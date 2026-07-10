defmodule Arbor.Orchestrator.Session.Builders do
  @moduledoc """
  Builder and application helpers for Session turn/heartbeat pipelines.

  Public facade that `Arbor.Orchestrator.Session` delegates to. Heavy lifting
  is delegated to focused submodules:

  - `Session.ContextBuilder` — memory loading + context assembly
  - `Session.ResultProcessor` — result application, proposals, signals
  - `Session.Persistence` — checkpoint management + session entry persistence
  """

  require Logger

  alias Arbor.Orchestrator.Engine
  alias Arbor.Orchestrator.Session.ContextBuilder
  alias Arbor.Orchestrator.Session.ResultProcessor
  alias Arbor.Orchestrator.Session.Persistence

  # ── Compactor initialization ─────────────────────────────────────────

  @doc false
  def init_compactor(nil), do: nil

  def init_compactor({module, compactor_opts}) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :new, 1) do
      apply(module, :new, [compactor_opts])
    else
      Logger.warning("[Session] Compactor module #{inspect(module)} not available, disabling")
      nil
    end
  end

  def init_compactor(_), do: nil

  # ── Context value builders ───────────────────────────────────────────

  @doc false
  @spec build_turn_values(Arbor.Orchestrator.Session.t(), String.t() | map()) :: map()
  def build_turn_values(state, message) do
    build_turn_values(state, message, DateTime.utc_now())
  end

  @doc false
  @spec build_turn_values(Arbor.Orchestrator.Session.t(), String.t() | map(), DateTime.t()) ::
          map()
  def build_turn_values(state, message, now) do
    user_msg = %{
      "role" => "user",
      "content" => normalize_message(message),
      "timestamp" => DateTime.to_iso8601(now)
    }

    # Use compactor's projected view if available, otherwise all messages
    messages = ContextBuilder.compactor_llm_messages(state)
    messages_with_input = messages ++ [user_msg]

    base = ContextBuilder.session_base_values(state)

    Map.merge(base, %{
      "session.messages" => messages_with_input,
      "session.input" => normalize_message(message)
    })
  end

  @doc false
  @spec build_heartbeat_values(Arbor.Orchestrator.Session.t()) :: map()
  def build_heartbeat_values(state) do
    base = ContextBuilder.session_base_values(state)
    agent_id = state.agent_id

    # Load fresh data from the memory store (source of truth),
    # since the Session state may not have them (not populated at session creation).
    goals = ContextBuilder.load_goals_from_memory(agent_id) || Map.get(base, "session.goals", [])

    wm =
      ContextBuilder.load_working_memory_from_memory(agent_id) ||
        Map.get(base, "session.working_memory", %{})

    knowledge_graph = ContextBuilder.load_knowledge_graph(agent_id)
    pending_proposals = ContextBuilder.load_pending_proposals(agent_id)
    active_intents = ContextBuilder.load_active_intents(agent_id)
    recent_thoughts = ContextBuilder.load_recent_thinking(agent_id)

    recent_percepts = ContextBuilder.load_recent_percepts(agent_id)

    base
    |> Map.put("session.messages", [])
    |> Map.put("session.is_heartbeat", true)
    |> Map.put("session.goals", goals)
    |> Map.put("session.working_memory", wm)
    |> Map.put("session.knowledge_graph", knowledge_graph)
    |> Map.put("session.pending_proposals", pending_proposals)
    |> Map.put("session.active_intents", active_intents)
    |> Map.put("session.recent_thinking", recent_thoughts)
    |> Map.put("session.recent_percepts", recent_percepts)
  end

  @doc false
  def build_engine_opts(state, initial_values, opts_overrides \\ []) do
    agent_id = state.agent_id
    session_id = Map.get(state, :session_id) || "heartbeat:#{agent_id}"

    logs_root =
      Path.join([
        System.tmp_dir!(),
        "arbor_sessions",
        session_id
      ])

    opts = [
      session_adapters: Map.get(state, :adapters, %{}),
      logs_root: logs_root,
      max_steps: 100,
      initial_values: initial_values,
      authorization: true,
      execution_principal: agent_id,
      agent_id: agent_id,
      caller_id: agent_id,
      author_id: agent_id,
      session_id: session_id,
      authorizer: build_authorizer(state),
      # Turn/heartbeat runs are in-process and never resumed (the Session owns
      # crash recovery at the session level, not mid-pipeline). Skip writing
      # per-node resume checkpoints — audit stays in the event stream + status.json.
      resumable: false
    ]

    opts =
      if state.signer do
        Keyword.put(opts, :signer, state.signer)
      else
        opts
      end

    # Also inject signer into initial_values (pipeline context) so LlmHandler
    # can access it via Context.get(context, "session.signer"). Engine opts
    # get stripped by Placement.strip_function_opts for RPC safety, but
    # context values survive.
    initial_values =
      if state.signer do
        Map.put(initial_values, "session.signer", state.signer)
      else
        initial_values
      end

    # Steering (mirrors signer): a 0-arity closure the tool loop calls at iteration boundaries
    # to fold mid-turn user messages into the active turn. Put in the CONTEXT (opts get
    # function-stripped for RPC; local turns aren't checkpointed so the closure survives).
    # self() is the Session process here — build_engine_opts runs in it before the turn task
    # spawns, so the closure targets the right GenServer.
    session_pid = self()
    steer_check = fn -> Arbor.Orchestrator.Session.take_steering(session_pid) end
    opts = Keyword.put(opts, :steer_check, steer_check)
    initial_values = Map.put(initial_values, "session.steer_check", steer_check)

    opts = Keyword.put(opts, :initial_values, initial_values)

    # Wire streaming callback with source tag so the dashboard can
    # route turn deltas to chat and heartbeat deltas to the heartbeat panel.
    # Skippable per-session via config["stream"] == false — the tool-use
    # streaming path (complete_streaming) is exercised only when on_stream is set;
    # headless callers (e.g. the eval harness) can opt out to use the plain
    # Client.complete path.
    source = Keyword.get(opts_overrides, :source, :turn)

    if Map.get(state.config || %{}, "stream", true) == false do
      opts
    else
      Keyword.put(opts, :on_stream, build_stream_callback(state, source))
    end
  end

  defp build_authorizer(state) do
    agent_id = state.agent_id
    signer = state.signer
    session_id = Map.get(state, :session_id) || "heartbeat:#{agent_id}"
    task_id = Map.get(state, :task_id)

    fn ^agent_id, _handler_type ->
      # All engine handler types (compute, exec, transform, etc.) are gated by
      # arbor://orchestrator/execute. The signer produces a fresh SignedRequest
      # per check so nonce/timestamp are unique. arbor_security is a hard dep;
      # security_available?/0 remains a runtime liveness gate (CapabilityStore
      # process present) — fail-closed below when required and it's down.
      if Arbor.Orchestrator.Config.security_available?() do
        auth_opts =
          case signer do
            f when is_function(f, 1) ->
              case f.("arbor://orchestrator/execute") do
                {:ok, signed} ->
                  [
                    signed_request: signed,
                    verify_identity: true,
                    expected_resource: "arbor://orchestrator/execute"
                  ]

                _ ->
                  []
              end

            _ ->
              []
          end

        auth_opts =
          auth_opts
          |> Keyword.put(:session_id, session_id)
          |> then(fn opts -> if task_id, do: Keyword.put(opts, :task_id, task_id), else: opts end)

        case Arbor.Security.authorize(
               agent_id,
               "arbor://orchestrator/execute",
               :execute,
               auth_opts
             ) do
          {:ok, :authorized} -> :ok
          {:error, reason} -> {:error, reason}
        end
      else
        # Security unavailable — fail closed unless explicitly configured permissive
        # (standalone orchestrator without arbor_security).
        if Arbor.Orchestrator.Config.security_required?(),
          do: {:error, :security_unavailable},
          else: :ok
      end
    end
  end

  defp build_stream_callback(state, source) do
    agent_id = state.agent_id
    session_id = state.session_id
    session_pid = state.pid

    fn event ->
      case event do
        %{type: :delta, data: data} ->
          text = Map.get(data, :text) || Map.get(data, "text", "")

          # Durable accumulation (streaming partial preservation, Option A): hand
          # each chat-turn chunk to the Session GenServer so the partial survives a
          # turn-task crash/cancel/timeout. The signal below stays for the
          # dashboard's live render. Only :turn streams feed the turn buffer.
          if source == :turn and is_pid(session_pid) and text != "" do
            send(session_pid, {:stream_chunk, text})
          end

          ResultProcessor.emit_signal(:agent, :stream_delta, %{
            agent_id: agent_id,
            session_id: session_id,
            text: text,
            source: source
          })

        %{type: :finish} ->
          ResultProcessor.emit_signal(:agent, :stream_finish, %{
            agent_id: agent_id,
            session_id: session_id,
            source: source
          })

        _ ->
          :ok
      end
    end
  end

  # ── Result application ───────────────────────────────────────────────

  @doc false
  @spec apply_turn_result(
          Arbor.Orchestrator.Session.t(),
          String.t() | map(),
          Engine.run_result(),
          keyword()
        ) :: Arbor.Orchestrator.Session.t()
  def apply_turn_result(state, message, result, opts \\ [])

  def apply_turn_result(state, message, %{context: result_ctx}, opts) do
    alias Arbor.Contracts.Session.{AssistantMessage, UserMessage}
    alias Arbor.Orchestrator.SessionCore

    now = DateTime.utc_now()

    # The user's send-time comes from the typed UserMessage envelope when
    # available (dashboard / future Signal/Discord/Slack adapters carry it).
    # When absent, we fall back to `now` — that's the legacy behavior and
    # is no worse than what was happening before this envelope existed.
    user_sent_at =
      case Keyword.get(opts, :user_message) do
        %UserMessage{sent_at: %DateTime{} = sent_at} -> sent_at
        _ -> now
      end

    # ── Functional core ──────────────────────────────────────────────────────
    # Every *decision* about what this turn becomes — display messages, the typed
    # assistant envelope, the new message list, working memory, turn count, and
    # persistence timestamps — is made here, purely, in one call. (The assistant
    # display msg gets `now`; the user msg its real send time, so they diverge
    # and the SessionStore query gets a real ordering.)
    commit =
      SessionCore.commit_turn(%{
        message: message,
        result_ctx: result_ctx,
        current_messages: ContextBuilder.get_messages(state),
        current_working_memory: ContextBuilder.get_working_memory(state),
        current_turn_count: ContextBuilder.get_turn_count(state),
        now: now,
        user_sent_at: user_sent_at,
        envelope_builder: &AssistantMessage.from_result_ctx/3
      })

    # ── Imperative shell ─────────────────────────────────────────────────────
    # Side effects + state adoption, driven entirely by the pure commit.

    # Compactor (may trigger compaction) + compaction telemetry.
    old_compression_count =
      if state.compactor, do: Map.get(state.compactor, :compression_count, 0), else: 0

    compactor = append_to_compactor(state.compactor, commit.user_msg, commit.assistant_msg)

    if compactor && Map.get(compactor, :compression_count, 0) > old_compression_count do
      utilization =
        if Map.get(compactor, :effective_window, 0) > 0,
          do: Map.get(compactor, :token_count, 0) / compactor.effective_window,
          else: 0.0

      maybe_record_compaction_telemetry(state.agent_id, utilization)
    end

    # Persist to SessionStore — distinct, accurate user/assistant times.
    Persistence.persist_turn_entries(
      state,
      commit.user_msg,
      commit.assistant_message,
      result_ctx,
      user_sent_at: commit.user_sent_at,
      assistant_completed_at: commit.assistant_completed_at
    )

    # Adopt new GenServer state.
    state = %{
      state
      | messages: commit.messages,
        working_memory: commit.working_memory,
        turn_count: commit.turn_count,
        compactor: compactor
    }

    update_session_state(state, fn ss ->
      ss
      |> Map.put(:messages, commit.messages)
      |> Map.put(:working_memory, commit.working_memory)
      |> maybe_call_increment_turn()
    end)
  end

  @doc """
  Finalize an interrupted turn: persist whatever streamed as a partial
  `AssistantMessage` (`:interrupted` for system failures, `:cancelled` for user
  cancel), alongside the in-flight user message.

  A crashed/cancelled/timed-out turn never reached `apply_turn_result`, so neither
  entry was persisted — this persists BOTH from `state.streaming_buffer` +
  `state.turn_user_message`. Called only when the buffer has content (see
  `Session.finalize_partial/3`). Does not mutate session state (the caller resets).
  """
  @spec apply_turn_interruption(Arbor.Orchestrator.Session.t(), atom(), term()) :: :ok
  def apply_turn_interruption(state, status, reason) do
    alias Arbor.Contracts.Session.{AssistantMessage, UserMessage}
    alias Arbor.Orchestrator.SessionCore

    buf = state.streaming_buffer
    now = DateTime.utc_now()
    user_message = state.turn_user_message

    user_sent_at =
      case user_message do
        %UserMessage{sent_at: %DateTime{} = sent_at} -> sent_at
        _ -> buf.started_at
      end

    user_content =
      case user_message do
        %UserMessage{content: content} -> content
        _ -> ""
      end

    user_msg = SessionCore.build_user_message(user_content, user_sent_at)

    assistant_message =
      case status do
        :cancelled ->
          AssistantMessage.cancelled(buf.content, buf.started_at,
            completed_at: now,
            first_token_at: buf.first_token_at
          )

        _ ->
          AssistantMessage.interrupted(buf.content, reason, buf.started_at,
            completed_at: now,
            first_token_at: buf.first_token_at
          )
      end

    Persistence.persist_turn_entries(state, user_msg, assistant_message, %{},
      user_sent_at: user_sent_at,
      assistant_completed_at: now
    )

    :ok
  end

  @doc false
  @spec apply_heartbeat_result(Arbor.Orchestrator.Session.t(), Engine.run_result()) ::
          Arbor.Orchestrator.Session.t()
  def apply_heartbeat_result(state, %{context: result_ctx}) do
    agent_id = state.agent_id

    # Phase 3: heartbeat becomes read-only — generate proposals instead of
    # directly mutating state. The ActionCycleServer reviews proposals.
    proposals = ResultProcessor.Core.generate_heartbeat_proposals(agent_id, state, result_ctx)
    created = ResultProcessor.create_proposals(agent_id, proposals)

    if created > 0 do
      ResultProcessor.emit_notification_percept(agent_id, created, proposals)
    end

    # Persist heartbeat entry to session store (async)
    Persistence.persist_heartbeat_entry(state, result_ctx)

    # Update cognitive_mode from the heartbeat result — this is operational state,
    # not proposal-worthy. Without this update, maybe_add_cognitive_mode_proposal
    # would regenerate a cognitive_mode proposal every heartbeat because the state
    # never reflects the mode selected by select_mode.
    case Map.get(result_ctx, "session.cognitive_mode") do
      mode when is_binary(mode) and mode != "" ->
        try do
          atom_mode = String.to_existing_atom(mode)
          %{state | cognitive_mode: atom_mode}
        rescue
          ArgumentError -> state
        end

      _ ->
        state
    end
  end

  # Delegate to ResultProcessor
  @doc false
  defdelegate apply_goal_changes(existing_goals, updates, new_goals), to: ResultProcessor.Core

  # ── Signal emission ──────────────────────────────────────────────────

  @doc false
  defdelegate emit_turn_signal(state, result), to: ResultProcessor
  @doc false
  defdelegate emit_heartbeat_signal(state, result), to: ResultProcessor
  @doc false
  defdelegate emit_signal(category, event, data), to: ResultProcessor
  @doc false
  def emit_signal(category, event, data, tenant_context),
    do: ResultProcessor.emit_signal(category, event, data, tenant_context)

  # ── Checkpoint management ────────────────────────────────────────────

  @doc false
  defdelegate apply_checkpoint(state, checkpoint), to: Persistence
  @doc false
  defdelegate maybe_checkpoint(state), to: Persistence
  @doc false
  defdelegate extract_checkpoint_data(state), to: Persistence
  @doc false
  defdelegate maybe_restore(state, field, value), to: Persistence
  @doc false
  defdelegate maybe_restore_cognitive_mode(state, mode), to: Persistence
  @doc false
  defdelegate sync_checkpoint_to_session_state(state), to: Persistence

  # ── Contract struct helpers ──────────────────────────────────────────

  @doc false
  def contracts_available? do
    Code.ensure_loaded?(config_module()) and
      Code.ensure_loaded?(state_module()) and
      Code.ensure_loaded?(behavior_module())
  end

  @doc false
  def build_contract_structs(opts) do
    if contracts_available?() do
      session_config = build_session_config(opts)
      session_state = build_session_state(opts)
      behavior = build_behavior(opts)
      {session_config, session_state, behavior}
    else
      {nil, nil, nil}
    end
  end

  # ── DOT parsing ──────────────────────────────────────────────────────

  @doc false
  def parse_dot_file(path) do
    with {:ok, source} <- File.read(path) do
      Arbor.Orchestrator.parse(source)
    end
  end

  # ── Message normalization ────────────────────────────────────────────

  @doc false
  defdelegate normalize_message(message), to: Arbor.Orchestrator.SessionCore

  @doc false
  def safe_to_atom(string, fallback) do
    String.to_existing_atom(string)
  rescue
    ArgumentError -> fallback
  end

  @doc false
  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, key, value), do: Map.put(map, key, value)

  # ── Compactor helpers ─────────────────────────────────────────────

  @doc false
  def append_to_compactor(nil, _user_msg, _assistant_msg), do: nil

  def append_to_compactor(compactor, user_msg, assistant_msg) do
    compactor = apply_compactor(compactor, :append, [user_msg])

    compactor =
      if assistant_msg do
        apply_compactor(compactor, :append, [assistant_msg])
      else
        compactor
      end

    apply_compactor(compactor, :maybe_compact, [])
  end

  @doc false
  def apply_compactor(%{__struct__: module} = compactor, fun, args) do
    apply(module, fun, [compactor | args])
  end

  # ── Contract struct construction helpers (private) ────────────────

  @doc false
  def build_session_state(opts) do
    case apply(state_module(), :new, [[trace_id: Keyword.get(opts, :trace_id)]]) do
      {:ok, session_state} ->
        session_state

      {:error, reason} ->
        Logger.warning("[Session] Failed to create Session.State: #{inspect(reason)}, using nil")

        nil
    end
  end

  @doc false
  def build_behavior(opts) do
    case Keyword.get(opts, :behavior) do
      nil ->
        case apply(behavior_module(), :default, []) do
          {:ok, behavior} -> behavior
          _ -> nil
        end

      %{__struct__: _} = behavior ->
        behavior

      _other ->
        Logger.warning("[Session] Invalid behavior option, using default")

        case apply(behavior_module(), :default, []) do
          {:ok, behavior} -> behavior
          _ -> nil
        end
    end
  end

  # ── Private helpers ──────────────────────────────────────────────────

  defp build_session_config(opts) do
    case apply(config_module(), :new, [
           [
             session_id: Keyword.fetch!(opts, :session_id),
             agent_id: Keyword.fetch!(opts, :agent_id),
             session_type: Keyword.get(opts, :session_type, :primary),
             metadata: Keyword.get(opts, :config, %{})
           ]
         ]) do
      {:ok, config} ->
        config

      {:error, reason} ->
        Logger.warning("[Session] Failed to create Session.Config: #{inspect(reason)}, using nil")

        nil
    end
  end

  defp update_session_state(%{session_state: nil} = state, _update_fn), do: state

  defp update_session_state(%{session_state: ss} = state, update_fn) when not is_nil(ss) do
    updated_ss = update_fn.(ss)
    %{state | session_state: updated_ss}
  end

  defp maybe_call_increment_turn(ss) do
    if contracts_available?() do
      apply(state_module(), :increment_turn, [ss])
    else
      %{ss | turn_count: ss.turn_count + 1}
    end
  end

  # Module references via functions to avoid compile-time warnings
  defp config_module, do: Arbor.Contracts.Session.Config
  defp state_module, do: Arbor.Contracts.Session.State
  defp behavior_module, do: Arbor.Contracts.Session.Behavior

  defp maybe_record_compaction_telemetry(agent_id, utilization) do
    store = Arbor.Common.AgentTelemetry.Store

    if Code.ensure_loaded?(store) do
      store.record_compaction(agent_id, utilization)
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # The assistant turn's LLM-call start time, derived from the recorded call
  # duration (`session.usage.duration_ms`) — i.e. `completed_at - duration_ms`.
  # Clamped to never precede `user_sent_at` so the persisted assistant entry can
  # never sort before the user entry on equal-ish timestamps.
end
