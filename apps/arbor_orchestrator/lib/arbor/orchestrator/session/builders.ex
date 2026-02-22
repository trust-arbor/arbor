defmodule Arbor.Orchestrator.Session.Builders do
  @moduledoc """
  Builder and application helpers for Session turn/heartbeat pipelines.

  Extracted from `Arbor.Orchestrator.Session` to reduce module size.
  Contains context value builders, result application, signal emission,
  checkpoint management, contract struct construction, and related utilities.
  """

  require Logger

  alias Arbor.Orchestrator.Engine

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
    messages = compactor_llm_messages(state)
    messages_with_input = messages ++ [user_msg]

    base = session_base_values(state)

    Map.merge(base, %{
      "session.messages" => messages_with_input,
      "session.input" => normalize_message(message)
    })
  end

  @doc false
  @spec build_heartbeat_values(Arbor.Orchestrator.Session.t()) :: map()
  def build_heartbeat_values(state) do
    base = session_base_values(state)
    agent_id = state.agent_id

    # Load fresh data from the memory store (source of truth),
    # since the Session state may not have them (not populated at session creation).
    goals = load_goals_from_memory(agent_id) || Map.get(base, "session.goals", [])
    wm = load_working_memory_from_memory(agent_id) || Map.get(base, "session.working_memory", %{})
    knowledge_graph = load_knowledge_graph(agent_id)
    pending_proposals = load_pending_proposals(agent_id)
    active_intents = load_active_intents(agent_id)
    recent_thoughts = load_recent_thinking(agent_id)

    recent_percepts = load_recent_percepts(agent_id)

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
  def session_base_values(state) do
    %{
      "session.id" => state.session_id,
      "session.agent_id" => state.agent_id,
      "session.trust_tier" => to_string(state.trust_tier),
      "session.turn_count" => get_turn_count(state),
      "session.working_memory" => get_working_memory(state),
      "session.goals" => get_goals(state),
      "session.cognitive_mode" => to_string(get_cognitive_mode(state)),
      "session.phase" => to_string(get_phase(state)),
      "session.session_type" => to_string(state.session_type),
      "session.trace_id" => state.trace_id,
      "session.config" => state.config,
      "session.signal_topic" => state.signal_topic
    }
  end

  @doc false
  def build_engine_opts(state, initial_values) do
    logs_root =
      Path.join([
        System.tmp_dir!(),
        "arbor_sessions",
        state.session_id
      ])

    [
      session_adapters: state.adapters,
      logs_root: logs_root,
      max_steps: 100,
      initial_values: initial_values,
      authorization: false
    ]
  end

  # ── Result application ───────────────────────────────────────────────

  @doc false
  @spec apply_turn_result(Arbor.Orchestrator.Session.t(), String.t() | map(), Engine.run_result()) ::
          Arbor.Orchestrator.Session.t()
  def apply_turn_result(state, message, %{context: result_ctx}) do
    response = Map.get(result_ctx, "session.response", "")
    now = DateTime.utc_now()
    now_iso = DateTime.to_iso8601(now)

    user_msg = %{
      "role" => "user",
      "content" => normalize_message(message),
      "timestamp" => now_iso
    }

    assistant_msg = %{"role" => "assistant", "content" => response, "timestamp" => now_iso}

    updated_messages =
      case Map.get(result_ctx, "session.messages") do
        msgs when is_list(msgs) ->
          msgs ++ [assistant_msg]

        _ ->
          get_messages(state) ++ [user_msg, assistant_msg]
      end

    updated_wm =
      case Map.get(result_ctx, "session.working_memory") do
        wm when is_map(wm) -> wm
        _ -> get_working_memory(state)
      end

    new_turn_count = get_turn_count(state) + 1

    # Append messages to compactor and run compaction
    compactor = append_to_compactor(state.compactor, user_msg, assistant_msg)

    # Persist turn entries to session store (async)
    persist_turn_entries(state, now, user_msg, assistant_msg, result_ctx)

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
    proposals = generate_heartbeat_proposals(agent_id, state, result_ctx)
    created = create_proposals(agent_id, proposals)

    if created > 0 do
      emit_notification_percept(agent_id, created, proposals)
    end

    # Persist heartbeat entry to session store (async)
    persist_heartbeat_entry(state, result_ctx)

    # Return state UNMODIFIED — action cycle will review proposals
    state
  end

  @doc false
  def apply_goal_changes(existing_goals, updates, new_goals) do
    updated =
      Enum.map(existing_goals, fn goal ->
        case Enum.find(updates, &(Map.get(&1, "id") == Map.get(goal, "id"))) do
          nil -> goal
          update -> Map.merge(goal, update)
        end
      end)

    updated ++ List.wrap(new_goals)
  end

  # ── Signal emission (runtime bridge) ──────────────────────────────

  @doc false
  def emit_turn_signal(state, %{context: result_ctx}) do
    tool_calls = Map.get(result_ctx, "session.tool_calls", [])
    response = Map.get(result_ctx, "session.response", "")

    emit_signal(:agent, :query_completed, %{
      id: state.agent_id,
      agent_id: state.agent_id,
      session_id: state.session_id,
      type: :session,
      model: Map.get(result_ctx, "llm.model", "unknown"),
      tool_calls_count: length(List.wrap(tool_calls)),
      response_length: String.length(response),
      turn_count: get_turn_count(state)
    })
  end

  def emit_turn_signal(_state, _result), do: :ok

  @doc false
  def emit_heartbeat_signal(state, %{context: result_ctx}) do
    actions = Map.get(result_ctx, "session.actions", [])
    goal_updates = Map.get(result_ctx, "session.goal_updates", [])
    new_goals = Map.get(result_ctx, "session.new_goals", [])
    memory_notes = Map.get(result_ctx, "session.memory_notes", [])
    cognitive_mode = Map.get(result_ctx, "session.cognitive_mode", "reflection")
    concerns = Map.get(result_ctx, "session.concerns", [])
    curiosity = Map.get(result_ctx, "session.curiosity", [])
    identity_insights = Map.get(result_ctx, "session.identity_insights", [])
    decompositions = Map.get(result_ctx, "session.decompositions", [])
    proposal_decisions = Map.get(result_ctx, "session.proposal_decisions", [])

    emit_signal(:agent, :heartbeat_complete, %{
      agent_id: state.agent_id,
      session_id: state.session_id,
      cognitive_mode: cognitive_mode,
      actions: List.wrap(actions),
      llm_actions: length(List.wrap(actions)),
      goal_updates_count: length(List.wrap(goal_updates)) + length(List.wrap(new_goals)),
      memory_notes_count: length(List.wrap(memory_notes)),
      memory_notes: List.wrap(memory_notes),
      concerns: List.wrap(concerns),
      curiosity: List.wrap(curiosity),
      identity_insights: List.wrap(identity_insights),
      decompositions: List.wrap(decompositions),
      proposal_decisions: List.wrap(proposal_decisions),
      goal_updates: List.wrap(goal_updates),
      new_goals: List.wrap(new_goals),
      agent_thinking: Map.get(result_ctx, "llm.content"),
      completed_nodes: Map.get(result_ctx, "__completed_nodes__", [])
    })
  end

  def emit_heartbeat_signal(_state, _result), do: :ok

  @doc false
  def emit_signal(category, event, data) do
    if Code.ensure_loaded?(Arbor.Signals) and
         function_exported?(Arbor.Signals, :emit, 4) and
         Process.whereis(Arbor.Signals.Bus) != nil do
      agent_id = data[:agent_id]
      meta = if agent_id, do: %{agent_id: agent_id}, else: %{}
      apply(Arbor.Signals, :emit, [category, event, data, [metadata: meta]])
    end
  rescue
    _ -> :ok
  end

  # ── Checkpoint management ───────────────────────────────────────────

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
  defp cp_get(data, field) do
    Map.get(data, "session.#{field}") || Map.get(data, field)
  end

  @doc false
  def maybe_restore(state, _field, nil), do: state
  def maybe_restore(state, field, value), do: %{state | field => value}

  @doc false
  def maybe_restore_cognitive_mode(state, nil), do: state

  def maybe_restore_cognitive_mode(state, mode) when is_atom(mode),
    do: %{state | cognitive_mode: mode}

  def maybe_restore_cognitive_mode(state, mode) when is_binary(mode),
    do: %{state | cognitive_mode: safe_to_atom(mode, state.cognitive_mode)}

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

  # ── Session checkpoint persistence ──────────────────────────────────

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
      "messages" => get_messages(state),
      "working_memory" => get_working_memory(state),
      "goals" => get_goals(state),
      "turn_count" => get_turn_count(state),
      "cognitive_mode" => to_string(get_cognitive_mode(state)),
      "checkpoint_at" => DateTime.to_iso8601(DateTime.utc_now())
    }
  end

  defp should_checkpoint?(state) do
    interval = get_in(state, [Access.key(:config), Access.key(:checkpoint_interval)]) || 1
    rem(get_turn_count(state), max(interval, 1)) == 0
  end

  # ── Trust tier verification ─────────────────────────────────────────

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

  # ── Contract struct helpers ─────────────────────────────────────────

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

  # ── DOT parsing ─────────────────────────────────────────────────────

  @doc false
  def parse_dot_file(path) do
    with {:ok, source} <- File.read(path) do
      Arbor.Orchestrator.parse(source)
    end
  end

  # ── Message normalization ───────────────────────────────────────────

  @doc false
  def normalize_message(message) when is_binary(message), do: message
  def normalize_message(%{"content" => content}), do: content
  def normalize_message(%{content: content}), do: content
  def normalize_message(message), do: inspect(message)

  @doc false
  def safe_to_atom(string, fallback) do
    String.to_existing_atom(string)
  rescue
    ArgumentError -> fallback
  end

  # ── Private helpers (contract-aware accessors) ──────────────────────
  #
  # Duplicated from parent to avoid circular module dependencies.
  # These read from session_state when available, falling back to flat fields.

  defp get_messages(%{session_state: %{messages: msgs}} = _state) when is_list(msgs), do: msgs
  defp get_messages(state), do: state.messages

  defp get_turn_count(%{session_state: %{turn_count: tc}} = _state)
       when is_integer(tc),
       do: tc

  defp get_turn_count(state), do: state.turn_count

  defp get_working_memory(%{session_state: %{working_memory: wm}} = _state) when is_map(wm),
    do: wm

  defp get_working_memory(state), do: state.working_memory

  defp get_goals(%{session_state: %{goals: goals}} = _state) when is_list(goals), do: goals
  defp get_goals(state), do: state.goals

  defp get_cognitive_mode(%{session_state: %{cognitive_mode: cm}} = _state) when is_atom(cm),
    do: cm

  defp get_cognitive_mode(state), do: state.cognitive_mode

  defp get_phase(%{session_state: %{phase: phase}} = _state) when is_atom(phase), do: phase
  defp get_phase(state), do: state.phase

  # ── Private helpers (contract-aware mutation) ───────────────────────

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

  # ── Contract struct construction helpers ─────────────────────────────

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

  defp build_session_state(opts) do
    case apply(state_module(), :new, [[trace_id: Keyword.get(opts, :trace_id)]]) do
      {:ok, session_state} ->
        session_state

      {:error, reason} ->
        Logger.warning("[Session] Failed to create Session.State: #{inspect(reason)}, using nil")

        nil
    end
  end

  defp build_behavior(opts) do
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

  # ── Heartbeat proposal generation (Phase 3) ─────────────────────

  defp generate_heartbeat_proposals(agent_id, state, result_ctx) do
    []
    |> maybe_add_cognitive_mode_proposal(state, result_ctx)
    |> maybe_add_goal_proposals(result_ctx)
    |> maybe_add_goal_update_proposals(result_ctx)
    |> maybe_add_wm_proposals(result_ctx)
    |> maybe_add_decomposition_proposals(result_ctx)
    |> maybe_add_identity_proposals(agent_id, result_ctx)
  end

  defp maybe_add_cognitive_mode_proposal(proposals, state, result_ctx) do
    case Map.get(result_ctx, "session.cognitive_mode") do
      mode when is_binary(mode) and mode != "" ->
        current = to_string(get_cognitive_mode(state))

        if mode != current do
          [
            %{
              type: :cognitive_mode,
              content: "Switch to #{mode} mode",
              metadata: %{from: current, to: mode}
            }
            | proposals
          ]
        else
          proposals
        end

      _ ->
        proposals
    end
  end

  defp maybe_add_goal_proposals(proposals, result_ctx) do
    case Map.get(result_ctx, "session.new_goals", []) do
      goals when is_list(goals) and goals != [] ->
        goal_proposals =
          goals
          |> Enum.map(fn goal ->
            desc = Map.get(goal, "description", "")
            desc = if is_binary(desc), do: String.trim(desc), else: ""
            {desc, goal}
          end)
          |> Enum.reject(fn {desc, _goal} -> desc == "" end)
          |> Enum.map(fn {desc, goal} ->
            %{
              type: :goal,
              content: desc,
              metadata: %{goal_data: goal}
            }
          end)

        goal_proposals ++ proposals

      _ ->
        proposals
    end
  end

  defp maybe_add_goal_update_proposals(proposals, result_ctx) do
    case Map.get(result_ctx, "session.goal_updates", []) do
      updates when is_list(updates) and updates != [] ->
        update_proposals =
          Enum.map(updates, fn update ->
            %{
              type: :goal_update,
              content: "Update goal #{Map.get(update, "id", "?")}",
              metadata: %{update_data: update}
            }
          end)

        update_proposals ++ proposals

      _ ->
        proposals
    end
  end

  # Maximum observation proposals per heartbeat to prevent volume explosion
  @max_observations_per_heartbeat 5

  # Internal monologue prefixes — these are self-instructions, not observations
  @intention_prefixes [
    "Should ",
    "Need to ",
    "Want to ",
    "Must ",
    "Have to ",
    "I should ",
    "I need to ",
    "I want to ",
    "I must ",
    "I have to "
  ]

  defp maybe_add_wm_proposals(proposals, result_ctx) do
    thoughts = Map.get(result_ctx, "session.memory_notes", [])
    concerns = Map.get(result_ctx, "session.concerns", [])
    curiosities = Map.get(result_ctx, "session.curiosity", [])

    thought_props =
      thoughts
      |> List.wrap()
      |> Enum.map(fn t ->
        {text, metadata} = extract_note_with_metadata(t)
        %{type: :thought, content: text, metadata: metadata}
      end)
      |> Enum.reject(&internal_monologue?/1)

    concern_props =
      Enum.map(List.wrap(concerns), fn c ->
        {text, metadata} = extract_note_with_metadata(c)
        %{type: :concern, content: text, metadata: metadata}
      end)

    curiosity_props =
      Enum.map(List.wrap(curiosities), fn c ->
        {text, metadata} = extract_note_with_metadata(c)
        %{type: :curiosity, content: text, metadata: metadata}
      end)

    wm_proposals = thought_props ++ concern_props ++ curiosity_props

    # Cap total observations per heartbeat — LLM puts most important first
    capped = Enum.take(wm_proposals, @max_observations_per_heartbeat)

    capped ++ proposals
  end

  defp internal_monologue?(%{content: text}) do
    Enum.any?(@intention_prefixes, &String.starts_with?(text, &1))
  end

  defp extract_note_with_metadata(note) when is_binary(note), do: {note, %{}}

  defp extract_note_with_metadata(%{"text" => text} = note) when is_binary(text) do
    metadata =
      case Map.get(note, "referenced_date") do
        date_str when is_binary(date_str) -> %{referenced_date: date_str}
        _ -> %{}
      end

    {text, metadata}
  end

  defp extract_note_with_metadata(other), do: {inspect(other), %{}}

  defp maybe_add_decomposition_proposals(proposals, result_ctx) do
    case Map.get(result_ctx, "session.decompositions", []) do
      decomps when is_list(decomps) and decomps != [] ->
        intent_proposals =
          Enum.map(decomps, fn d ->
            %{
              type: :intent,
              content: Map.get(d, "description", "Decomposed intent"),
              metadata: %{decomposition: d}
            }
          end)

        intent_proposals ++ proposals

      _ ->
        proposals
    end
  end

  defp maybe_add_identity_proposals(proposals, _agent_id, result_ctx) do
    case Map.get(result_ctx, "session.identity_insights", []) do
      insights when is_list(insights) and insights != [] ->
        identity_proposals =
          Enum.map(insights, fn insight ->
            text =
              if is_binary(insight), do: insight, else: Map.get(insight, "text", inspect(insight))

            %{type: :identity, content: text, metadata: %{source: "heartbeat"}}
          end)

        identity_proposals ++ proposals

      _ ->
        proposals
    end
  end

  defp create_proposals(agent_id, proposals) do
    proposal_module = Arbor.Memory.Proposal

    if Code.ensure_loaded?(proposal_module) and
         function_exported?(proposal_module, :create, 3) do
      Enum.count(proposals, fn prop ->
        case apply(proposal_module, :create, [
               agent_id,
               prop.type,
               %{
                 content: prop.content,
                 source: "heartbeat",
                 metadata: prop.metadata,
                 confidence: 0.7
               }
             ]) do
          {:ok, _} -> true
          {:error, _} -> false
        end
      end)
    else
      0
    end
  rescue
    _ -> 0
  catch
    :exit, _ -> 0
  end

  defp emit_notification_percept(agent_id, count, proposals) do
    by_type = Enum.group_by(proposals, & &1.type)

    summary_parts =
      Enum.map(by_type, fn {type, items} ->
        "#{length(items)} #{type}"
      end)

    summary = "#{count} proposals waiting: #{Enum.join(summary_parts, ", ")}"

    # Enqueue notification to ActionCycleServer via runtime bridge
    action_cycle_sup = Arbor.Agent.ActionCycleSupervisor

    if Code.ensure_loaded?(action_cycle_sup) do
      case apply(action_cycle_sup, :lookup, [agent_id]) do
        {:ok, pid} ->
          send(
            pid,
            {:percept,
             %{
               type: :notification,
               summary: summary,
               proposal_count: count,
               by_type: Map.new(by_type, fn {k, v} -> {k, length(v)} end)
             }}
          )

        :error ->
          :ok
      end
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # ── Compactor helpers ────────────────────────────────────────────

  # Seed compactor with restored checkpoint messages so it can track them.
  # Without this, a restored session would have messages in state but an
  # empty compactor — it would never compact because it thinks it has 0 tokens.
  defp seed_compactor_from_checkpoint(%{compactor: nil} = state), do: state

  defp seed_compactor_from_checkpoint(%{compactor: compactor, messages: messages} = state)
       when is_list(messages) and messages != [] do
    seeded =
      Enum.reduce(messages, compactor, fn msg, acc ->
        apply_compactor(acc, :append, [msg])
      end)

    %{state | compactor: seeded}
  end

  defp seed_compactor_from_checkpoint(state), do: state

  # Use compactor's projected view if available, otherwise all messages
  defp compactor_llm_messages(%{compactor: nil} = state), do: get_messages(state)

  defp compactor_llm_messages(%{compactor: compactor}) when not is_nil(compactor) do
    apply_compactor(compactor, :llm_messages, [])
  end

  # Catch-all for sessions started before compactor field existed
  defp compactor_llm_messages(state), do: get_messages(state)

  # Append user + assistant messages and run compaction
  defp append_to_compactor(nil, _user_msg, _assistant_msg), do: nil

  defp append_to_compactor(compactor, user_msg, assistant_msg) do
    compactor
    |> apply_compactor(:append, [user_msg])
    |> apply_compactor(:append, [assistant_msg])
    |> apply_compactor(:maybe_compact, [])
  end

  # Runtime bridge: the compactor struct carries its own module via __struct__
  defp apply_compactor(%{__struct__: module} = compactor, fun, args) do
    apply(module, fun, [compactor | args])
  end

  # ── Memory store runtime bridge ──────────────────────────────────

  defp load_goals_from_memory(agent_id) do
    if Code.ensure_loaded?(Arbor.Memory) and
         function_exported?(Arbor.Memory, :get_active_goals, 1) do
      case apply(Arbor.Memory, :get_active_goals, [agent_id]) do
        goals when is_list(goals) and goals != [] ->
          Enum.map(goals, fn goal ->
            %{
              "id" => to_string(Map.get(goal, :id, "")),
              "description" => to_string(Map.get(goal, :description, "")),
              "progress" => Map.get(goal, :progress, 0.0),
              "status" => to_string(Map.get(goal, :status, :active)),
              "priority" => Map.get(goal, :priority, 50),
              "type" => to_string(Map.get(goal, :type, :achieve))
            }
          end)

        _ ->
          nil
      end
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp load_working_memory_from_memory(agent_id) do
    if memory_available?(:get_working_memory, 1) do
      case apply(Arbor.Memory, :get_working_memory, [agent_id]) do
        wm when is_map(wm) and map_size(wm) > 0 -> sanitize_working_memory(wm)
        _ -> nil
      end
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  # Convert WorkingMemory struct (or any map) to a plain JSON-serializable map.
  # The engine checkpoint serializes context values via Jason — structs without
  # Jason.Encoder will crash.
  @wm_internal_keys ~w(agent_id max_tokens model __struct__)a
  defp sanitize_working_memory(%{__struct__: _} = wm) do
    wm
    |> Map.from_struct()
    |> Map.drop(@wm_internal_keys)
    |> stringify_datetimes()
  end

  defp sanitize_working_memory(wm) when is_map(wm), do: wm

  defp stringify_datetimes(map) when is_map(map) do
    Map.new(map, fn
      {k, %DateTime{} = dt} -> {k, DateTime.to_iso8601(dt)}
      {k, items} when is_list(items) -> {k, Enum.map(items, &stringify_value/1)}
      {k, v} -> {k, v}
    end)
  end

  defp stringify_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp stringify_value(%{} = map) do
    Map.new(map, fn
      {k, %DateTime{} = dt} -> {k, DateTime.to_iso8601(dt)}
      {k, v} -> {k, v}
    end)
  end

  defp stringify_value(v), do: v

  defp load_knowledge_graph(agent_id) do
    if memory_available?(:export_knowledge_graph, 1) do
      case apply(Arbor.Memory, :export_knowledge_graph, [agent_id]) do
        {:ok, %{nodes: nodes}} when is_map(nodes) and map_size(nodes) > 0 ->
          nodes
          |> Enum.take(20)
          |> Enum.map(fn {_id, node} ->
            %{
              "content" => node["content"] || Map.get(node, :content, ""),
              "type" => node["type"] || to_string(Map.get(node, :type, "")),
              "confidence" => node["confidence"] || Map.get(node, :confidence, 0.5)
            }
          end)

        _ ->
          []
      end
    else
      []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp load_pending_proposals(agent_id) do
    if memory_available?(:get_proposals, 1) do
      case apply(Arbor.Memory, :get_proposals, [agent_id]) do
        {:ok, proposals} when is_list(proposals) ->
          Enum.map(proposals, fn p ->
            %{
              "id" => to_string(Map.get(p, :id, "")),
              "type" => to_string(Map.get(p, :type, "")),
              "content" => to_string(Map.get(p, :content, Map.get(p, :description, ""))),
              "source" => to_string(Map.get(p, :source, ""))
            }
          end)

        _ ->
          []
      end
    else
      []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp load_active_intents(agent_id) do
    if memory_available?(:pending_intentions, 1) do
      case apply(Arbor.Memory, :pending_intentions, [agent_id]) do
        intents when is_list(intents) ->
          Enum.map(intents, fn
            {intent, status} when is_map(intent) ->
              %{
                "id" => to_string(Map.get(intent, :id, "")),
                "action" => to_string(Map.get(intent, :action, "")),
                "description" => to_string(Map.get(intent, :description, "")),
                "goal_id" => to_string(Map.get(intent, :goal_id, "")),
                "status" => to_string(Map.get(status, :status, "pending"))
              }

            intent when is_map(intent) ->
              %{
                "id" => to_string(Map.get(intent, :id, "")),
                "action" => to_string(Map.get(intent, :action, "")),
                "description" => to_string(Map.get(intent, :description, "")),
                "goal_id" => to_string(Map.get(intent, :goal_id, "")),
                "status" => to_string(Map.get(intent, :status, ""))
              }
          end)

        _ ->
          []
      end
    else
      []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp load_recent_thinking(agent_id) do
    if memory_available?(:recent_thinking, 1) do
      case apply(Arbor.Memory, :recent_thinking, [agent_id]) do
        thoughts when is_list(thoughts) ->
          thoughts
          |> Enum.take(5)
          |> Enum.map(fn t ->
            %{
              "text" => to_string(Map.get(t, :text, "")),
              "significant" => Map.get(t, :significant, false)
            }
          end)

        _ ->
          []
      end
    else
      []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp load_recent_percepts(agent_id) do
    if memory_available?(:recent_percepts, 1) do
      case apply(Arbor.Memory, :recent_percepts, [agent_id, [limit: 5]]) do
        percepts when is_list(percepts) ->
          Enum.map(percepts, fn p ->
            %{
              "action_type" => get_percept_action_type(p),
              "outcome" => to_string(Map.get(p, :outcome, "")),
              "data" => Map.get(p, :data, %{})
            }
          end)

        _ ->
          []
      end
    else
      []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp get_percept_action_type(p) do
    data = Map.get(p, :data, %{})

    Map.get(data, :action_type) ||
      Map.get(data, "action_type", "unknown")
  end

  defp memory_available?(function, arity) do
    Code.ensure_loaded?(Arbor.Memory) and
      function_exported?(Arbor.Memory, function, arity)
  end

  # ── Session entry persistence (runtime bridge) ─────────────────────

  @session_store Arbor.Persistence.SessionStore

  defp persist_turn_entries(state, timestamp, user_msg, assistant_msg, result_ctx) do
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
              "turn_count" => get_turn_count(state) + 1
            }
          })
        rescue
          e -> Logger.warning("[Session] Turn entry persistence failed: #{Exception.message(e)}")
        end
      end)
    end
  end

  defp persist_heartbeat_entry(state, result_ctx) do
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

  defp get_persist_entry_fn(state) do
    # Check adapter first, then fall back to runtime bridge
    case get_in(state, [Access.key(:adapters), Access.key(:persist_entry)]) do
      fun when is_function(fun, 1) ->
        fun

      _ ->
        build_persist_fn_from_store(state)
    end
  end

  defp build_persist_fn_from_store(state) do
    if session_store_available?() do
      case get_session_uuid(state.session_id) do
        nil -> nil
        uuid -> fn attrs -> apply(@session_store, :append_entry, [uuid, attrs]) end
      end
    end
  end

  defp get_session_uuid(session_id) do
    case apply(@session_store, :get_session, [session_id]) do
      {:ok, session} -> session.id
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp session_store_available? do
    Code.ensure_loaded?(@session_store) and
      function_exported?(@session_store, :available?, 0) and
      apply(@session_store, :available?, [])
  end

  # Wrap a text string into a structured content array
  defp wrap_content(text) when is_binary(text), do: [%{"type" => "text", "text" => text}]
  defp wrap_content(content) when is_list(content), do: content
  defp wrap_content(_), do: []

  # Build assistant content array with optional tool_use blocks
  defp build_assistant_content(text, tool_calls) when is_list(tool_calls) and tool_calls != [] do
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

  defp build_assistant_content(text, _), do: wrap_content(text)
end
