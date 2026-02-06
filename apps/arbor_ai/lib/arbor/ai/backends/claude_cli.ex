defmodule Arbor.AI.Backends.ClaudeCli do
  @moduledoc """
  Claude CLI backend for LLM text generation.

  Uses the `claude` command-line tool with subscription-based pricing.
  Supports multiple models (Opus, Sonnet, Haiku) via the `--model` flag.

  ## Session Management

  Claude CLI stores sessions in `~/.claude/projects/` organized by working directory.
  - Resume last session: `-c` flag
  - Resume specific session: `-r <session_uuid>`

  ## Models

  - `opus` / `claude-opus-4-5` - Best reasoning, highest quality
  - `sonnet` / `claude-sonnet-4` - Balanced performance (default)
  - `haiku` / `claude-haiku` - Fast, efficient

  ## Streaming Mode

  When `streaming: true` is passed, uses NDJSON streaming output format which
  captures real-time content including thinking blocks (when available).

      {:ok, response} = ClaudeCli.generate_text("Analyze this", streaming: true)
      response.thinking  #=> [%{text: "...", signature: "..."}]

  ## Usage

      # Basic generation
      {:ok, response} = ClaudeCli.generate_text("Hello")

      # With model selection
      {:ok, response} = ClaudeCli.generate_text("Complex task", model: :opus)

      # Force new session
      {:ok, response} = ClaudeCli.generate_text("New project", new_session: true)

      # Streaming mode (captures thinking)
      {:ok, response} = ClaudeCli.generate_text("Think about this", streaming: true)
  """

  use Arbor.AI.Backends.CliBackend, provider: :anthropic

  alias Arbor.AI.StreamParser

  # Model mappings - atom shortcuts and full names
  # Claude CLI accepts short aliases like "sonnet", "opus", "haiku"
  @models %{
    :opus => "opus",
    :sonnet => "sonnet",
    :haiku => "haiku",
    # Also accept full names
    "claude-opus-4-5" => "opus",
    "claude-sonnet-4" => "sonnet",
    "claude-haiku" => "haiku",
    "opus" => "opus",
    "sonnet" => "sonnet",
    "haiku" => "haiku"
  }

  @default_model :sonnet

  # ============================================================================
  # Callback Implementations
  # ============================================================================

  @impl true
  def generate_text(prompt, opts) do
    streaming = Keyword.get(opts, :streaming, false)

    if streaming do
      generate_text_streaming(prompt, opts)
    else
      # Use default implementation from CliBackend
      CliBackend.do_generate_text(__MODULE__, @provider, prompt, opts)
    end
  end

  @impl true
  def build_command(prompt, opts) do
    model = resolve_model(Keyword.get(opts, :model, @default_model))
    session_mode = CliBackend.session_mode(session_dir(), opts)
    session_id = Keyword.get(opts, :session_id)
    streaming = Keyword.get(opts, :streaming, false)

    args = []

    # Model selection (if not default)
    args =
      if model != resolve_model(@default_model) do
        ["--model", model | args]
      else
        args
      end

    # Session handling
    args =
      case {session_mode, session_id} do
        {:resume, nil} ->
          # Resume last session
          ["-c" | args]

        {:resume, id} when is_binary(id) ->
          # Resume specific session
          ["-r", id | args]

        {:new, _} ->
          # New session (no flag needed)
          args
      end

    # Output format - streaming vs JSON
    args =
      if streaming do
        args ++ ["--output-format", "stream-json", "--verbose", "--include-partial-messages"]
      else
        args ++ ["--output-format", "json"]
      end

    # Skip permission prompts for non-interactive use
    args = args ++ ["--dangerously-skip-permissions"]

    # Add the prompt
    args = args ++ ["-p", prompt]

    {"claude", args}
  end

  @impl true
  def parse_output(output) do
    # Claude outputs JSON when --output-format json is used
    # Format: {"type":"result","result":"...","modelUsage":{...}}
    trimmed = String.trim(output)

    case CliBackend.parse_json_output(trimmed) do
      {:ok, json} ->
        parse_json_response(json)

      {:error, _} ->
        # Fallback: treat as plain text
        {:ok, CliBackend.build_response(%{text: trimmed}, @provider)}
    end
  end

  @impl true
  def default_model, do: @default_model

  @impl true
  def available_models, do: [:opus, :sonnet, :haiku]

  @impl true
  def supports_json_output?, do: true

  @impl true
  def supports_sessions?, do: true

  @impl true
  def session_dir do
    # Claude stores sessions in ~/.claude/projects/
    home = System.get_env("HOME") || "~"
    Path.join([home, ".claude", "projects"])
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  # Generate text using streaming mode with StreamParser
  defp generate_text_streaming(prompt, opts) do
    {cmd, args} = build_command(prompt, opts)
    model = Keyword.get(opts, :model, @default_model)

    Logger.info("Claude CLI streaming generation",
      model: model,
      prompt_length: String.length(prompt)
    )

    start_time = System.monotonic_time(:millisecond)

    case CliBackend.execute_command(cmd, args, opts) do
      {:ok, output} ->
        duration = System.monotonic_time(:millisecond) - start_time

        # Parse streaming output
        state = StreamParser.new()
        state = StreamParser.process_lines(state, output)
        result = StreamParser.finalize(state)

        # Build response from parsed result
        response = build_streaming_response(result, model, duration)

        Logger.info("Claude CLI streaming response received",
          duration_ms: duration,
          response_length: String.length(response.text || ""),
          thinking_blocks: length(response.thinking || [])
        )

        {:ok, response}

      {:error, {:exit_code, _code, output}} = error ->
        # Check for quota exhaustion in error output
        Arbor.AI.QuotaTracker.check_and_mark(@provider, output)
        Logger.warning("Claude CLI streaming execution error", error: inspect(error))
        error

      {:error, reason} ->
        Logger.warning("Claude CLI streaming execution error", error: inspect(reason))
        {:error, reason}
    end
  end

  # Build Response from StreamParser result
  defp build_streaming_response(result, model, duration_ms) do
    # Convert thinking blocks to expected format
    thinking =
      case result.thinking do
        nil ->
          nil

        [] ->
          nil

        blocks ->
          Enum.map(blocks, fn block ->
            %{
              text: block.text,
              signature: block[:signature]
            }
          end)
      end

    Response.new(
      text: result.text,
      thinking: thinking,
      provider: @provider,
      model: result.model || resolve_model(model),
      session_id: result.session_id,
      usage: result.usage,
      timing: %{duration_ms: duration_ms}
    )
  end

  defp resolve_model(model) when is_atom(model) do
    Map.get(@models, model, @models[@default_model])
  end

  defp resolve_model(model) when is_binary(model) do
    Map.get(@models, model, model)
  end

  # Real Claude JSON structure:
  # {
  #   "type": "result",
  #   "subtype": "success",
  #   "is_error": false,
  #   "duration_ms": 2453,
  #   "duration_api_ms": 2441,
  #   "num_turns": 1,
  #   "result": "Hello",
  #   "session_id": "7b08e77b-...",
  #   "total_cost_usd": 0.068,
  #   "usage": {input_tokens, cache_creation_input_tokens, cache_read_input_tokens, output_tokens},
  #   "modelUsage": {"claude-opus-4-5-...": {inputTokens, outputTokens, cacheReadInputTokens, ...}}
  # }
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp parse_json_response(json) when is_map(json) do
    text = json["result"] || ""
    session_id = json["session_id"]

    # Extract model from modelUsage keys
    {model, model_usage} = extract_model_usage(json["modelUsage"])

    # Merge top-level usage with model-specific usage
    top_usage = json["usage"] || %{}

    usage = %{
      input_tokens: top_usage["input_tokens"] || model_usage[:input_tokens] || 0,
      output_tokens: top_usage["output_tokens"] || model_usage[:output_tokens] || 0,
      total_tokens: (top_usage["input_tokens"] || 0) + (top_usage["output_tokens"] || 0),
      cache_read_tokens:
        top_usage["cache_read_input_tokens"] || model_usage[:cache_read_tokens] || 0,
      cache_creation_tokens:
        top_usage["cache_creation_input_tokens"] || model_usage[:cache_creation_tokens] || 0,
      cost_usd: json["total_cost_usd"] || model_usage[:cost_usd]
    }

    response =
      Response.new(
        text: text,
        provider: @provider,
        model: model,
        session_id: session_id,
        usage: usage,
        timing: %{
          duration_ms: json["duration_ms"],
          duration_api_ms: json["duration_api_ms"]
        },
        raw_response: json
      )

    {:ok, response}
  end

  defp extract_model_usage(nil), do: {nil, %{}}

  defp extract_model_usage(model_usage) when is_map(model_usage) do
    # modelUsage is a map like {"claude-opus-4-5-...": {inputTokens: ..., outputTokens: ...}}
    case Map.to_list(model_usage) do
      [{model_name, stats} | _] ->
        usage = %{
          input_tokens: stats["inputTokens"] || 0,
          output_tokens: stats["outputTokens"] || 0,
          cache_read_tokens: stats["cacheReadInputTokens"] || 0,
          cache_creation_tokens: stats["cacheCreationInputTokens"] || 0,
          cost_usd: stats["costUSD"]
        }

        {model_name, usage}

      [] ->
        {nil, %{}}
    end
  end
end
