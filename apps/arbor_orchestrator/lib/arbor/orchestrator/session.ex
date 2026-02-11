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

  # ── State ────────────────────────────────────────────────────────────

  defstruct [
    :session_id,
    :agent_id,
    :trust_tier,
    :turn_graph,
    :heartbeat_graph,
    :trace_id,
    :seed_ref,
    :signal_topic,
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
          heartbeat_in_flight: boolean()
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
        trace_id: trace_id
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
    state = %{state | phase: :processing}
    values = build_turn_values(state, message)
    engine_opts = build_engine_opts(state, values)

    try do
      case Engine.run(state.turn_graph, engine_opts) do
        {:ok, result} ->
          new_state = apply_turn_result(%{state | phase: :idle}, message, result)
          response = Map.get(result.context, "session.response", "")
          {:reply, {:ok, response}, new_state}

        {:error, reason} ->
          {:reply, {:error, reason}, %{state | phase: :idle}}
      end
    rescue
      e ->
        {:reply, {:error, {:engine_crash, Exception.message(e)}}, %{state | phase: :idle}}
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
    new_state = apply_heartbeat_result(%{state | heartbeat_in_flight: false}, result)
    {:noreply, new_state}
  end

  def handle_info({:heartbeat_result, {:error, _reason}}, state) do
    # Heartbeat failures are non-fatal — continue with current state
    {:noreply, %{state | heartbeat_in_flight: false}}
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
    messages_with_input = state.messages ++ [user_msg]

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
    Map.put(base, "session.messages", state.messages)
  end

  defp session_base_values(state) do
    %{
      "session.id" => state.session_id,
      "session.agent_id" => state.agent_id,
      "session.trust_tier" => to_string(state.trust_tier),
      "session.turn_count" => state.turn_count,
      "session.working_memory" => state.working_memory,
      "session.goals" => state.goals,
      "session.cognitive_mode" => to_string(state.cognitive_mode),
      "session.phase" => to_string(state.phase),
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
          state.messages ++ [user_msg, assistant_msg]
      end

    updated_wm =
      case Map.get(result_ctx, "session.working_memory") do
        wm when is_map(wm) -> wm
        _ -> state.working_memory
      end

    %{
      state
      | messages: updated_messages,
        working_memory: updated_wm,
        turn_count: state.turn_count + 1
    }
  end

  @doc false
  @spec apply_heartbeat_result(t(), Engine.run_result()) :: t()
  def apply_heartbeat_result(state, %{context: result_ctx}) do
    # Cognitive mode from the mode_select handler
    cognitive_mode =
      case Map.get(result_ctx, "session.cognitive_mode") do
        mode when is_binary(mode) and mode != "" ->
          safe_to_atom(mode, state.cognitive_mode)

        _ ->
          state.cognitive_mode
      end

    # Goal updates from process_results handler
    goal_updates = Map.get(result_ctx, "session.goal_updates", [])
    new_goals = Map.get(result_ctx, "session.new_goals", [])
    goals = apply_goal_changes(state.goals, goal_updates, new_goals)

    %{state | cognitive_mode: cognitive_mode, goals: goals}
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

      {:ok, _pid} =
        Task.start(fn ->
          result =
            try do
              Engine.run(heartbeat_graph, engine_opts)
            rescue
              e -> {:error, {:engine_crash, Exception.message(e)}}
            end

          send(session_pid, {:heartbeat_result, result})
        end)

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
end
