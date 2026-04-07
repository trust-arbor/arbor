defmodule Arbor.Orchestrator.SessionCore do
  @moduledoc """
  Pure CRC module for session state operations.

  All functions are pure — they take session state in, return session state out.
  No GenServer calls, no ETS, no persistence, no telemetry recording.
  The GenServer wrapper (Session) handles side effects based on the results.

  ## CRC Pattern

  - **Construct**: `new/1`, `normalize_message/1` — build initial state or normalize inputs
  - **Reduce**: `append_user_message/2`, `apply_llm_response/2`, `maybe_compact/1` — state transitions
  - **Convert**: `for_llm/1`, `for_dashboard/1`, `for_persistence/1`, etc. — consumer-specific views

  ## Pipeline Composability

      session
      |> SessionCore.append_user_message("hello")
      |> SessionCore.apply_llm_response(response)
      |> SessionCore.maybe_compact()
      |> SessionCore.for_llm()   # → messages ready for LLM API
  """

  # ===========================================================================
  # Construct
  # ===========================================================================

  @doc "Normalize a message to a plain string."
  @spec normalize_message(term()) :: String.t()
  def normalize_message(message) when is_binary(message), do: message
  def normalize_message(%{"content" => content}) when is_binary(content), do: content
  def normalize_message(%{content: content}) when is_binary(content), do: content
  def normalize_message(message), do: inspect(message)

  @doc "Build a user message map."
  @spec build_user_message(String.t(), DateTime.t()) :: map()
  def build_user_message(content, timestamp \\ DateTime.utc_now()) do
    %{
      "role" => "user",
      "content" => normalize_message(content),
      "timestamp" => DateTime.to_iso8601(timestamp)
    }
  end

  @doc "Build an assistant message map. Returns nil for empty responses."
  @spec build_assistant_message(String.t() | nil, DateTime.t()) :: map() | nil
  def build_assistant_message(content, timestamp \\ DateTime.utc_now())
  def build_assistant_message(nil, _timestamp), do: nil
  def build_assistant_message("", _timestamp), do: nil

  def build_assistant_message(content, timestamp) do
    trimmed = String.trim(content)

    if trimmed == "" do
      nil
    else
      %{
        "role" => "assistant",
        "content" => trimmed,
        "timestamp" => DateTime.to_iso8601(timestamp)
      }
    end
  end

  # ===========================================================================
  # Reduce — State Transitions
  # ===========================================================================

  @doc """
  Append a user message to the session. Returns just the updated messages list.

  Pipeable — chains with other Reduce functions. If you need the constructed
  user message itself (e.g. for telemetry), call `build_user_message/2`
  separately or use `List.last/1` on the result.

  Pure — does not persist or emit events.
  """
  @spec append_user_message([map()], String.t(), DateTime.t()) :: [map()]
  def append_user_message(messages, content, timestamp \\ DateTime.utc_now()) do
    messages ++ [build_user_message(content, timestamp)]
  end

  @doc """
  Apply an LLM response to the session messages. Returns just the updated messages.

  Filters empty responses — only appends if the response has actual content,
  so the result may equal the input when the response is nil/empty.

  Pipeable — chains with other Reduce functions. If you need the constructed
  assistant message itself, call `build_assistant_message/2` separately.

  Pure — does not persist or emit events.
  """
  @spec apply_llm_response([map()], String.t() | nil, DateTime.t()) :: [map()]
  def apply_llm_response(messages, response_text, timestamp \\ DateTime.utc_now()) do
    case build_assistant_message(response_text, timestamp) do
      nil -> messages
      assistant_msg -> messages ++ [assistant_msg]
    end
  end

  @doc """
  Decide whether compaction is needed based on token count vs window.

  Returns `{:compact, messages_to_keep, messages_to_summarize}` or `:no_compact`.
  """
  @spec compaction_decision([map()], non_neg_integer(), non_neg_integer()) ::
          {:compact, [map()], [map()]} | :no_compact
  def compaction_decision(messages, token_count, effective_window) do
    if token_count >= effective_window do
      # Split: older messages get summarized, recent stay
      target_tokens = div(effective_window, 2)
      {to_summarize, to_keep} = split_for_compression(messages, target_tokens)
      {:compact, to_keep, to_summarize}
    else
      :no_compact
    end
  end

  @doc """
  Split messages into keep (recent) and summarize (old) buckets.

  Keeps messages from the end that fit within target_tokens.
  Returns `{to_summarize, to_keep}`.
  """
  @spec split_for_compression([map()], non_neg_integer()) :: {[map()], [map()]}
  def split_for_compression(messages, target_tokens) do
    reversed = Enum.reverse(messages)

    {to_keep_rev, to_summarize_rev, _tokens} =
      Enum.reduce(reversed, {[], [], 0}, fn msg, {keep, summarize, tokens} ->
        msg_tokens = estimate_message_tokens(msg)

        if tokens + msg_tokens <= target_tokens do
          {[msg | keep], summarize, tokens + msg_tokens}
        else
          {keep, [msg | summarize], tokens}
        end
      end)

    {Enum.reverse(to_summarize_rev), Enum.reverse(to_keep_rev)}
  end

  @doc "Increment turn count."
  @spec increment_turn(non_neg_integer()) :: non_neg_integer()
  def increment_turn(count), do: count + 1

  # ===========================================================================
  # Convert — Consumer-Specific Views
  # ===========================================================================

  @doc """
  Format messages for LLM API call.

  Returns a list of message maps with "role" and "content" keys,
  suitable for passing to the LLM provider.
  """
  @spec for_llm([map()]) :: [map()]
  def for_llm(messages) do
    messages
    |> Enum.filter(fn msg ->
      role = msg["role"] || msg[:role]
      content = msg["content"] || msg[:content]
      role != nil and content != nil and content != ""
    end)
    |> Enum.map(fn msg ->
      %{
        "role" => to_string(msg["role"] || msg[:role]),
        "content" => to_string(msg["content"] || msg[:content])
      }
    end)
  end

  @doc """
  Format messages for cloud egress with PII tokenization.

  Replaces sensitive values with entity placeholders using the token_map.
  """
  @spec for_cloud([map()], map()) :: [map()]
  def for_cloud(messages, token_map) when is_map(token_map) do
    messages
    |> for_llm()
    |> Enum.map(fn msg ->
      content = msg["content"]

      tokenized =
        Enum.reduce(token_map, content, fn {placeholder, %{original: original}}, acc ->
          String.replace(acc, original, placeholder)
        end)

      %{msg | "content" => tokenized}
    end)
  end

  def for_cloud(messages, _), do: for_llm(messages)

  @doc """
  Format messages for dashboard display.

  Returns display-ready maps with id, role (atom), content, and timestamp.
  """
  @spec for_dashboard([map()]) :: [map()]
  def for_dashboard(messages) do
    messages
    |> Enum.with_index()
    |> Enum.map(fn {msg, idx} ->
      role =
        case msg["role"] || msg[:role] do
          "user" -> :user
          "assistant" -> :assistant
          "system" -> :system
          other when is_atom(other) -> other
          _ -> :unknown
        end

      %{
        id: "msg-#{idx}",
        role: role,
        content: to_string(msg["content"] || msg[:content] || ""),
        timestamp: msg["timestamp"] || msg[:timestamp]
      }
    end)
  end

  @doc """
  Format messages for persistence to SessionStore.

  Returns entries with content wrapped as content blocks (SessionEntry format).
  """
  @spec for_persistence([map()]) :: [map()]
  def for_persistence(messages) do
    messages
    |> Enum.map(fn msg ->
      role = to_string(msg["role"] || msg[:role] || "unknown")
      content_text = to_string(msg["content"] || msg[:content] || "")

      %{
        entry_type: role,
        role: role,
        content: [%{"type" => "text", "text" => content_text}],
        timestamp: parse_timestamp(msg["timestamp"] || msg[:timestamp])
      }
    end)
  end

  @doc """
  Build pipeline context dict from session state.

  This is the initial_values map passed to the DOT pipeline engine.
  """
  @spec for_prompt_context(map()) :: map()
  def for_prompt_context(session_state) when is_map(session_state) do
    %{
      "session.agent_id" => session_state[:agent_id] || session_state["agent_id"],
      "session.session_id" => session_state[:session_id] || session_state["session_id"],
      "session.messages" => session_state[:messages] || session_state["messages"] || [],
      "session.turn_count" => session_state[:turn_count] || session_state["turn_count"] || 0,
      "session.trust_tier" => session_state[:trust_tier] || session_state["trust_tier"]
    }
  end

  @doc """
  Summarize a turn for telemetry.

  Returns a map with turn metrics suitable for AgentTelemetry.record_turn.
  """
  @spec turn_summary([map()], map()) :: map()
  def turn_summary(messages, usage \\ %{}) do
    %{
      turn_count: length(messages),
      message_count: length(messages),
      user_messages: Enum.count(messages, &(&1["role"] == "user")),
      assistant_messages: Enum.count(messages, &(&1["role"] == "assistant")),
      input_tokens: usage["input_tokens"] || usage[:input_tokens] || 0,
      output_tokens: usage["output_tokens"] || usage[:output_tokens] || 0,
      cached_tokens: usage["cached_tokens"] || usage[:cached_tokens] || 0,
      total_tokens: estimate_total_tokens(messages)
    }
  end

  @doc "Estimate token count for a single message."
  @spec estimate_message_tokens(map()) :: non_neg_integer()
  def estimate_message_tokens(msg) when is_map(msg) do
    content = msg["content"] || msg[:content] || ""
    estimate_text_tokens(to_string(content))
  end

  @doc "Estimate token count for text (rough: ~4 chars per token)."
  @spec estimate_text_tokens(String.t()) :: non_neg_integer()
  def estimate_text_tokens(text) when is_binary(text) do
    div(String.length(text), 4) + 1
  end

  def estimate_text_tokens(_), do: 0

  @doc "Estimate total tokens across all messages."
  @spec estimate_total_tokens([map()]) :: non_neg_integer()
  def estimate_total_tokens(messages) when is_list(messages) do
    Enum.reduce(messages, 0, fn msg, acc -> acc + estimate_message_tokens(msg) end)
  end

  # ===========================================================================
  # Private
  # ===========================================================================

  defp parse_timestamp(%DateTime{} = dt), do: dt
  defp parse_timestamp(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end
  defp parse_timestamp(_), do: DateTime.utc_now()
end
