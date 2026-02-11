defmodule Arbor.Orchestrator.Session do
  @moduledoc """
  Session GenServer — drives agent turns and heartbeats through DOT graphs.

  Each Session holds pre-parsed turn and heartbeat graphs, accumulated messages,
  working memory, goals, and cognitive mode. External dependencies (LLM, tools,
  memory, etc.) are injected as adapter functions — the Session itself is pure
  orchestration.

  ## Architecture

  A Session is the convergence point between `Arbor.Orchestrator.Engine` and
  the agent lifecycle. Rather than hand-coding turn/heartbeat logic in procedural
  Elixir, the Session delegates to graph execution:

      send_message/2  →  Engine.run(turn_graph, initial_values)  →  apply_turn_result/2
      :heartbeat      →  Task → Engine.run(heartbeat_graph)     →  {:heartbeat_result, _}

  The `SessionHandler` provides all node implementations; adapters bridge to
  real infrastructure (LLM providers, memory stores, tool servers).

  ## Contracts

  When `Arbor.Contracts.Session.Config`, `Arbor.Contracts.Session.State`, and
  `Arbor.Contracts.Session.Behavior` are available, the Session uses them as
  the source of truth for immutable config, mutable state, and phase transitions.
  All existing flat fields are kept in sync for backward compatibility — callers
  can still access `state.turn_count`, `state.phase`, etc. directly.

  ## Turn vs Heartbeat execution

  **Turns** run synchronously via `GenServer.call` — the caller blocks until the
  engine completes and the response is ready. This is correct for query-response
  semantics.

  **Heartbeats** run in a spawned `Task` to avoid blocking the GenServer. The
  heartbeat result is sent back as `{:heartbeat_result, result}` and applied
  asynchronously. This means the GenServer remains responsive to `send_message/2`
  calls while a heartbeat is in-flight.

  ## Example

      {:ok, pid} = Session.start_link(
        session_id: "session-1",
        agent_id: "agent_abc123",
        trust_tier: :established,
        adapters: %{
          llm_call: &MyLLM.call/3,
          memory_recall: &MyMemory.recall/2
        },
        turn_dot: "specs/pipelines/session/turn.dot",
        heartbeat_dot: "specs/pipelines/session/heartbeat.dot"
      )

      {:ok, response} = Session.send_message(pid, "Hello!")
  """

  use GenServer

  require Logger

  alias Arbor.Orchestrator.Engine
  alias Arbor.Orchestrator.Handlers.{Registry, SessionHandler}

  @default_heartbeat_interval 30_000

  # All session.* node types that SessionHandler dispatches on.
  # Nodes with shape=diamond (check_auth, check_response, mode_router)
  # use ConditionalHandler via the Registry's shape-to-type mapping — correct.
  @session_node_types ~w(
    session.classify
    session.memory_recall
    session.mode_select
    session.llm_call
    session.tool_dispatch
    session.format
    session.memory_update
    session.checkpoint
    session.background_checks
    session.process_results
    session.route_actions
    session.update_goals
  )

  # ── Contract module availability (runtime bridge) ──────────────────
  # Checked at runtime so the orchestrator works standalone without
  # arbor_contracts in the dependency tree.

  # ── State ────────────────────────────────────────────────────────────
  #
  # All existing flat fields are preserved for backward compatibility.
  # When contracts are available, `session_config`, `session_state`, and
  # `behavior` hold the canonical typed structs. The flat fields are
  # kept in sync so callers (tests, get_state/1) can access them directly.

  defstruct [
    :session_id,
    :agent_id,
    :trust_tier,
    :turn_graph,
    :heartbeat_graph,
    :trace_id,
    :seed_ref,
    :signal_topic,
    # Contract structs (nil when contracts unavailable)
    :session_config,
    :session_state,
    :behavior,
    phase: :idle,
    session_type: :primary,
    config: %{},
    turn_count: 0,
    messages: [],
    working_memory: %{},
    goals: [],
    cognitive_mode: :reflection,
    adapters: %{},
    heartbeat_interval: @default_heartbeat_interval,
    heartbeat_ref: nil,
    heartbeat_in_flight: false
  ]

  @type phase :: :idle | :processing | :awaiting_tools | :awaiting_llm
  @type session_type :: :primary | :background | :delegation | :consultation

  @type t :: %__MODULE__{
          session_id: String.t(),
          agent_id: String.t(),
          trust_tier: atom(),
          turn_graph: Arbor.Orchestrator.Graph.t(),
          heartbeat_graph: Arbor.Orchestrator.Graph.t(),
          phase: phase(),
          session_type: session_type(),
          trace_id: String.t() | nil,
          config: map(),
          seed_ref: term() | nil,
          signal_topic: String.t() | nil,
          turn_count: non_neg_integer(),
          messages: [map()],
          working_memory: map(),
          goals: [map()],
          cognitive_mode: atom(),
          adapters: map(),
          heartbeat_interval: pos_integer(),
          heartbeat_ref: reference() | nil,
          heartbeat_in_flight: boolean(),
          session_config: struct() | nil,
          session_state: struct() | nil,
          behavior: struct() | nil
        }

  # ── Public API ───────────────────────────────────────────────────────

  @doc """
  Start a Session process.

  ## Required options

    * `:session_id`    — unique session identifier
    * `:agent_id`      — the agent this session belongs to
    * `:trust_tier`    — atom trust tier (e.g. `:established`)
    * `:turn_dot`      — path to the turn pipeline DOT file
    * `:heartbeat_dot` — path to the heartbeat pipeline DOT file

  ## Optional

    * `:adapters`           — map of adapter functions (see `SessionHandler`).
                              Include `:trust_tier_resolver` (`fn agent_id -> {:ok, tier}`)
                              to verify trust_tier against the authority (e.g. `Arbor.Trust`)
    * `:heartbeat_interval` — ms between heartbeats (default #{@default_heartbeat_interval})
    * `:name`               — GenServer name registration
    * `:start_heartbeat`    — whether to schedule heartbeat on init (default true)
    * `:session_type`       — `:primary | :background | :delegation | :consultation` (default `:primary`)
    * `:config`             — session-level settings map (max_turns, model, temperature, etc.)
    * `:seed_ref`           — reference to the agent's Seed for identity continuity
    * `:signal_topic`       — dedicated signal topic for this session's observability
    * `:trace_id`           — distributed tracing correlation ID
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Send a user message and receive the agent's response.

  Runs the turn graph synchronously. The message is appended to the session's
  message history, processed through classify -> authorize -> recall -> LLM -> format,
  and the response is returned.
  """
  @spec send_message(GenServer.server(), String.t() | map()) ::
          {:ok, String.t()} | {:error, term()}
  def send_message(session, message) do
    GenServer.call(session, {:send_message, message}, :infinity)
  end

  @doc """
  Trigger an immediate heartbeat cycle.

  Runs asynchronously in a Task — the heartbeat graph executes without blocking
  the GenServer, and results are applied via `{:heartbeat_result, _}` message.
  Returns immediately.
  """
  @spec heartbeat(GenServer.server()) :: :ok
  def heartbeat(session) do
    GenServer.cast(session, :heartbeat)
  end

  @doc """
  Return the current session state. Useful for testing and inspection.
  """
  @spec get_state(GenServer.server()) :: t()
  def get_state(session) do
    GenServer.call(session, :get_state)
  end

  # ── GenServer callbacks ──────────────────────────────────────────────

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    agent_id = Keyword.fetch!(opts, :agent_id)
    trust_tier = Keyword.fetch!(opts, :trust_tier)
    turn_dot_path = Keyword.fetch!(opts, :turn_dot)
    heartbeat_dot_path = Keyword.fetch!(opts, :heartbeat_dot)

    adapters = Keyword.get(opts, :adapters, %{})
    heartbeat_interval = Keyword.get(opts, :heartbeat_interval, @default_heartbeat_interval)
    start_heartbeat = Keyword.get(opts, :start_heartbeat, true)
    session_type = Keyword.get(opts, :session_type, :primary)
    config = Keyword.get(opts, :config, %{})
    seed_ref = Keyword.get(opts, :seed_ref)
    signal_topic = Keyword.get(opts, :signal_topic, "session:#{session_id}")
    trace_id = Keyword.get(opts, :trace_id)

    # Verify trust_tier if a resolver is available (hierarchy constraint bridge).
    # Without a resolver, we trust the caller — but log a warning.
    trust_tier = verify_trust_tier(trust_tier, agent_id, adapters)

    with {:ok, turn_graph} <- parse_dot_file(turn_dot_path),
         {:ok, heartbeat_graph} <- parse_dot_file(heartbeat_dot_path) do
      ensure_session_handler_registered()

      # Build contract structs if available (runtime bridge)
      {session_config, session_state, behavior} =
        build_contract_structs(
          session_id: session_id,
          agent_id: agent_id,
          trust_tier: trust_tier,
          session_type: session_type,
          trace_id: trace_id,
          config: config,
          behavior: Keyword.get(opts, :behavior)
        )

      state = %__MODULE__{
        session_id: session_id,
        agent_id: agent_id,
        trust_tier: trust_tier,
        turn_graph: turn_graph,
        heartbeat_graph: heartbeat_graph,
        adapters: adapters,
        heartbeat_interval: heartbeat_interval,
        session_type: session_type,
        config: config,
        seed_ref: seed_ref,
        signal_topic: signal_topic,
        trace_id: trace_id,
        session_config: session_config,
        session_state: session_state,
        behavior: behavior
      }

      state =
        if start_heartbeat do
          schedule_heartbeat(state)
        else
          state
        end

      {:ok, state}
    else
      {:error, reason} -> {:stop, {:bad_dot, reason}}
    end
  end

  @impl true
  def handle_call({:send_message, message}, _from, state) do
    state = transition_phase(state, :idle, :input_received, :processing)
    values = build_turn_values(state, message)
    engine_opts = build_engine_opts(state, values)

    try do
      case Engine.run(state.turn_graph, engine_opts) do
        {:ok, result} ->
          new_state =
            state
            |> transition_phase(:processing, :complete, :idle)
            |> apply_turn_result(message, result)

          response = Map.get(result.context, "session.response", "")
          {:reply, {:ok, response}, new_state}

        {:error, reason} ->
          new_state = transition_phase(state, :processing, :complete, :idle)
          {:reply, {:error, reason}, new_state}
      end
    rescue
      e ->
        new_state = transition_phase(state, :processing, :complete, :idle)
        {:reply, {:error, {:engine_crash, Exception.message(e)}}, new_state}
    end
  end

  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_cast(:heartbeat, state) do
    state = start_heartbeat_task(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:heartbeat, state) do
    state = start_heartbeat_task(state)
    state = schedule_heartbeat(state)
    {:noreply, state}
  end

  def handle_info({:heartbeat_result, {:ok, result}}, state) do
    new_state =
      state
      |> Map.put(:heartbeat_in_flight, false)
      |> apply_heartbeat_result(result)

    {:noreply, new_state}
  end

  def handle_info({:heartbeat_result, {:error, _reason}}, state) do
    # Heartbeat failures are non-fatal — continue with current state
    new_state =
      state
      |> Map.put(:heartbeat_in_flight, false)
      |> maybe_increment_errors()

    {:noreply, new_state}
  end

  # Handle Task DOWN messages (normal exits from heartbeat Tasks)
  def handle_info({:DOWN, _ref, :process, _pid, :normal}, state) do
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    # Heartbeat task crashed — reset in_flight flag
    {:noreply, %{state | heartbeat_in_flight: false}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Context value builders ───────────────────────────────────────────
  #
  # These produce plain maps that get merged into the Engine's Context
  # via the :initial_values option. All keys use the "session." namespace
  # to match what SessionHandler reads via Context.get/3.

  @doc false
  @spec build_turn_values(t(), String.t() | map()) :: map()
  def build_turn_values(state, message) do
    user_msg = %{"role" => "user", "content" => normalize_message(message)}
    messages = get_messages(state)
    messages_with_input = messages ++ [user_msg]

    base = session_base_values(state)

    Map.merge(base, %{
      "session.messages" => messages_with_input,
      "session.input" => normalize_message(message)
    })
  end

  @doc false
  @spec build_heartbeat_values(t()) :: map()
  def build_heartbeat_values(state) do
    base = session_base_values(state)
    Map.put(base, "session.messages", get_messages(state))
  end

  defp session_base_values(state) do
    # Read from contract structs when available, fall back to flat fields.
    # This keeps the context map identical regardless of contract availability.
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

  # ── Result application ───────────────────────────────────────────────

  @doc false
  @spec apply_turn_result(t(), String.t() | map(), Engine.run_result()) :: t()
  def apply_turn_result(state, message, %{context: result_ctx}) do
    response = Map.get(result_ctx, "session.response", "")

    user_msg = %{"role" => "user", "content" => normalize_message(message)}
    assistant_msg = %{"role" => "assistant", "content" => response}

    updated_messages =
      case Map.get(result_ctx, "session.messages") do
        msgs when is_list(msgs) ->
          # Engine may have appended tool messages; use its version + assistant
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

    # Update flat fields (backward compat)
    state = %{
      state
      | messages: updated_messages,
        working_memory: updated_wm,
        turn_count: new_turn_count
    }

    # Sync contract session_state if available
    update_session_state(state, fn ss ->
      ss
      |> Map.put(:messages, updated_messages)
      |> Map.put(:working_memory, updated_wm)
      |> maybe_call_increment_turn()
    end)
  end

  @doc false
  @spec apply_heartbeat_result(t(), Engine.run_result()) :: t()
  def apply_heartbeat_result(state, %{context: result_ctx}) do
    # Cognitive mode from the mode_select handler
    cognitive_mode =
      case Map.get(result_ctx, "session.cognitive_mode") do
        mode when is_binary(mode) and mode != "" ->
          safe_to_atom(mode, get_cognitive_mode(state))

        _ ->
          get_cognitive_mode(state)
      end

    # Goal updates from process_results handler
    goal_updates = Map.get(result_ctx, "session.goal_updates", [])
    new_goals = Map.get(result_ctx, "session.new_goals", [])
    current_goals = get_goals(state)
    goals = apply_goal_changes(current_goals, goal_updates, new_goals)

    # Update flat fields (backward compat)
    state = %{state | cognitive_mode: cognitive_mode, goals: goals}

    # Sync contract session_state if available
    update_session_state(state, fn ss ->
      ss
      |> Map.put(:cognitive_mode, cognitive_mode)
      |> Map.put(:goals, goals)
      |> maybe_call_touch()
    end)
  end

  # ── Private helpers ──────────────────────────────────────────────────

  defp start_heartbeat_task(state) do
    if state.heartbeat_in_flight do
      # Don't stack heartbeats — skip if one is already running
      state
    else
      session_pid = self()
      values = build_heartbeat_values(state)
      engine_opts = build_engine_opts(state, values)
      heartbeat_graph = state.heartbeat_graph

      task_sup = Arbor.Orchestrator.Session.TaskSupervisor

      task_fn = fn ->
        result =
          try do
            Engine.run(heartbeat_graph, engine_opts)
          rescue
            e -> {:error, {:engine_crash, Exception.message(e)}}
          end

        send(session_pid, {:heartbeat_result, result})
      end

      {:ok, _pid} =
        if Process.whereis(task_sup) do
          Task.Supervisor.start_child(task_sup, task_fn)
        else
          Task.start(task_fn)
        end

      %{state | heartbeat_in_flight: true}
    end
  end

  defp build_engine_opts(state, initial_values) do
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
      initial_values: initial_values
    ]
  end

  defp schedule_heartbeat(state) do
    if state.heartbeat_ref, do: Process.cancel_timer(state.heartbeat_ref)
    ref = Process.send_after(self(), :heartbeat, state.heartbeat_interval)
    %{state | heartbeat_ref: ref}
  end

  defp parse_dot_file(path) do
    with {:ok, source} <- File.read(path) do
      Arbor.Orchestrator.parse(source)
    end
  end

  defp ensure_session_handler_registered do
    Enum.each(@session_node_types, fn type ->
      unless handler_registered?(type) do
        Registry.register(type, SessionHandler)
      end
    end)
  end

  defp handler_registered?(type) do
    node = %Arbor.Orchestrator.Graph.Node{id: "_probe", attrs: %{"type" => type}}

    try do
      Registry.resolve(node) == SessionHandler
    rescue
      _ -> false
    end
  end

  defp normalize_message(message) when is_binary(message), do: message
  defp normalize_message(%{"content" => content}), do: content
  defp normalize_message(%{content: content}), do: content
  defp normalize_message(message), do: inspect(message)

  defp safe_to_atom(string, fallback) do
    String.to_existing_atom(string)
  rescue
    ArgumentError -> fallback
  end

  defp verify_trust_tier(declared_tier, agent_id, adapters) do
    case Map.get(adapters, :trust_tier_resolver) do
      resolver when is_function(resolver, 1) ->
        case resolver.(agent_id) do
          {:ok, verified_tier} -> verified_tier
          _ -> declared_tier
        end

      _ ->
        # No resolver available — accept declared tier.
        # Callers integrating with arbor_trust should provide
        # :trust_tier_resolver in adapters.
        declared_tier
    end
  end

  defp apply_goal_changes(existing_goals, updates, new_goals) do
    updated =
      Enum.map(existing_goals, fn goal ->
        case Enum.find(updates, &(Map.get(&1, "id") == Map.get(goal, "id"))) do
          nil -> goal
          update -> Map.merge(goal, update)
        end
      end)

    updated ++ List.wrap(new_goals)
  end

  # ── Contract struct helpers ─────────────────────────────────────────
  #
  # Runtime bridge: build and manage contract structs when available.
  # All functions check module availability at runtime so the orchestrator
  # works standalone without arbor_contracts in the dependency tree.

  @doc false
  def contracts_available? do
    Code.ensure_loaded?(config_module()) and
      Code.ensure_loaded?(state_module()) and
      Code.ensure_loaded?(behavior_module())
  end

  defp build_contract_structs(opts) do
    if contracts_available?() do
      session_config = build_session_config(opts)
      session_state = build_session_state(opts)
      behavior = build_behavior(opts)
      {session_config, session_state, behavior}
    else
      {nil, nil, nil}
    end
  end

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
        # Already a Behavior struct — use as-is
        behavior

      _other ->
        Logger.warning("[Session] Invalid behavior option, using default")

        case apply(behavior_module(), :default, []) do
          {:ok, behavior} -> behavior
          _ -> nil
        end
    end
  end

  # Module references via functions to avoid compile-time warnings
  # when arbor_contracts is not in the dependency tree.
  defp config_module, do: Arbor.Contracts.Session.Config
  defp state_module, do: Arbor.Contracts.Session.State
  defp behavior_module, do: Arbor.Contracts.Session.Behavior

  # ── Contract-aware state accessors ──────────────────────────────────
  #
  # These read from session_state when available, falling back to flat fields.
  # This ensures session_base_values/1 always produces the same context map.

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

  # ── Contract-aware state mutation ───────────────────────────────────

  # Update session_state struct and keep flat fields in sync.
  # The update_fn receives the current session_state struct and must return
  # the updated struct.
  defp update_session_state(%{session_state: nil} = state, _update_fn), do: state

  defp update_session_state(%{session_state: ss} = state, update_fn) when not is_nil(ss) do
    updated_ss = update_fn.(ss)
    %{state | session_state: updated_ss}
  end

  # Calls State.increment_turn/1 if the module is available, otherwise
  # just increments turn_count manually on the struct.
  defp maybe_call_increment_turn(ss) do
    if contracts_available?() do
      apply(state_module(), :increment_turn, [ss])
    else
      %{ss | turn_count: ss.turn_count + 1}
    end
  end

  # Calls State.touch/1 if available.
  defp maybe_call_touch(ss) do
    if contracts_available?() do
      apply(state_module(), :touch, [ss])
    else
      ss
    end
  end

  # Increment error count on heartbeat failures (when session_state is available).
  defp maybe_increment_errors(%{session_state: nil} = state), do: state

  defp maybe_increment_errors(%{session_state: ss} = state) when not is_nil(ss) do
    if contracts_available?() do
      %{state | session_state: apply(state_module(), :increment_errors, [ss])}
    else
      state
    end
  end

  # ── Phase transition with behavior validation ──────────────────────
  #
  # Validates the transition against the Behavior state machine before
  # applying it. In Phase 2 this is advisory (log warning, don't block).
  # The flat `phase` field and `session_state.phase` are both updated.

  defp transition_phase(state, expected_from, event, to_phase) do
    # Validate against behavior if available
    validate_transition(state.behavior, expected_from, event)

    # Update flat field (backward compat)
    state = %{state | phase: to_phase}

    # Update contract session_state if available
    update_session_state(state, fn ss ->
      %{ss | phase: to_phase}
    end)
  end

  defp validate_transition(nil, _from, _event), do: :ok

  defp validate_transition(behavior, from, event) do
    if contracts_available?() do
      valid? = apply(behavior_module(), :valid_transition?, [behavior, from, event])

      unless valid? do
        Logger.warning(
          "[Session] Invalid phase transition: #{inspect(from)} --#{inspect(event)}--> " <>
            "(not defined in behavior #{inspect(behavior.name)}). " <>
            "Proceeding anyway — enforcement deferred to Phase 2."
        )
      end
    end

    :ok
  end
end
