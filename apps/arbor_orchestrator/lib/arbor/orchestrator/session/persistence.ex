defmodule Arbor.Orchestrator.Session.Persistence do
  @moduledoc """
  Checkpoint management and session entry persistence.

  Handles saving/restoring checkpoints, persisting turn and heartbeat entries
  to the session store, and seeding the compactor from restored checkpoint data.
  """

  require Logger

  alias Arbor.Orchestrator.Session.ContextBuilder

  @session_store Arbor.Persistence.SessionStore

  # ── Checkpoint application ────────────────────────────────────────

  @doc false
  def apply_checkpoint(state, checkpoint) when is_map(checkpoint) do
    # Unwrap Checkpoint.save wrapper if present (stores data under :data key)
    data =
      case Map.get(checkpoint, :data) do
        inner when is_map(inner) -> inner
        _ -> checkpoint
      end

    # Support both prefixed ("session.messages") and unprefixed ("messages") keys
    state
    |> maybe_restore(:messages, cp_get(data, "messages"))
    |> maybe_restore(:working_memory, cp_get(data, "working_memory"))
    |> maybe_restore(:goals, cp_get(data, "goals"))
    |> maybe_restore(:turn_count, cp_get(data, "turn_count"))
    |> maybe_restore_cognitive_mode(cp_get(data, "cognitive_mode"))
    |> seed_compactor_from_checkpoint()
    |> sync_checkpoint_to_session_state()
  end

  # Fetch checkpoint value supporting both "session.X" and "X" key formats
  @doc false
  def cp_get(data, field) do
    Map.get(data, "session.#{field}") || Map.get(data, field)
  end

  @doc false
  def maybe_restore(state, _field, nil), do: state
  def maybe_restore(state, field, value), do: %{state | field => value}

  @doc false
  def maybe_restore_cognitive_mode(state, nil), do: state

  def maybe_restore_cognitive_mode(state, mode) when is_atom(mode),
    do: %{state | cognitive_mode: mode}

  def maybe_restore_cognitive_mode(state, mode) when is_binary(mode) do
    atom_mode =
      try do
        String.to_existing_atom(mode)
      rescue
        ArgumentError -> state.cognitive_mode
      end

    %{state | cognitive_mode: atom_mode}
  end

  @doc false
  def sync_checkpoint_to_session_state(%{session_state: nil} = state), do: state

  def sync_checkpoint_to_session_state(state) do
    update_session_state(state, fn ss ->
      ss
      |> Map.put(:messages, state.messages)
      |> Map.put(:working_memory, state.working_memory)
      |> Map.put(:goals, state.goals)
      |> Map.put(:turn_count, state.turn_count)
      |> Map.put(:cognitive_mode, state.cognitive_mode)
    end)
  end

  # ── Session checkpoint persistence ────────────────────────────────

  @doc false
  def maybe_checkpoint(state) do
    checkpoint_fn = get_in(state, [Access.key(:adapters), Access.key(:checkpoint_save)])

    if is_function(checkpoint_fn, 2) and should_checkpoint?(state) do
      data = extract_checkpoint_data(state)

      Task.start(fn ->
        try do
          checkpoint_fn.(state.session_id, data)
        rescue
          e -> Logger.warning("[Session] Checkpoint save failed: #{Exception.message(e)}")
        end
      end)
    end

    state
  end

  @doc false
  def extract_checkpoint_data(state) do
    %{
      "messages" => ContextBuilder.get_messages(state),
      "working_memory" => ContextBuilder.get_working_memory(state),
      "goals" => ContextBuilder.get_goals(state),
      "turn_count" => ContextBuilder.get_turn_count(state),
      "cognitive_mode" => to_string(ContextBuilder.get_cognitive_mode(state)),
      "checkpoint_at" => DateTime.to_iso8601(DateTime.utc_now())
    }
  end

  @doc false
  def should_checkpoint?(state) do
    interval = get_in(state, [Access.key(:config), Access.key(:checkpoint_interval)]) || 1
    rem(ContextBuilder.get_turn_count(state), max(interval, 1)) == 0
  end

  # ── Compactor seeding from checkpoint ─────────────────────────────

  # Seed compactor with restored checkpoint messages so it can track them.
  # Without this, a restored session would have messages in state but an
  # empty compactor — it would never compact because it thinks it has 0 tokens.
  @doc false
  def seed_compactor_from_checkpoint(%{compactor: nil} = state), do: state

  def seed_compactor_from_checkpoint(%{compactor: compactor, messages: messages} = state)
      when is_list(messages) and messages != [] do
    seeded =
      Enum.reduce(messages, compactor, fn msg, acc ->
        apply_compactor(acc, :append, [msg])
      end)

    %{state | compactor: seeded}
  end

  def seed_compactor_from_checkpoint(state), do: state

  # ── Session entry persistence (runtime bridge) ────────────────────

  @doc false
  def persist_turn_entries(state, timestamp, user_msg, assistant_msg, result_ctx) do
    persist_entry = get_persist_entry_fn(state)

    if persist_entry do
      Task.start(fn ->
        try do
          # Persist user message entry
          persist_entry.(%{
            entry_type: "user",
            role: "user",
            content: wrap_content(user_msg["content"]),
            timestamp: timestamp
          })

          # Build assistant content array (may include tool_use blocks)
          tool_calls = Map.get(result_ctx, "session.tool_calls", [])

          assistant_content =
            build_assistant_content(assistant_msg["content"], tool_calls)

          persist_entry.(%{
            entry_type: "assistant",
            role: "assistant",
            content: assistant_content,
            model: Map.get(result_ctx, "llm.model"),
            stop_reason: Map.get(result_ctx, "llm.stop_reason"),
            token_usage: Map.get(result_ctx, "llm.usage"),
            timestamp: timestamp,
            metadata: %{
              "turn_count" => ContextBuilder.get_turn_count(state) + 1
            }
          })
        rescue
          e -> Logger.warning("[Session] Turn entry persistence failed: #{Exception.message(e)}")
        end
      end)
    end
  end

  @doc false
  def persist_heartbeat_entry(state, result_ctx) do
    persist_entry = get_persist_entry_fn(state)

    if persist_entry do
      Task.start(fn ->
        try do
          cognitive_mode = Map.get(result_ctx, "session.cognitive_mode", "reflection")
          memory_notes = Map.get(result_ctx, "session.memory_notes", [])
          goal_updates = Map.get(result_ctx, "session.goal_updates", [])
          new_goals = Map.get(result_ctx, "session.new_goals", [])
          actions = Map.get(result_ctx, "session.actions", [])

          persist_entry.(%{
            entry_type: "heartbeat",
            role: "assistant",
            content: wrap_content(Map.get(result_ctx, "llm.content", "")),
            model: Map.get(result_ctx, "llm.model"),
            timestamp: DateTime.utc_now(),
            metadata: %{
              "cognitive_mode" => cognitive_mode,
              "memory_notes_count" => length(List.wrap(memory_notes)),
              "goal_updates_count" =>
                length(List.wrap(goal_updates)) + length(List.wrap(new_goals)),
              "actions_count" => length(List.wrap(actions))
            }
          })
        rescue
          e ->
            Logger.warning(
              "[Session] Heartbeat entry persistence failed: #{Exception.message(e)}"
            )
        end
      end)
    end
  end

  @doc false
  def get_persist_entry_fn(state) do
    # Check adapter first, then fall back to runtime bridge
    case get_in(state, [Access.key(:adapters), Access.key(:persist_entry)]) do
      fun when is_function(fun, 1) ->
        fun

      _ ->
        build_persist_fn_from_store(state)
    end
  end

  @doc false
  def build_persist_fn_from_store(state) do
    if session_store_available?() do
      case get_session_uuid(state.session_id) do
        nil -> nil
        uuid -> fn attrs -> apply(@session_store, :append_entry, [uuid, attrs]) end
      end
    end
  end

  @doc false
  def get_session_uuid(session_id) do
    case apply(@session_store, :get_session, [session_id]) do
      {:ok, session} -> session.id
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  @doc false
  def session_store_available? do
    Code.ensure_loaded?(@session_store) and
      function_exported?(@session_store, :available?, 0) and
      apply(@session_store, :available?, [])
  end

  @doc false
  def wrap_content(text) when is_binary(text), do: [%{"type" => "text", "text" => text}]
  def wrap_content(content) when is_list(content), do: content
  def wrap_content(_), do: []

  @doc false
  def build_assistant_content(text, tool_calls) when is_list(tool_calls) and tool_calls != [] do
    text_block = if text && text != "", do: [%{"type" => "text", "text" => text}], else: []

    tool_blocks =
      Enum.map(tool_calls, fn tc ->
        %{
          "type" => "tool_use",
          "id" => Map.get(tc, "id", Map.get(tc, :id)),
          "name" => Map.get(tc, "name", Map.get(tc, :name)),
          "input" => Map.get(tc, "input", Map.get(tc, :input, %{}))
        }
      end)

    text_block ++ tool_blocks
  end

  def build_assistant_content(text, _), do: wrap_content(text)

  # ── Private helpers ───────────────────────────────────────────────

  defp update_session_state(%{session_state: nil} = state, _update_fn), do: state

  defp update_session_state(%{session_state: ss} = state, update_fn) when not is_nil(ss) do
    updated_ss = update_fn.(ss)
    %{state | session_state: updated_ss}
  end

  # Runtime bridge: the compactor struct carries its own module via __struct__
  defp apply_compactor(%{__struct__: module} = compactor, fun, args) do
    apply(module, fun, [compactor | args])
  end
end
