defmodule Arbor.Orchestrator.Session.Persistence do
  @moduledoc """
  Session transcript persistence and explicit checkpoint import/export.

  Persistence's session transcript store owns automatic conversation recovery.
  Session restores only the selected named engagement and rebuilds its compactor.
  Volatile turn state is not a recoverable snapshot; Engine job recovery and
  agent-owned memory have separate owners.

  Explicit checkpoint codec/import helpers remain available to callers. The
  former `checkpoint_save` adapter is retired: detached whole-state writes had
  no production reader or stale-save fence and must not compete with transcripts.

  Successful turn commits use `persist_turn_entries/5`, which awaits one
  acknowledged user/assistant pair. Partial and cancelled turns use
  `persist_turn_entries_async/5`, which is fire-and-forget and must not be used
  on the acknowledged success path.
  """

  require Logger

  alias Arbor.Orchestrator.Session.ContextBuilder
  alias Arbor.Orchestrator.Session.Persistence.Core

  # Matches the bounded history admitted by the legacy load_entries path.
  @engagement_transcript_limit 1_000
  @commit_timeout_ms 10_000
  @commit_reap_ms 1_000
  @turn_persistence_errors [
    :turn_persistence_unavailable,
    :turn_persistence_malformed,
    :turn_persistence_failed,
    :turn_persistence_raised,
    :turn_persistence_uncertain
  ]

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

  # ── Explicit checkpoint codec (no automatic snapshot writer) ──────

  @doc "Compatibility no-op: acknowledged transcripts are the automatic recovery source."
  def maybe_checkpoint(state), do: state

  @doc false
  def extract_checkpoint_data(state) do
    engagement_id = Map.get(state, :current_engagement_id)
    scope = checkpoint_scope(state, engagement_id)

    with {:ok, %{messages: messages, manifest: manifest}} <-
           Core.encode_checkpoint_messages(ContextBuilder.get_messages(state), scope) do
      %{
        "messages" => messages,
        "messages_manifest" => manifest,
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

  # ── Compactor seeding from checkpoint ─────────────────────────────

  # Seed compactor with restored checkpoint messages so it can track them.
  # Without this, a restored session would have messages in state but an
  # empty compactor — it would never compact because it thinks it has 0 tokens.
  @doc false
  def rebuild_compactor_from_checkpoint(%{compactor_spec: spec, messages: messages} = state)
      when is_list(messages) do
    %{state | compactor: ContextBuilder.init_compactor(spec, messages)}
  end

  # Legacy state cannot safely prove which transcript produced its compactor.
  def rebuild_compactor_from_checkpoint(state), do: Map.put(state, :compactor, nil)

  defp cp_fetch(data, field) do
    case Map.fetch(data, "session.#{field}") do
      :error -> Map.fetch(data, field)
      found -> found
    end
  end

  defp restore_checkpoint_messages(state, data, engagement) do
    case {cp_fetch(data, "messages"), cp_fetch(data, "messages_manifest")} do
      {:error, :error} ->
        # Omission cannot distinguish a legacy partial update from a stripped
        # current checkpoint. Legacy compatibility requires a present plain
        # message list, which Core reconstructs conservatively.
        {:error, :checkpoint_transcript_missing}

      {:error, {:ok, _orphaned_manifest}} ->
        {:error, :checkpoint_messages_missing}

      {{:ok, persisted_messages}, manifest} ->
        persisted_manifest =
          case manifest do
            {:ok, value} -> value
            :error -> :missing
          end

        case engagement do
          {:ok, engagement_id} when is_binary(engagement_id) or is_nil(engagement_id) ->
            Core.restore_checkpoint_messages(
              persisted_messages,
              persisted_manifest,
              checkpoint_scope(state, engagement_id)
            )

          :error ->
            Core.restore_checkpoint_messages(persisted_messages, persisted_manifest, :missing)

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

  defp drop_active_engagement_stash(state) do
    engagement_id = Map.get(state, :current_engagement_id)

    %{
      state
      | transcripts: Map.delete(Map.get(state, :transcripts, %{}), engagement_id),
        compactors: Map.delete(Map.get(state, :compactors, %{}), engagement_id)
    }
  end

  # ── Session entry persistence ─────────────────────────────────────

  # Bounds the caller's wait by commit_timeout_ms (default 10000, never :infinity)
  # plus one @commit_reap_ms cleanup window. Steering/cancel stay queued until return.
  @doc false
  @spec persist_turn_entries(map(), term(), term(), term(), keyword()) ::
          {:ok, 2}
          | {:error,
             :turn_persistence_unavailable
             | :turn_persistence_malformed
             | :turn_persistence_failed
             | :turn_persistence_raised
             | :turn_persistence_uncertain}
  def persist_turn_entries(state, user_msg, assistant_message, run_result, opts \\ []) do
    case build_turn_entry_pair(state, user_msg, assistant_message, run_result, opts) do
      {:ok, entries} ->
        await_turn_persistence(state, entries)

      {:error, :turn_persistence_unavailable} = error ->
        Logger.warning("[Session] Turn persistence failed reason=turn_persistence_unavailable")
        error
    end
  end

  # Fire-and-forget pair append for partial/cancel only. Always returns :ok.
  # Must not be used on the acknowledged success path.
  @doc false
  @spec persist_turn_entries_async(map(), term(), term(), term(), keyword()) :: :ok
  def persist_turn_entries_async(state, user_msg, assistant_message, run_result, opts \\ []) do
    case build_turn_entry_pair(state, user_msg, assistant_message, run_result, opts) do
      {:ok, entries} ->
        ensure_session = get_ensure_session_fn(state)
        append_entries = get_persist_entries_fn(state)
        session_id = state.session_id
        agent_id = state.agent_id

        Task.start(fn ->
          case classify_turn_batch(
                 ensure_session,
                 append_entries,
                 session_id,
                 agent_id,
                 entries
               ) do
            {:ok, 2} ->
              :ok

            {:error, atom} ->
              Logger.warning("[Session] Atomic turn entry persistence failed reason=#{atom}")
          end
        end)

        :ok

      {:error, :turn_persistence_unavailable} ->
        Logger.warning("[Session] Turn persistence failed reason=turn_persistence_unavailable")
        :ok
    end
  end

  defp build_turn_entry_pair(state, user_msg, assistant_message, run_result, opts) do
    user_sent_at = Keyword.get(opts, :user_sent_at) || DateTime.utc_now()
    assistant_completed_at = Keyword.get(opts, :assistant_completed_at) || DateTime.utc_now()

    case Core.build_turn_entries(%{
           user_message: user_msg,
           assistant_message: assistant_message,
           run_result: run_result,
           user_sent_at: user_sent_at,
           assistant_completed_at: assistant_completed_at,
           engagement_id: Map.get(state, :current_engagement_id),
           private_memory_source: Keyword.get(opts, :private_memory_source),
           turn_count: ContextBuilder.get_turn_count(state)
         }) do
      {:ok, [_, _] = entries} -> {:ok, entries}
      {:error, _reason} -> {:error, :turn_persistence_unavailable}
    end
  end

  # Commit-guard protocol (private, Session-owned, no named supervisor):
  # - Caller (Session) stamps deadline_mono, spawn_monitors one guard, then
  #   selectively receives only {reply_ref, payload, completed_mono}, the guard
  #   DOWN, or the commit deadline. Unrelated mailbox messages stay in place.
  #   Session does not trap_exit and does not monitor the writer.
  # - Guard traps exits, monitors the owner, spawn_links one writer, owns the
  #   absolute deadline, and reaps the writer (kill + confirmed EXIT) on
  #   timeout, :settle, owner loss, or completion. Unconfirmed reap cannot
  #   publish {:ok, 2}. Guard death kills the linked writer.
  # - Writer does not trap; it runs one ensure_session + append_session_entries
  #   only if the deadline has not already passed.
  # - Tags are {reply_ref, payload, completed_mono} with completed_mono stamped
  #   immediately before send. On-time iff integer stamp <= deadline_mono.
  #   Late {:ok, 2} is :turn_persistence_uncertain. Late/stale tags must not
  #   produce a second reply or append. Per-turn cost is one guard + one writer
  #   for the bounded wait; trap_exit stays off Session so they are not folded.
  defp await_turn_persistence(state, entries) do
    owner = self()
    reply_ref = make_ref()
    deadline_mono = System.monotonic_time(:millisecond) + commit_timeout_ms(state)

    args = %{
      owner: owner,
      reply_ref: reply_ref,
      deadline_mono: deadline_mono,
      ensure_session: get_ensure_session_fn(state),
      append_entries: get_persist_entries_fn(state),
      session_id: state.session_id,
      agent_id: state.agent_id,
      entries: entries
    }

    {guard, guard_mon} = spawn_monitor(fn -> run_commit_guard(args) end)
    await_guard_result(reply_ref, guard, guard_mon, deadline_mono)
  end

  defp await_guard_result(reply_ref, guard, guard_mon, deadline_mono) do
    receive do
      {^reply_ref, payload, completed_mono} ->
        classified = classify_tagged_payload(payload, completed_mono, deadline_mono)
        finish_caller(classified, reply_ref, guard, guard_mon)

      {:DOWN, ^guard_mon, :process, ^guard, reason} ->
        case take_tagged(reply_ref) do
          {payload, stamp} ->
            classified = classify_tagged_payload(payload, stamp, deadline_mono)
            flush_tagged(reply_ref)
            classified

          :empty ->
            {:error, down_reason(reason)}
        end
    after
      remaining_ms(deadline_mono) ->
        settle_guard(reply_ref, guard, guard_mon, {:error, :turn_persistence_uncertain})
    end
  end

  defp finish_caller({:ok, 2}, reply_ref, _guard, guard_mon) do
    Process.demonitor(guard_mon, [:flush])
    flush_tagged(reply_ref)
    {:ok, 2}
  end

  defp finish_caller({:error, atom}, reply_ref, guard, guard_mon) do
    settle_guard(reply_ref, guard, guard_mon, {:error, atom})
  end

  defp settle_guard(reply_ref, guard, guard_mon, result) do
    if is_pid(guard) and Process.alive?(guard) do
      send(guard, {:settle, reply_ref})
    end

    reap_deadline = System.monotonic_time(:millisecond) + @commit_reap_ms
    down? = await_guard_down(reply_ref, guard, guard_mon, false, reap_deadline)

    down? =
      if down? do
        true
      else
        if is_pid(guard) and Process.alive?(guard), do: Process.exit(guard, :kill)
        await_guard_down(reply_ref, guard, guard_mon, false, reap_deadline)
      end

    _ = down?
    if is_reference(guard_mon), do: Process.demonitor(guard_mon, [:flush])
    flush_tagged(reply_ref)
    result
  end

  defp await_guard_down(_reply_ref, _guard, _guard_mon, true, _reap_deadline), do: true

  defp await_guard_down(reply_ref, guard, guard_mon, false, reap_deadline) do
    receive do
      {^reply_ref, _payload, _stamp} ->
        await_guard_down(reply_ref, guard, guard_mon, false, reap_deadline)

      {:DOWN, ^guard_mon, :process, ^guard, _reason} ->
        true
    after
      remaining_ms(reap_deadline) ->
        false
    end
  end

  defp run_commit_guard(args) do
    Process.flag(:trap_exit, true)
    owner = args.owner
    owner_mon = Process.monitor(owner)

    cond do
      not Process.alive?(owner) ->
        exit(:normal)

      not on_time?(System.monotonic_time(:millisecond), args.deadline_mono) ->
        reply_owner(
          owner,
          args.reply_ref,
          {:error, :turn_persistence_uncertain},
          args.deadline_mono
        )

        exit(:normal)

      true ->
        guard = self()

        writer =
          spawn_link(fn ->
            result = run_writer_batch(args)
            send(guard, {:writer_done, result})
          end)

        guard_loop(args, owner, owner_mon, writer)
    end
  end

  defp run_writer_batch(args) do
    if on_time?(System.monotonic_time(:millisecond), args.deadline_mono) do
      classify_turn_batch(
        args.ensure_session,
        args.append_entries,
        args.session_id,
        args.agent_id,
        args.entries
      )
    else
      {:error, :turn_persistence_uncertain}
    end
  end

  defp guard_loop(args, owner, owner_mon, writer) do
    deadline_mono = args.deadline_mono
    reply_ref = args.reply_ref

    receive do
      {:writer_done, result} ->
        done_mono = System.monotonic_time(:millisecond)

        classified =
          if on_time?(done_mono, deadline_mono),
            do: result,
            else: {:error, :turn_persistence_uncertain}

        finish_guard(owner, reply_ref, classified, deadline_mono, writer, true)

      {:settle, ^reply_ref} ->
        finish_guard(
          owner,
          reply_ref,
          {:error, :turn_persistence_uncertain},
          deadline_mono,
          writer,
          true
        )

      {:DOWN, ^owner_mon, :process, ^owner, _reason} ->
        finish_guard(
          owner,
          reply_ref,
          {:error, :turn_persistence_uncertain},
          deadline_mono,
          writer,
          false
        )

      {:EXIT, ^writer, _reason} ->
        reply_owner(owner, reply_ref, {:error, :turn_persistence_raised}, deadline_mono)
        exit(:normal)

      {:EXIT, _other, _reason} ->
        guard_loop(args, owner, owner_mon, writer)

      {:DOWN, _ref, :process, _pid, _reason} ->
        guard_loop(args, owner, owner_mon, writer)
    after
      remaining_ms(deadline_mono) ->
        finish_guard(
          owner,
          reply_ref,
          {:error, :turn_persistence_uncertain},
          deadline_mono,
          writer,
          true
        )
    end
  end

  defp finish_guard(owner, reply_ref, classified, deadline_mono, writer, send?) do
    reap = reap_writer(writer)

    payload =
      if classified == {:ok, 2} and reap != :confirmed do
        {:error, :turn_persistence_uncertain}
      else
        classified
      end

    if send?, do: reply_owner(owner, reply_ref, payload, deadline_mono)
    exit(:normal)
  end

  defp reap_writer(writer) do
    Process.exit(writer, :kill)
    confirm_writer_exit(writer)
  end

  defp confirm_writer_exit(writer) do
    receive do
      {:EXIT, ^writer, _} -> :confirmed
      {:writer_done, _} -> confirm_writer_exit(writer)
    after
      @commit_reap_ms -> :unconfirmed
    end
  end

  defp reply_owner(owner, reply_ref, classified, deadline_mono) do
    if Process.alive?(owner) do
      completed_mono = System.monotonic_time(:millisecond)

      payload =
        if classified == {:ok, 2} and not on_time?(completed_mono, deadline_mono) do
          {:error, :turn_persistence_uncertain}
        else
          classified
        end

      send(owner, {reply_ref, payload, completed_mono})
    end

    :ok
  end

  defp classify_turn_batch(ensure_session, append_entries, session_id, agent_id, entries) do
    try do
      with {:ok, %{id: session_uuid}} when is_binary(session_uuid) <-
             ensure_session.(session_id, agent_id, []),
           {:ok, 2} <- append_entries.(session_uuid, entries) do
        {:ok, 2}
      else
        {:error, _reason} -> {:error, :turn_persistence_failed}
        _other -> {:error, :turn_persistence_malformed}
      end
    rescue
      _ -> {:error, :turn_persistence_raised}
    catch
      :throw, _ -> {:error, :turn_persistence_raised}
      :exit, _ -> {:error, :turn_persistence_raised}
    end
  end

  defp classify_tagged_payload(payload, stamp, deadline) do
    cond do
      not is_integer(stamp) ->
        {:error, :turn_persistence_malformed}

      stamp > deadline ->
        {:error, :turn_persistence_uncertain}

      payload == {:ok, 2} ->
        {:ok, 2}

      match?({:error, atom} when atom in @turn_persistence_errors, payload) ->
        payload

      true ->
        {:error, :turn_persistence_malformed}
    end
  end

  defp on_time?(stamp, deadline) when is_integer(stamp) and stamp <= deadline, do: true
  defp on_time?(_stamp, _deadline), do: false

  defp remaining_ms(deadline_mono) do
    rem = deadline_mono - System.monotonic_time(:millisecond)
    if rem > 0, do: rem, else: 0
  end

  defp commit_timeout_ms(state) do
    config = Map.get(state, :config) || %{}

    candidates = [
      Map.get(config, :turn_commit_timeout_ms),
      Map.get(config, "turn_commit_timeout_ms")
    ]

    case Enum.find(candidates, &finite_commit_timeout?/1) do
      ms when is_integer(ms) -> ms
      _ -> @commit_timeout_ms
    end
  end

  defp finite_commit_timeout?(ms) when is_integer(ms) and ms > 0 and ms <= @commit_timeout_ms,
    do: true

  defp finite_commit_timeout?(_), do: false

  defp down_reason(:killed), do: :turn_persistence_uncertain
  defp down_reason(_reason), do: :turn_persistence_raised

  defp take_tagged(reply_ref) do
    receive do
      {^reply_ref, payload, stamp} -> {payload, stamp}
    after
      0 -> :empty
    end
  end

  defp flush_tagged(reply_ref) do
    receive do
      {^reply_ref, _payload, _stamp} -> flush_tagged(reply_ref)
      {^reply_ref, _other} -> flush_tagged(reply_ref)
    after
      0 -> :ok
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
  `config["recover_session"] == false` disables this read. The unscoped default
  engagement is never restored from the aggregate display projection.
  """
  @spec load_engagement_transcript(map(), String.t() | nil) :: [map()]
  def load_engagement_transcript(_state, nil), do: []

  def load_engagement_transcript(%{config: %{"recover_session" => false}}, _engagement_id),
    do: []

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
  def load_private_memory_sources(state) do
    # Recovery spans engagements only within this stable Session id. Use the
    # same source-owned transcript reader as ordinary restoration.
    get_load_session_messages_fn(state).(state.session_id, limit: 1_000)
  rescue
    _ -> {:error, :private_memory_recovery_unavailable}
  catch
    _, _ -> {:error, :private_memory_recovery_unavailable}
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
