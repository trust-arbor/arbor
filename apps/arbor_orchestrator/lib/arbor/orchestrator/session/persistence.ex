defmodule Arbor.Orchestrator.Session.Persistence do
  @moduledoc """
  Checkpoint management and session entry persistence.

  Handles saving/restoring checkpoints, persisting turn and heartbeat entries
  to the session store, and seeding the compactor from restored checkpoint data.
  """

  require Logger

  alias Arbor.Orchestrator.Session.ContextBuilder
  alias Arbor.Orchestrator.Session.Persistence.Core

  # Matches the bounded history admitted by the legacy load_entries path.
  @engagement_transcript_limit 1_000

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
    |> restore_checkpoint_conversation(data)
    |> maybe_restore(:working_memory, cp_get(data, "working_memory"))
    |> maybe_restore(:goals, cp_get(data, "goals"))
    |> maybe_restore(:turn_count, cp_get(data, "turn_count"))
    |> maybe_restore_cognitive_mode(cp_get(data, "cognitive_mode"))
    |> drop_active_engagement_stash()
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
  def restore_checkpoint_conversation(state, data) do
    engagement = cp_fetch(data, "current_engagement_id")
    messages = restore_checkpoint_messages(state, data, engagement)

    case {engagement, messages} do
      {{:ok, engagement_id}, {:ok, restored_messages}}
      when is_binary(engagement_id) or is_nil(engagement_id) ->
        %{state | current_engagement_id: engagement_id, messages: restored_messages}
        |> rebuild_compactor_from_checkpoint()

      {{:ok, engagement_id}, :error}
      when (is_binary(engagement_id) or is_nil(engagement_id)) and
             engagement_id != state.current_engagement_id ->
        # Never relabel the active transcript when provenance changes without
        # carrying its matching messages.
        %{state | current_engagement_id: engagement_id, messages: []}
        |> rebuild_compactor_from_checkpoint()

      {:error, {:ok, restored_messages}} ->
        %{state | messages: restored_messages}
        |> rebuild_compactor_from_checkpoint()

      {{:ok, engagement_id}, {:error, _reason}}
      when is_binary(engagement_id) or is_nil(engagement_id) ->
        %{state | current_engagement_id: engagement_id, messages: []}
        |> rebuild_compactor_from_checkpoint()

      {_engagement, {:error, _reason}} ->
        %{state | messages: []}
        |> rebuild_compactor_from_checkpoint()

      _ ->
        state
    end
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
      case extract_checkpoint_data(state) do
        data when is_map(data) ->
          Task.start(fn -> save_checkpoint(checkpoint_fn, state.session_id, data) end)

        {:error, _reason} ->
          Logger.warning("[Session] Checkpoint construction failed")
      end
    end

    state
  end

  @doc false
  def extract_checkpoint_data(state) do
    engagement_id = Map.get(state, :current_engagement_id)
    scope = checkpoint_scope(state, engagement_id)

    with {:ok, messages} <-
           Core.encode_checkpoint_messages(ContextBuilder.get_messages(state), scope) do
      %{
        "messages" => messages,
        "current_engagement_id" => engagement_id,
        "working_memory" => ContextBuilder.get_working_memory(state),
        "goals" => ContextBuilder.get_goals(state),
        "turn_count" => ContextBuilder.get_turn_count(state),
        "cognitive_mode" => to_string(ContextBuilder.get_cognitive_mode(state)),
        "checkpoint_at" => DateTime.to_iso8601(DateTime.utc_now())
      }
    else
      {:error, _reason} -> {:error, :checkpoint_provenance_unavailable}
    end
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
  def rebuild_compactor_from_checkpoint(%{compactor_spec: spec, messages: messages} = state)
      when is_list(messages) do
    %{state | compactor: ContextBuilder.init_compactor(spec, messages)}
  end

  # Compatibility for state maps created before compactor_spec existed.
  def rebuild_compactor_from_checkpoint(state), do: state

  defp cp_fetch(data, field) do
    case Map.fetch(data, "session.#{field}") do
      :error -> Map.fetch(data, field)
      found -> found
    end
  end

  defp restore_checkpoint_messages(state, data, engagement) do
    case cp_fetch(data, "messages") do
      :error ->
        :missing

      {:ok, persisted_messages} ->
        case engagement do
          {:ok, engagement_id} when is_binary(engagement_id) or is_nil(engagement_id) ->
            Core.restore_checkpoint_messages(
              persisted_messages,
              checkpoint_scope(state, engagement_id)
            )

          :error ->
            Core.restore_checkpoint_messages(persisted_messages, :missing)

          {:ok, _invalid_engagement} ->
            {:error, :invalid_checkpoint_engagement}
        end
    end
  end

  defp checkpoint_scope(state, engagement_id) do
    %{
      "agent_id" => Map.get(state, :agent_id),
      "current_engagement_id" => engagement_id,
      "session_id" => Map.get(state, :session_id)
    }
  end

  defp save_checkpoint(checkpoint_fn, session_id, data) do
    case checkpoint_fn.(session_id, data) do
      :ok -> :ok
      {:ok, _receipt} -> :ok
      _other -> Logger.warning("[Session] Checkpoint save failed")
    end
  rescue
    _ -> Logger.warning("[Session] Checkpoint save failed")
  catch
    _, _ -> Logger.warning("[Session] Checkpoint save failed")
  end

  defp drop_active_engagement_stash(state) do
    engagement_id = Map.get(state, :current_engagement_id)

    %{
      state
      | transcripts: Map.delete(Map.get(state, :transcripts, %{}), engagement_id),
        compactors: Map.delete(Map.get(state, :compactors, %{}), engagement_id)
    }
  end

  # ── Session entry persistence ─────────────────────────────────────

  @doc false
  def persist_turn_entries(state, user_msg, assistant_message, run_result, opts \\ []) do
    user_sent_at = Keyword.get(opts, :user_sent_at) || DateTime.utc_now()
    assistant_completed_at = Keyword.get(opts, :assistant_completed_at) || DateTime.utc_now()

    case Core.build_turn_entries(%{
           user_message: user_msg,
           assistant_message: assistant_message,
           run_result: run_result,
           user_sent_at: user_sent_at,
           assistant_completed_at: assistant_completed_at,
           engagement_id: Map.get(state, :current_engagement_id),
           turn_count: ContextBuilder.get_turn_count(state)
         }) do
      {:ok, [_, _] = entries} ->
        start_turn_persistence(state, entries)

      {:error, _reason} ->
        Logger.warning("[Session] Turn entry construction failed")
        {:error, :turn_persistence_unavailable}
    end
  end

  defp start_turn_persistence(state, entries) do
    ensure_session = get_ensure_session_fn(state)
    append_entries = get_persist_entries_fn(state)

    Task.start(fn ->
      persist_turn_batch(
        ensure_session,
        append_entries,
        state.session_id,
        state.agent_id,
        entries
      )
    end)
  end

  defp persist_turn_batch(ensure_session, append_entries, session_id, agent_id, entries) do
    with {:ok, %{id: session_uuid}} when is_binary(session_uuid) <-
           ensure_session.(session_id, agent_id, []),
         {:ok, 2} <- append_entries.(session_uuid, entries) do
      :ok
    else
      _other ->
        Logger.warning("[Session] Atomic turn entry persistence failed")
    end
  rescue
    _ -> Logger.warning("[Session] Atomic turn entry persistence failed")
  catch
    _, _ -> Logger.warning("[Session] Atomic turn entry persistence failed")
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

          result =
            persist_entry.(%{
              entry_type: "heartbeat",
              role: "assistant",
              # `last_response` is what LlmHandler actually writes; `llm.content`
              # was a dead-letter read kept around from an earlier design.
              content: wrap_content(Map.get(result_ctx, "last_response", "")),
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

          if result not in [:ok, {:ok, 1}] do
            Logger.warning("[Session] Heartbeat entry persistence failed")
          end
        rescue
          _ -> Logger.warning("[Session] Heartbeat entry persistence failed")
        catch
          _, _ -> Logger.warning("[Session] Heartbeat entry persistence failed")
        end
      end)
    end
  end

  @doc """
  Restore an engagement's transcript from the durable store.

  Loads the public display projection with an exact `engagement_id` filter and
  rebuilds machine-readable message maps retaining metadata, taint, and
  taint-status fields alongside role and content. Used by the Session on the
  first switch to an engagement, so a resumed conversation is not empty after a
  restart. Best-effort: returns `[]` if the store is unavailable or on any error.
  """
  @spec load_engagement_transcript(map(), String.t() | nil) :: [map()]
  def load_engagement_transcript(_state, nil), do: []

  def load_engagement_transcript(state, engagement_id) do
    load_messages = get_load_session_messages_fn(state)

    case load_messages.(
           state.session_id,
           engagement_id: engagement_id,
           limit: @engagement_transcript_limit
         ) do
      messages when is_list(messages) -> Core.restore_messages(messages)
      _other -> []
    end
  rescue
    _ ->
      Logger.debug("[Session] engagement transcript restore failed")
      []
  catch
    _, _ ->
      Logger.debug("[Session] engagement transcript restore failed")
      []
  end

  @doc false
  def get_persist_entries_fn(state) do
    case get_in(state, [Access.key(:adapters), Access.key(:append_session_entries)]) do
      fun when is_function(fun, 2) -> fun
      _other -> &Arbor.Persistence.append_session_entries/2
    end
  end

  defp get_ensure_session_fn(state) do
    case get_in(state, [Access.key(:adapters), Access.key(:ensure_session)]) do
      fun when is_function(fun, 3) -> fun
      _other -> &Arbor.Persistence.ensure_session/3
    end
  end

  defp get_load_session_messages_fn(state) do
    case get_in(state, [Access.key(:adapters), Access.key(:load_recent_session_messages)]) do
      fun when is_function(fun, 2) -> fun
      _other -> &Arbor.Persistence.load_recent_session_messages/2
    end
  end

  @doc false
  def get_persist_entry_fn(state) do
    case get_in(state, [Access.key(:adapters), Access.key(:persist_entry)]) do
      fun when is_function(fun, 1) ->
        fun

      _ ->
        build_persist_fn_from_store(state)
    end
  end

  @doc false
  def build_persist_fn_from_store(state) do
    append_entries = get_persist_entries_fn(state)

    case ensure_session_uuid(state) do
      nil -> nil
      uuid -> fn attrs -> append_entries.(uuid, [attrs]) end
    end
  end

  @doc false
  def ensure_session_uuid(session_id, agent_id) do
    case Arbor.Persistence.ensure_session(session_id, agent_id, []) do
      {:ok, %{id: session_uuid}} when is_binary(session_uuid) ->
        session_uuid

      _ ->
        nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp ensure_session_uuid(state) do
    ensure_session = get_ensure_session_fn(state)

    case ensure_session.(state.session_id, state.agent_id, []) do
      {:ok, %{id: session_uuid}} when is_binary(session_uuid) -> session_uuid
      _other -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  @doc false
  defdelegate wrap_content(content), to: Core

  @doc false
  defdelegate build_assistant_content(text, tool_calls), to: Core

  # ── Private helpers ───────────────────────────────────────────────

  defp update_session_state(%{session_state: nil} = state, _update_fn), do: state

  defp update_session_state(%{session_state: ss} = state, update_fn) when not is_nil(ss) do
    updated_ss = update_fn.(ss)
    %{state | session_state: updated_ss}
  end
end
