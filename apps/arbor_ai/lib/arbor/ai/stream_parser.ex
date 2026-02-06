defmodule Arbor.AI.StreamParser do
  @moduledoc """
  Parses Claude CLI stream-json output for real-time content extraction.

  Claude CLI with `--output-format stream-json --verbose --include-partial-messages`
  produces NDJSON events that this module can parse.

  ## Event Types

  - `stream_event` with `content_block_start` — marks beginning of content
  - `stream_event` with `content_block_delta` — incremental content chunks
  - `assistant` — final complete message
  - `result` — final result with usage stats

  ## Content Delta Types

  - `text_delta` — regular text output
  - `thinking_delta` — extended thinking (when available)

  ## Usage

      # Parse a single line
      {:ok, event} = StreamParser.parse_line(line)

      # Parse full output and accumulate
      state = StreamParser.new()
      state = StreamParser.process_line(state, line1)
      state = StreamParser.process_line(state, line2)
      result = StreamParser.finalize(state)

      result.text         #=> "Accumulated text"
      result.thinking     #=> [%{text: "...", signature: nil}]
      result.session_id   #=> "..."
  """

  require Logger

  @type content_block :: %{
          type: :text | :thinking,
          text: String.t(),
          signature: String.t() | nil
        }

  @type state :: %{
          text_acc: iodata(),
          thinking_acc: iodata(),
          thinking_blocks: [content_block()],
          current_block_type: :text | :thinking | nil,
          session_id: String.t() | nil,
          usage: map() | nil,
          model: String.t() | nil,
          raw_events: [map()]
        }

  @type result :: %{
          text: String.t(),
          thinking: [content_block()] | nil,
          session_id: String.t() | nil,
          usage: map() | nil,
          model: String.t() | nil
        }

  @doc """
  Create a new parser state.
  """
  @spec new() :: state()
  def new do
    %{
      text_acc: [],
      thinking_acc: [],
      thinking_blocks: [],
      current_block_type: nil,
      session_id: nil,
      usage: nil,
      model: nil,
      raw_events: []
    }
  end

  @doc """
  Parse a single NDJSON line into an event map.
  """
  @spec parse_line(String.t()) :: {:ok, map()} | {:error, term()}
  def parse_line(line) do
    line
    |> String.trim()
    |> Jason.decode()
  end

  @doc """
  Process a single line and update state.
  """
  @spec process_line(state(), String.t()) :: state()
  def process_line(state, line) do
    case parse_line(line) do
      {:ok, event} ->
        process_event(state, event)

      {:error, _} ->
        # Skip non-JSON lines
        state
    end
  end

  @doc """
  Process multiple lines at once.
  """
  @spec process_lines(state(), String.t()) :: state()
  def process_lines(state, output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce(state, &process_line(&2, &1))
  end

  @doc """
  Finalize parsing and return result.
  """
  @spec finalize(state()) :: result()
  def finalize(state) do
    # Finalize any in-progress thinking block
    state = finalize_thinking_block(state)

    thinking =
      case state.thinking_blocks do
        [] -> nil
        blocks -> Enum.reverse(blocks)
      end

    %{
      text: IO.iodata_to_binary(Enum.reverse(state.text_acc)),
      thinking: thinking,
      session_id: state.session_id,
      usage: state.usage,
      model: state.model
    }
  end

  # ============================================================================
  # Event Processing
  # ============================================================================

  defp process_event(state, %{"type" => "stream_event", "event" => event}) do
    process_stream_event(state, event)
  end

  defp process_event(state, %{"type" => "assistant", "message" => message}) do
    process_assistant_message(state, message)
  end

  defp process_event(state, %{"type" => "result"} = result) do
    process_result(state, result)
  end

  defp process_event(state, _event) do
    # Ignore other event types (system, hook_started, hook_response, etc.)
    state
  end

  # Stream event processing
  defp process_stream_event(state, %{"type" => "content_block_start", "content_block" => block}) do
    block_type = block_type_from_content(block)
    %{state | current_block_type: block_type}
  end

  defp process_stream_event(state, %{"type" => "content_block_delta", "delta" => delta}) do
    process_delta(state, delta)
  end

  defp process_stream_event(state, %{"type" => "content_block_stop"}) do
    # Finalize current block
    finalize_current_block(state)
  end

  defp process_stream_event(state, _event) do
    state
  end

  # Delta processing
  defp process_delta(state, %{"type" => "text_delta", "text" => text}) do
    %{state | text_acc: [text | state.text_acc]}
  end

  defp process_delta(state, %{"type" => "thinking_delta", "thinking" => thinking}) do
    %{state | thinking_acc: [thinking | state.thinking_acc], current_block_type: :thinking}
  end

  defp process_delta(state, _delta) do
    state
  end

  # Determine block type from content_block_start
  defp block_type_from_content(%{"type" => "thinking"}), do: :thinking
  defp block_type_from_content(%{"type" => "text"}), do: :text
  defp block_type_from_content(_), do: :text

  # Finalize current block when content_block_stop is received
  defp finalize_current_block(%{current_block_type: :thinking} = state) do
    finalize_thinking_block(state)
  end

  defp finalize_current_block(state) do
    %{state | current_block_type: nil}
  end

  # Finalize accumulated thinking into a block
  defp finalize_thinking_block(%{thinking_acc: []} = state) do
    %{state | current_block_type: nil}
  end

  defp finalize_thinking_block(state) do
    text = IO.iodata_to_binary(Enum.reverse(state.thinking_acc))

    block = %{
      type: :thinking,
      text: text,
      signature: nil
    }

    %{
      state
      | thinking_blocks: [block | state.thinking_blocks],
        thinking_acc: [],
        current_block_type: nil
    }
  end

  # Process final assistant message (contains complete content)
  defp process_assistant_message(state, %{"content" => content} = message) when is_list(content) do
    session_id = message["id"]

    # Extract model from message or nested model info
    model = extract_model(message)

    # Process content blocks (may include thinking blocks with signatures)
    state = process_content_blocks(state, content)

    %{state | session_id: session_id, model: model}
  end

  defp process_assistant_message(state, _message) do
    state
  end

  defp extract_model(%{"model" => model}) when is_binary(model), do: model
  defp extract_model(_), do: nil

  # Process content blocks from assistant message
  defp process_content_blocks(state, content) when is_list(content) do
    Enum.reduce(content, state, &process_content_block/2)
  end

  defp process_content_block(%{"type" => "thinking"} = block, state) do
    thinking_block = %{
      type: :thinking,
      text: block["thinking"] || "",
      signature: block["signature"]
    }

    # Only add if we don't already have this content from streaming
    if Enum.any?(state.thinking_blocks, &(&1.text == thinking_block.text)) do
      state
    else
      %{state | thinking_blocks: [thinking_block | state.thinking_blocks]}
    end
  end

  defp process_content_block(_block, state) do
    # Text blocks already accumulated from deltas
    state
  end

  # Process final result (has usage stats)
  defp process_result(state, result) do
    usage = extract_usage(result)
    session_id = result["session_id"] || state.session_id

    %{state | usage: usage, session_id: session_id}
  end

  defp extract_usage(result) do
    raw_usage = result["usage"] || %{}

    %{
      input_tokens: raw_usage["input_tokens"] || 0,
      output_tokens: raw_usage["output_tokens"] || 0,
      cache_read_tokens: raw_usage["cache_read_input_tokens"] || 0,
      cache_creation_tokens: raw_usage["cache_creation_input_tokens"] || 0
    }
  end
end
