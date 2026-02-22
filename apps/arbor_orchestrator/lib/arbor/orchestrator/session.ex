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

  ## Execution Modes

  The `:execution_mode` option controls the strangler fig migration:

    * `:legacy`  — Session rejects `send_message/2` with `{:error, :legacy_mode}`.
                   Callers (Claude GenServer, APIAgent) use their native path.
    * `:session` — Session handles turns and heartbeats through DOT graphs (default).
    * `:graph`   — Full DOT graph execution with no fallback path.

  ## Turn vs Heartbeat execution

  **Turns** run in a spawned `Task` — the caller blocks on `GenServer.call` but
  the GenServer itself is free to handle heartbeats. When the Task completes,
  the result is sent back as `{:turn_result, message, result}` and
  `GenServer.reply/2` unblocks the original caller. Only one turn can be
  in-flight at a time (concurrent turns get `{:error, :turn_in_progress}`).

  **Heartbeats** also run in a spawned `Task` — the heartbeat result is sent
  back as `{:heartbeat_result, result}` and applied asynchronously. Both a
  turn and a heartbeat can overlap safely since adapters are stateless and
  memory stores are ETS-backed GenServers.

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
  alias Arbor.Orchestrator.Session.Builders

  @default_heartbeat_interval 30_000

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
    # Context compactor for progressive forgetting (nil = disabled)
    :compactor,
    phase: :idle,
    session_type: :primary,
    execution_mode: :session,
    config: %{},
    turn_count: 0,
    messages: [],
    working_memory: %{},
    goals: [],
    cognitive_mode: :reflection,
    adapters: %{},
    heartbeat_interval: @default_heartbeat_interval,
    heartbeat_ref: nil,
    heartbeat_in_flight: false,
    # Async turn execution state
    turn_in_flight: false,
    turn_from: nil,
    turn_task_ref: nil
  ]

  @type phase :: :idle | :processing | :awaiting_tools | :awaiting_llm
  @type session_type :: :primary | :background | :delegation | :consultation
  @type execution_mode :: :legacy | :session | :graph

  @type t :: %__MODULE__{
          session_id: String.t(),
          agent_id: String.t(),
          trust_tier: atom(),
          turn_graph: Arbor.Orchestrator.Graph.t(),
          heartbeat_graph: Arbor.Orchestrator.Graph.t(),
          phase: phase(),
          session_type: session_type(),
          execution_mode: execution_mode(),
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
          turn_in_flight: boolean(),
          turn_from: GenServer.from() | nil,
          turn_task_ref: reference() | nil,
          compactor: struct() | nil,
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
    * `:execution_mode`     — `:legacy | :session | :graph` (default `:session`)
    * `:config`             — session-level settings map (max_turns, model, temperature, etc.)
    * `:seed_ref`           — reference to the agent's Seed for identity continuity
    * `:signal_topic`       — dedicated signal topic for this session's observability
    * `:trace_id`           — distributed tracing correlation ID
    * `:checkpoint`         — map of checkpoint data to restore on init (crash recovery)
    * `:compactor`          — `{module, opts}` tuple for context compaction (e.g. `{ContextCompactor, [effective_window: 75_000]}`)
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
          {:ok, %{text: String.t(), tool_history: [map()], tool_rounds: non_neg_integer()}}
          | {:error, term()}
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

  @doc """
  Return the current execution mode.
  """
  @spec execution_mode(GenServer.server()) :: execution_mode()
  def execution_mode(session) do
    GenServer.call(session, :execution_mode)
  end

  @doc """
  Restore session state from a checkpoint map.

  The checkpoint map should have string keys matching the session context
  namespace (e.g. `"session.messages"`, `"session.turn_count"`). This is
  used for crash recovery — the supervisor restarts the session and passes
  the last checkpoint to restore state.
  """
  @spec restore_checkpoint(GenServer.server(), map()) :: :ok
  def restore_checkpoint(session, checkpoint) when is_map(checkpoint) do
    GenServer.call(session, {:restore_checkpoint, checkpoint})
  end

  # ── Delegated functions (extracted to Builders) ─────────────────────

  @doc false
  defdelegate build_turn_values(state, message), to: Builders
  @doc false
  defdelegate build_heartbeat_values(state), to: Builders
  @doc false
  defdelegate apply_turn_result(state, message, result), to: Builders
  @doc false
  defdelegate apply_heartbeat_result(state, result), to: Builders
  @doc false
  defdelegate contracts_available?(), to: Builders

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
    execution_mode = Keyword.get(opts, :execution_mode, :session)
    config = Keyword.get(opts, :config, %{})
    seed_ref = Keyword.get(opts, :seed_ref)
    signal_topic = Keyword.get(opts, :signal_topic, "session:#{session_id}")
    trace_id = Keyword.get(opts, :trace_id)
    checkpoint = Keyword.get(opts, :checkpoint)

    # Verify trust_tier if a resolver is available (hierarchy constraint bridge).
    # Without a resolver, we trust the caller — but log a warning.
    trust_tier = Builders.verify_trust_tier(trust_tier, agent_id, adapters)

    # Initialize compactor if configured (runtime bridge — module lives in arbor_agent)
    compactor = Builders.init_compactor(Keyword.get(opts, :compactor))

    with {:ok, turn_graph} <- Builders.parse_dot_file(turn_dot_path),
         {:ok, heartbeat_graph} <- Builders.parse_dot_file(heartbeat_dot_path) do
      # Build contract structs if available (runtime bridge)
      {session_config, session_state, behavior} =
        Builders.build_contract_structs(
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
        compactor: compactor,
        adapters: adapters,
        heartbeat_interval: heartbeat_interval,
        session_type: session_type,
        execution_mode: execution_mode,
        config: config,
        seed_ref: seed_ref,
        signal_topic: signal_topic,
        trace_id: trace_id,
        session_config: session_config,
        session_state: session_state,
        behavior: behavior
      }

      # Restore from checkpoint if provided (crash recovery)
      state =
        if checkpoint do
          Builders.apply_checkpoint(state, checkpoint)
        else
          state
        end

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
  def handle_call({:send_message, _message}, _from, %{execution_mode: :legacy} = state) do
    {:reply, {:error, :legacy_mode}, state}
  end

  def handle_call({:send_message, _message}, _from, %{turn_in_flight: true} = state) do
    {:reply, {:error, :turn_in_progress}, state}
  end

  def handle_call({:send_message, message}, from, state) do
    case authorize_orchestrator(state) do
      :ok ->
        do_send_message_async(message, from, state)

      {:error, reason} ->
        {:reply, {:error, {:unauthorized, reason}}, state}
    end
  end

  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  def handle_call(:execution_mode, _from, state) do
    {:reply, state.execution_mode, state}
  end

  def handle_call({:restore_checkpoint, checkpoint}, _from, state) do
    {:reply, :ok, Builders.apply_checkpoint(state, checkpoint)}
  end

  defp do_send_message_async(message, from, state) do
    state = transition_phase(state, :idle, :input_received, :processing)
    values = Builders.build_turn_values(state, message)
    engine_opts = Builders.build_engine_opts(state, values)

    session_pid = self()
    turn_graph = state.turn_graph

    task_fn = fn ->
      result =
        try do
          Engine.run(turn_graph, engine_opts)
        rescue
          e -> {:error, {:engine_crash, Exception.message(e)}}
        end

      send(session_pid, {:turn_result, message, result})
    end

    task_sup = Arbor.Orchestrator.Session.TaskSupervisor

    {_task_pid, task_ref} =
      if Process.whereis(task_sup) do
        {:ok, pid} = Task.Supervisor.start_child(task_sup, task_fn)
        ref = Process.monitor(pid)
        {pid, ref}
      else
        {:ok, pid} = Task.start(task_fn)
        ref = Process.monitor(pid)
        {pid, ref}
      end

    new_state = %{state | turn_in_flight: true, turn_from: from, turn_task_ref: task_ref}
    {:noreply, new_state}
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

  def handle_info({:turn_result, message, {:ok, result}}, state) do
    new_state =
      state
      |> transition_phase(:processing, :complete, :idle)
      |> Builders.apply_turn_result(message, result)
      |> Builders.maybe_checkpoint()

    response = Map.get(result.context, "session.response", "")
    tool_history = Map.get(result.context, "session.tool_history", [])
    tool_rounds = Map.get(result.context, "session.tool_round_count", 0)
    Builders.emit_turn_signal(new_state, result)

    # Phase 3: notify ActionCycleServer of chat percept
    maybe_enqueue_chat_percept(state.agent_id, message)

    reply = {:ok, %{text: response, tool_history: tool_history, tool_rounds: tool_rounds}}
    safe_reply(state.turn_from, reply)

    if state.turn_task_ref, do: Process.demonitor(state.turn_task_ref, [:flush])
    {:noreply, %{new_state | turn_in_flight: false, turn_from: nil, turn_task_ref: nil}}
  end

  def handle_info({:turn_result, _message, {:error, reason}}, state) do
    new_state = transition_phase(state, :processing, :complete, :idle)

    safe_reply(state.turn_from, {:error, reason})

    if state.turn_task_ref, do: Process.demonitor(state.turn_task_ref, [:flush])
    {:noreply, %{new_state | turn_in_flight: false, turn_from: nil, turn_task_ref: nil}}
  end

  def handle_info({:heartbeat_result, {:ok, result}}, state) do
    completed = Map.get(result.context, "__completed_nodes__", [])
    llm_content = Map.get(result.context, "llm.content")

    Logger.info(
      "[Session] Heartbeat completed for #{state.agent_id}: " <>
        "#{length(completed)} nodes, content=#{if llm_content, do: "#{String.length(to_string(llm_content))} chars", else: "nil"}"
    )

    new_state =
      state
      |> Map.put(:heartbeat_in_flight, false)
      |> Builders.apply_heartbeat_result(result)
      |> Builders.maybe_checkpoint()

    Builders.emit_heartbeat_signal(new_state, result)
    {:noreply, new_state}
  end

  def handle_info({:heartbeat_result, {:error, reason}}, state) do
    Logger.warning("[Session] Heartbeat failed for #{state.agent_id}: #{inspect(reason)}")

    # Heartbeat failures are non-fatal — continue with current state
    new_state =
      state
      |> Map.put(:heartbeat_in_flight, false)
      |> maybe_increment_errors()

    Builders.emit_signal(:agent, :heartbeat_failed, %{
      agent_id: state.agent_id,
      session_id: state.session_id,
      reason: inspect(reason)
    })

    {:noreply, new_state}
  end

  # Handle Task DOWN messages
  def handle_info({:DOWN, ref, :process, _pid, :normal}, state) do
    # Clean up turn_task_ref if it matches
    if ref == state.turn_task_ref do
      {:noreply, %{state | turn_task_ref: nil}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    if ref == state.turn_task_ref do
      # Turn task crashed — reply to caller and reset
      new_state = transition_phase(state, :processing, :complete, :idle)
      safe_reply(state.turn_from, {:error, {:turn_task_crashed, reason}})
      {:noreply, %{new_state | turn_in_flight: false, turn_from: nil, turn_task_ref: nil}}
    else
      # Heartbeat task crashed — reset in_flight flag
      {:noreply, %{state | heartbeat_in_flight: false}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Private helpers ──────────────────────────────────────────────────

  # Reply to a caller safely — the caller may have timed out and died
  defp safe_reply(nil, _reply), do: :ok

  defp safe_reply(from, reply) do
    GenServer.reply(from, reply)
  catch
    _, _ -> :ok
  end

  defp start_heartbeat_task(state) do
    if state.heartbeat_in_flight do
      # Don't stack heartbeats — skip if one is already running
      state
    else
      case authorize_orchestrator(state) do
        :ok ->
          do_start_heartbeat_task(state)

        {:error, reason} ->
          Logger.warning("[Session] Heartbeat blocked: unauthorized (#{inspect(reason)})")
          state
      end
    end
  end

  defp do_start_heartbeat_task(state) do
    session_pid = self()
    values = Builders.build_heartbeat_values(state)
    engine_opts = Builders.build_engine_opts(state, values)
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

  defp schedule_heartbeat(state) do
    if state.heartbeat_ref, do: Process.cancel_timer(state.heartbeat_ref)
    ref = Process.send_after(self(), :heartbeat, state.heartbeat_interval)
    %{state | heartbeat_ref: ref}
  end

  # ── Gate-level orchestrator authorization ────────────────────────────
  #
  # Checks arbor://orchestrator/execute once per turn/heartbeat rather than
  # per-node. Council decision 2026-02-20: gate auth + action-level auth
  # provides defense-in-depth without O(N) per-node overhead.

  @orchestrator_resource "arbor://orchestrator/execute"

  defp authorize_orchestrator(state) do
    if Code.ensure_loaded?(Arbor.Security) and
         function_exported?(Arbor.Security, :authorize, 3) and
         Process.whereis(Arbor.Security.CapabilityStore) != nil do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      case apply(Arbor.Security, :authorize, [state.agent_id, @orchestrator_resource, :execute]) do
        {:ok, :authorized} -> :ok
        {:error, _reason} -> {:error, :orchestrator_not_authorized}
      end
    else
      # Security module not available (standalone orchestrator without security app).
      # In test env, CapabilityStore is started by test_helper.exs, so tests
      # always take the authorize path above.
      :ok
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # ── Contract-aware state mutation ───────────────────────────────────

  # Update session_state struct and keep flat fields in sync.
  # The update_fn receives the current session_state struct and must return
  # the updated struct.
  defp update_session_state(%{session_state: nil} = state, _update_fn), do: state

  defp update_session_state(%{session_state: ss} = state, update_fn) when not is_nil(ss) do
    updated_ss = update_fn.(ss)
    %{state | session_state: updated_ss}
  end

  # Increment error count on heartbeat failures (when session_state is available).
  defp maybe_increment_errors(%{session_state: nil} = state), do: state

  defp maybe_increment_errors(%{session_state: ss} = state) when not is_nil(ss) do
    if Builders.contracts_available?() do
      %{state | session_state: apply(state_module(), :increment_errors, [ss])}
    else
      state
    end
  end

  # Module references via functions to avoid compile-time warnings
  # when arbor_contracts is not in the dependency tree.
  defp state_module, do: Arbor.Contracts.Session.State
  defp behavior_module, do: Arbor.Contracts.Session.Behavior

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

  # ── Phase 3: percept forwarding ──────────────────────────────────

  defp maybe_enqueue_chat_percept(agent_id, message) do
    action_cycle_sup = Arbor.Agent.ActionCycleSupervisor

    if Code.ensure_loaded?(action_cycle_sup) do
      case apply(action_cycle_sup, :lookup, [agent_id]) do
        {:ok, pid} ->
          content = Builders.normalize_message(message)
          send(pid, {:percept, %{type: :chat, content: content, agent_id: agent_id}})

        :error ->
          :ok
      end
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp validate_transition(nil, _from, _event), do: :ok

  defp validate_transition(behavior, from, event) do
    if Builders.contracts_available?() do
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
