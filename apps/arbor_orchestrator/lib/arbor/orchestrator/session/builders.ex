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
    user_msg = %{
      "role" => "user",
      "content" => normalize_message(message),
      "timestamp" => DateTime.to_iso8601(DateTime.utc_now())
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
    logs_root =
      Path.join([
        System.tmp_dir!(),
        "arbor_sessions",
        state.session_id
      ])

    opts = [
      session_adapters: state.adapters,
      logs_root: logs_root,
      max_steps: 100,
      initial_values: initial_values,
      authorization: true,
      authorizer: build_authorizer(state)
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

    opts = Keyword.put(opts, :initial_values, initial_values)

    # Wire streaming callback with source tag so the dashboard can
    # route turn deltas to chat and heartbeat deltas to the heartbeat panel.
    source = Keyword.get(opts_overrides, :source, :turn)
    Keyword.put(opts, :on_stream, build_stream_callback(state, source))
  end

  defp build_authorizer(state) do
    agent_id = state.agent_id
    signer = state.signer

    fn ^agent_id, _handler_type ->
      # All engine handler types (compute, exec, transform, etc.) are gated by
      # arbor://orchestrator/execute. The signer produces a fresh SignedRequest
      # per check so nonce/timestamp are unique.
      security_mod = Module.concat([:Arbor, :Security])

      if Code.ensure_loaded?(security_mod) do
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

        case apply(security_mod, :authorize, [
               agent_id,
               "arbor://orchestrator/execute",
               :execute,
               auth_opts
             ]) do
          {:ok, :authorized} -> :ok
          {:error, reason} -> {:error, reason}
        end
      else
        # Security module not available — allow (permissive fallback)
        :ok
      end
    end
  end

  defp build_stream_callback(state, source) do
    agent_id = state.agent_id
    session_id = state.session_id

    fn event ->
      case event do
        %{type: :delta, data: data} ->
          text = Map.get(data, :text) || Map.get(data, "text", "")

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
  @spec apply_turn_result(Arbor.Orchestrator.Session.t(), String.t() | map(), Engine.run_result()) ::
          Arbor.Orchestrator.Session.t()
  def apply_turn_result(state, message, %{context: result_ctx}) do
    alias Arbor.Orchestrator.SessionCore

    response = Map.get(result_ctx, "session.response", "")
    now = DateTime.utc_now()

    # Pure: build message structs via SessionCore
    user_msg = SessionCore.build_user_message(message, now)
    assistant_msg = SessionCore.build_assistant_message(response, now)

    # Pure: update message list
    updated_messages =
      case Map.get(result_ctx, "session.messages") do
        msgs when is_list(msgs) ->
          if assistant_msg, do: msgs ++ [assistant_msg], else: msgs

        _ ->
          base = ContextBuilder.get_messages(state) ++ [user_msg]
          if assistant_msg, do: base ++ [assistant_msg], else: base
      end

    updated_wm =
      case Map.get(result_ctx, "session.working_memory") do
        wm when is_map(wm) -> wm
        _ -> ContextBuilder.get_working_memory(state)
      end

    # Pure: increment turn count
    new_turn_count =
      state
      |> ContextBuilder.get_turn_count()
      |> SessionCore.increment_turn()

    # Side effect: compactor (may trigger compaction)
    old_compression_count =
      if state.compactor, do: Map.get(state.compactor, :compression_count, 0), else: 0

    compactor = append_to_compactor(state.compactor, user_msg, assistant_msg)

    # Side effect: telemetry recording
    if compactor && Map.get(compactor, :compression_count, 0) > old_compression_count do
      utilization =
        if Map.get(compactor, :effective_window, 0) > 0,
          do: Map.get(compactor, :token_count, 0) / compactor.effective_window,
          else: 0.0

      maybe_record_compaction_telemetry(state.agent_id, utilization)
    end

    # Side effect: persist to SessionStore
    Persistence.persist_turn_entries(
      state,
      now,
      user_msg,
      assistant_msg || %{"role" => "assistant", "content" => ""},
      result_ctx
    )

    # Update GenServer state
    state = %{
      state
      | messages: updated_messages,
        working_memory: updated_wm,
        turn_count: new_turn_count,
        compactor: compactor
    }

    update_session_state(state, fn ss ->
      ss
      |> Map.put(:messages, updated_messages)
      |> Map.put(:working_memory, updated_wm)
      |> maybe_call_increment_turn()
    end)
  end

  @doc false
  @spec apply_heartbeat_result(Arbor.Orchestrator.Session.t(), Engine.run_result()) ::
          Arbor.Orchestrator.Session.t()
  def apply_heartbeat_result(state, %{context: result_ctx}) do
    agent_id = state.agent_id

    # Phase 3: heartbeat becomes read-only — generate proposals instead of
    # directly mutating state. The ActionCycleServer reviews proposals.
    proposals = ResultProcessor.generate_heartbeat_proposals(agent_id, state, result_ctx)
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
  defdelegate apply_goal_changes(existing_goals, updates, new_goals), to: ResultProcessor

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

  # ── Trust tier verification ──────────────────────────────────────────

  @doc false
  def verify_trust_tier(declared_tier, agent_id, adapters) do
    case Map.get(adapters, :trust_tier_resolver) do
      resolver when is_function(resolver, 1) ->
        case resolver.(agent_id) do
          {:ok, verified_tier} -> verified_tier
          _ -> declared_tier
        end

      _ ->
        declared_tier
    end
  end

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
             trust_tier: Keyword.fetch!(opts, :trust_tier),
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
end
