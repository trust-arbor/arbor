defmodule Arbor.Orchestrator.Session do
  @moduledoc """
  Session GenServer — drives agent turns through DOT graphs.

  Each Session holds a pre-parsed turn graph, accumulated messages,
  working memory, goals, and cognitive mode. External dependencies (LLM, tools,
  memory, etc.) are injected as adapter functions — the Session itself is pure
  orchestration.

  Heartbeats are handled by `Arbor.Orchestrator.HeartbeatService`, a separate
  supervised GenServer started as child #4 of `Arbor.Agent.BranchSupervisor`.

  ## Architecture

  A Session is the convergence point between `Arbor.Orchestrator.Engine` and
  the agent lifecycle. Rather than hand-coding turn logic in procedural
  Elixir, the Session delegates to graph execution:

      send_message/2  →  Engine.run(turn_graph, initial_values)  →  apply_turn_result/2

  Node implementations are provided by Jido Actions (via `exec target="action"`)
  and LlmHandler (via `compute` nodes). Session-specific actions live in
  `Arbor.Actions.Session*` modules.

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
    * `:session` — Session handles turns through DOT graphs (default).
    * `:graph`   — Full DOT graph execution with no fallback path.

  ## Turn execution

  **Turns** run in a spawned `Task` — the caller blocks on `GenServer.call` but
  the GenServer itself remains responsive. When the Task completes,
  the result is sent back as `{:turn_result, message, result}` and
  `GenServer.reply/2` unblocks the original caller. Only one turn can be
  in-flight at a time (concurrent turns get `{:error, :turn_in_progress}`).

  ## Example

      {:ok, pid} = Session.start_link(
        session_id: "session-1",
        agent_id: "agent_abc123",
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

  alias Arbor.Contracts.Pipeline.Response, as: PipelineResponse

  alias Arbor.Orchestrator.Engine
  alias Arbor.Orchestrator.Session.Builders
  alias Arbor.Orchestrator.Session.Persistence

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
    :turn_graph,
    # DOT file path — stored so reload_dot/1 can re-parse without restarting
    :turn_dot_path,
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
    # Async turn execution state
    turn_in_flight: false,
    turn_from: nil,
    turn_task_ref: nil,
    # Monitor ref for the GenServer.call caller (so we can clean in_flight state
    # if the caller times out or dies, preventing permanent :turn_in_progress lock)
    turn_caller_ref: nil,
    # Monotonic start time of the in-flight turn (native units), for the
    # [:arbor, :session, :turn] telemetry event emitted on completion.
    turn_started_at: nil,
    # Signer function for identity verification (fn resource -> {:ok, signed_request})
    signer: nil,
    # Progressive tool disclosure: tools discovered via find_tools during session
    discovered_tools: MapSet.new(),
    # Multi-user: identifies the acting principal (nil = single-user mode)
    tenant_context: nil,
    # The Session's own pid (set in init/1) so the streaming callback closure can
    # send chunks back here for durable accumulation.
    pid: nil,
    # Streaming partial preservation: the in-flight turn's user message, the
    # partial-stream accumulator, the turn-task pid (for cancel/timeout kill), and
    # the turn-timeout timer. On crash/cancel/timeout the partial is finalized as
    # an :interrupted/:cancelled AssistantMessage instead of being lost.
    turn_user_message: nil,
    streaming_buffer: nil,
    turn_task_pid: nil,
    turn_timeout_ref: nil,
    # Engagement multiplexing (single-mind model): one Session process per agent
    # holds many conversations. `messages` is the ACTIVE engagement's transcript;
    # `transcripts` stashes the others (engagement_id => [messages]);
    # `current_engagement_id` names the active one (nil = the default/back-compat
    # single conversation). Turns serialize through the one mind — a send arriving
    # mid-turn is appended to `turn_queue` (FIFO across engagements) and run when
    # the current turn finishes, rather than rejected. This preserves "one
    # continuous experience" without dropping input.
    current_engagement_id: nil,
    transcripts: %{},
    turn_queue: []
  ]

  @type phase :: :idle | :processing | :awaiting_tools | :awaiting_llm
  @type session_type :: :primary | :background | :delegation | :consultation
  @type execution_mode :: :legacy | :session | :graph

  @type t :: %__MODULE__{
          session_id: String.t(),
          agent_id: String.t(),
          turn_graph: Arbor.Orchestrator.Graph.t(),
          turn_dot_path: String.t() | nil,
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
          turn_in_flight: boolean(),
          turn_from: GenServer.from() | nil,
          turn_task_ref: reference() | nil,
          turn_caller_ref: reference() | nil,
          turn_started_at: integer() | nil,
          compactor: struct() | nil,
          session_config: struct() | nil,
          session_state: struct() | nil,
          behavior: struct() | nil,
          discovered_tools: MapSet.t(),
          pid: pid() | nil,
          turn_user_message: Arbor.Contracts.Session.UserMessage.t() | nil,
          streaming_buffer: map() | nil,
          turn_task_pid: pid() | nil,
          turn_timeout_ref: reference() | nil
        }

  # ── Public API ───────────────────────────────────────────────────────

  @doc """
  Start a Session process.

  ## Required options

    * `:session_id`    — unique session identifier
    * `:agent_id`      — the agent this session belongs to
    * `:turn_dot`      — path to the turn pipeline DOT file
    * `:heartbeat_dot` — path to the heartbeat pipeline DOT file (passed through for HeartbeatService)

  ## Optional

    * `:adapters`           — map of adapter functions (legacy, unused with action-based DOTs).
    * `:name`               — GenServer name registration
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
  @spec send_message(
          GenServer.server(),
          String.t() | map() | Arbor.Contracts.Session.UserMessage.t()
        ) ::
          {:ok, %{text: String.t(), tool_history: [map()], tool_rounds: non_neg_integer()}}
          | {:error, term()}
  def send_message(session, message) do
    GenServer.call(session, {:send_message, message}, Arbor.Orchestrator.Config.turn_timeout_ms())
  end

  @doc """
  Cancel the in-flight turn (user-initiated).

  Preserves whatever the assistant streamed so far as a `:cancelled`
  `AssistantMessage` (distinct from a system `:interrupted`), kills the turn
  task, and unblocks the session. Returns `:ok`, or `{:error, :no_turn_in_flight}`
  when nothing is running.
  """
  @spec cancel_turn(GenServer.server()) :: :ok | {:error, :no_turn_in_flight}
  def cancel_turn(session) do
    GenServer.call(session, :cancel_turn)
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
  Update the running session's LLM model. Reflected on the next turn —
  the DOT pipeline's LlmHandler reads `context["session.llm_model"]` which
  is sourced from `state.config["llm_model"]`.

  Use this from slash commands (`/model X`) and other operator surfaces.
  Returns the new model string so callers can echo it back.
  """
  @spec set_model(GenServer.server(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def set_model(session, model) when is_binary(model) do
    GenServer.call(session, {:set_model, model})
  end

  @doc """
  Update the running session's LLM provider. Reflected on the next turn —
  the DOT pipeline's LlmHandler reads `context["session.llm_provider"]`
  which is sourced from `state.config["llm_provider"]`.
  """
  @spec set_provider(GenServer.server(), atom() | String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def set_provider(session, provider) when is_atom(provider) and not is_nil(provider) do
    GenServer.call(session, {:set_provider, to_string(provider)})
  end

  def set_provider(session, provider) when is_binary(provider) do
    GenServer.call(session, {:set_provider, provider})
  end

  @doc """
  Update the running session's runtime axis (`:arbor` or `:acp`).
  Reflected on the next turn — LlmHandler reads
  `context["session.llm_runtime"]` and sets `request.runtime` so that
  `Arbor.AI.Runtime.Registry` dispatches to the right adapter.

  Used by the `/runtime` slash command and by `/model X runtime=Y` when
  the runtime opt is present.
  """
  @spec set_runtime(GenServer.server(), atom()) :: {:ok, atom()} | {:error, term()}
  def set_runtime(session, runtime) when runtime in [:arbor, :acp] do
    GenServer.call(session, {:set_runtime, runtime})
  end

  def set_runtime(_session, runtime) do
    {:error, {:invalid_runtime, runtime}}
  end

  @doc """
  Update the running session's LLM fallback chain. Reflected on the
  next turn / heartbeat — LlmHandler reads
  `context["session.llm_fallback_chain"]` and threads it into
  `policy.fallback_chain` on Dispatcher.dispatch.

  Each entry is an override map with optional `:runtime`, `:provider`,
  and/or `:model` fields. Used by the `/fallback` slash command and
  programmatic callers that want to rotate fallback paths per turn.

  Pass an empty list to clear the chain.
  """
  @spec set_fallback_chain(GenServer.server(), [map()]) ::
          {:ok, [map()]} | {:error, term()}
  def set_fallback_chain(session, chain) when is_list(chain) do
    GenServer.call(session, {:set_fallback_chain, chain})
  end

  def set_fallback_chain(_session, chain) do
    {:error, {:invalid_fallback_chain, chain}}
  end

  @doc """
  Return the running session's current fallback chain. Reads from
  `state.config["llm_fallback_chain"]`. Empty list when unset.
  """
  @spec get_fallback_chain(GenServer.server()) :: {:ok, [map()]} | {:error, term()}
  def get_fallback_chain(session) do
    GenServer.call(session, :get_fallback_chain)
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

  @doc """
  Re-parse the DOT pipeline files from disk and hot-reload the session graphs.

  Useful when DOT files change after a session is already running — without this,
  the session keeps its original parsed graphs indefinitely. Returns `:ok` if both
  graphs reload successfully, or `{:error, reason}` if either file fails to parse.
  """
  @spec reload_dot(GenServer.server()) :: :ok | {:error, term()}
  def reload_dot(session) do
    GenServer.call(session, :reload_dot)
  end

  # ── Delegated functions (extracted to Builders) ─────────────────────

  @doc false
  defdelegate build_turn_values(state, message), to: Builders
  @doc false
  defdelegate apply_turn_result(state, message, result), to: Builders
  @doc false
  defdelegate contracts_available?(), to: Builders

  # ── GenServer callbacks ──────────────────────────────────────────────

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    agent_id = Keyword.fetch!(opts, :agent_id)
    turn_dot_path = Keyword.fetch!(opts, :turn_dot)

    adapters = Keyword.get(opts, :adapters, %{})
    session_type = Keyword.get(opts, :session_type, :primary)
    execution_mode = Keyword.get(opts, :execution_mode, :session)
    config = Keyword.get(opts, :config, %{})
    seed_ref = Keyword.get(opts, :seed_ref)
    signal_topic = Keyword.get(opts, :signal_topic, "session:#{session_id}")
    trace_id = Keyword.get(opts, :trace_id)
    checkpoint = Keyword.get(opts, :checkpoint)
    signer = Keyword.get(opts, :signer)
    tenant_context = Keyword.get(opts, :tenant_context)

    # Initialize compactor if configured (runtime bridge — module lives in arbor_agent)
    compactor = Builders.init_compactor(Keyword.get(opts, :compactor))

    with {:ok, turn_graph} <- Builders.parse_dot_file(turn_dot_path) do
      # Build contract structs if available (runtime bridge)
      {session_config, session_state, behavior} =
        Builders.build_contract_structs(
          session_id: session_id,
          agent_id: agent_id,
          session_type: session_type,
          trace_id: trace_id,
          config: config,
          behavior: Keyword.get(opts, :behavior)
        )

      state = %__MODULE__{
        session_id: session_id,
        agent_id: agent_id,
        turn_graph: turn_graph,
        turn_dot_path: turn_dot_path,
        compactor: compactor,
        adapters: adapters,
        session_type: session_type,
        execution_mode: execution_mode,
        config: config,
        seed_ref: seed_ref,
        signal_topic: signal_topic,
        trace_id: trace_id,
        session_config: session_config,
        session_state: session_state,
        behavior: behavior,
        signer: signer,
        tenant_context: tenant_context,
        pid: self()
      }

      # Restore from checkpoint if provided (crash recovery)
      state =
        if checkpoint do
          Builders.apply_checkpoint(state, checkpoint)
        else
          state
        end

      # Grant security capabilities for the session's resolved tool set.
      # Tool exposure is profile/capability-derived (not trust-tier gated); the
      # agent needs matching capabilities for Security.authorize to succeed.
      alias Arbor.Orchestrator.Session.ToolDisclosure

      resolved_tools =
        ToolDisclosure.resolve_tools(
          config,
          Map.get(state, :discovered_tools, MapSet.new()),
          agent_id: agent_id
        )

      ToolDisclosure.ensure_tool_capabilities(agent_id, resolved_tools)

      # Subscribe to trust profile changes for reactive tool updates
      safe_subscribe_profile_signals(agent_id)

      {:ok, state}
    else
      {:error, reason} -> {:stop, {:bad_dot, reason}}
    end
  end

  @impl true
  def handle_call({:send_message, _message}, _from, %{execution_mode: :legacy} = state) do
    {:reply, {:error, :legacy_mode}, state}
  end

  # A send arriving mid-turn is QUEUED, not rejected. Single-mind serialization:
  # the one mind finishes its current turn, then drains the queue in FIFO order
  # (across all engagements). The caller's GenServer.call blocks until its turn
  # actually runs and replies (via turn_from). Coerce here so the queued entry is
  # already a typed envelope (carrying its engagement_id).
  def handle_call({:send_message, message}, from, %{turn_in_flight: true} = state) do
    user_message = coerce_user_message(message)
    {:noreply, %{state | turn_queue: state.turn_queue ++ [{user_message, from}]}}
  end

  def handle_call({:send_message, message}, from, state) do
    # Slash commands are parsed at each adapter's intake (CommandIntake), not
    # here; by the time a message reaches Session it has been classified as a
    # regular prompt. Session stays a pure runtime container.
    message |> coerce_user_message() |> start_turn(from, state)
  end

  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  # User cancellation: preserve whatever streamed as a :cancelled partial, kill the
  # turn task, unblock the original caller and the session. The demonitor [:flush]
  # before the kill means the task's :DOWN is dropped and can't re-finalize.
  def handle_call(:cancel_turn, _from, %{turn_in_flight: true} = state) do
    new_state = transition_phase(state, :processing, :complete, :idle)
    finalize_partial(state, :cancelled, :user_cancelled)
    safe_reply(state.turn_from, {:error, :cancelled})

    if state.turn_task_ref, do: Process.demonitor(state.turn_task_ref, [:flush])
    if state.turn_caller_ref, do: Process.demonitor(state.turn_caller_ref, [:flush])
    if is_pid(state.turn_task_pid), do: Process.exit(state.turn_task_pid, :kill)

    # Cancelling the active turn frees the mind — let queued turns proceed.
    send(self(), :drain_queue)
    {:reply, :ok, reset_turn(new_state)}
  end

  def handle_call(:cancel_turn, _from, state) do
    {:reply, {:error, :no_turn_in_flight}, state}
  end

  def handle_call(:execution_mode, _from, state) do
    {:reply, state.execution_mode, state}
  end

  # Phase 2d mutator handlers. State.config is the map ContextBuilder
  # reads when assembling DOT pipeline values, so updating it here
  # propagates to the next turn without any further wiring.

  def handle_call({:set_model, model}, _from, state) do
    new_config = Map.put(state.config || %{}, "llm_model", model)

    Logger.info("[Session #{state.agent_id}] /model → #{model} (effective on next turn)")

    {:reply, {:ok, model}, %{state | config: new_config}}
  end

  def handle_call({:set_provider, provider}, _from, state) do
    new_config = Map.put(state.config || %{}, "llm_provider", provider)

    Logger.info("[Session #{state.agent_id}] provider → #{provider} (effective on next turn)")

    {:reply, {:ok, provider}, %{state | config: new_config}}
  end

  def handle_call({:set_runtime, runtime}, _from, state) do
    new_config = Map.put(state.config || %{}, "llm_runtime", runtime)

    Logger.info("[Session #{state.agent_id}] /runtime → #{runtime} (effective on next turn)")

    {:reply, {:ok, runtime}, %{state | config: new_config}}
  end

  def handle_call({:set_fallback_chain, chain}, _from, state) do
    new_config = Map.put(state.config || %{}, "llm_fallback_chain", chain)

    Logger.info(
      "[Session #{state.agent_id}] /fallback → #{length(chain)} entries (effective on next turn)"
    )

    {:reply, {:ok, chain}, %{state | config: new_config}}
  end

  def handle_call(:get_fallback_chain, _from, state) do
    chain =
      case state.config || %{} do
        %{"llm_fallback_chain" => c} when is_list(c) -> c
        %{llm_fallback_chain: c} when is_list(c) -> c
        _ -> []
      end

    {:reply, {:ok, chain}, state}
  end

  def handle_call({:restore_checkpoint, checkpoint}, _from, state) do
    {:reply, :ok, Builders.apply_checkpoint(state, checkpoint)}
  end

  def handle_call(:reload_dot, _from, state) do
    case Builders.parse_dot_file(state.turn_dot_path) do
      {:ok, turn_graph} ->
        Logger.info("[Session] Reloaded turn DOT graph for #{state.agent_id}")
        {:reply, :ok, %{state | turn_graph: turn_graph}}

      {:error, reason} ->
        Logger.warning(
          "[Session] Failed to reload DOT graph for #{state.agent_id}: #{inspect(reason)}"
        )

        {:reply, {:error, reason}, state}
    end
  end

  defp do_send_message_async(%Arbor.Contracts.Session.UserMessage{} = user_message, from, state) do
    state = transition_phase(state, :idle, :input_received, :processing)
    # The engine still receives the bare content string — only the persistence
    # path needs the typed envelope, and that's threaded via the {:turn_result,
    # user_message, result} tuple below.
    values = Builders.build_turn_values(state, user_message.content)

    # Pre-turn preprocessor (disabled by default, fails open). When enabled it
    # attaches enrichment under "session.preprocessor.*". See
    # Arbor.Orchestrator.Preprocessor and docs/arbor/PREPROCESSOR.md.
    values = maybe_preprocess(values, user_message.content)

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

      send(session_pid, {:turn_result, user_message, result})
    end

    task_sup = Arbor.Orchestrator.Session.TaskSupervisor

    {task_pid, task_ref} =
      if Process.whereis(task_sup) do
        {:ok, pid} = Task.Supervisor.start_child(task_sup, task_fn)
        ref = Process.monitor(pid)
        {pid, ref}
      else
        {:ok, pid} = Task.start(task_fn)
        ref = Process.monitor(pid)
        {pid, ref}
      end

    caller_pid = elem(from, 0)
    caller_ref = Process.monitor(caller_pid)

    # Streaming partial preservation: arm a hung-task safety-net timeout and open
    # an accumulator the stream callback writes into. The buffer's started_at is
    # wall-clock (the partial AssistantMessage's started_at when finalized).
    timeout_ref = Process.send_after(self(), {:turn_timeout, task_ref}, turn_timeout_ms(state))

    new_state = %{
      state
      | turn_in_flight: true,
        turn_from: from,
        turn_task_ref: task_ref,
        turn_task_pid: task_pid,
        turn_caller_ref: caller_ref,
        turn_started_at: System.monotonic_time(),
        turn_user_message: user_message,
        streaming_buffer: %{content: "", started_at: DateTime.utc_now(), first_token_at: nil},
        turn_timeout_ref: timeout_ref
    }

    {:noreply, new_state}
  end

  # Run the pre-turn preprocessor when enabled; merge its output into turn values
  # under "session.preprocessor.*". Disabled-by-default and fail-open: any failure
  # leaves `values` unchanged so the turn proceeds exactly as before.
  defp maybe_preprocess(values, content) do
    {:ok, preproc} = Arbor.Orchestrator.Preprocessor.run(content)

    if preproc == %{} do
      values
    else
      namespaced = Map.new(preproc, fn {k, v} -> {"session.preprocessor.#{k}", v} end)
      values = Map.merge(values, namespaced)
      apply_preprocessor_tools(values, preproc)
    end
  rescue
    _ -> values
  end

  # Engine consumption of the preprocessor: override the turn's tool list based on
  # tier / retrieved tools. `LlmHandler.resolve_tools/3` reads "session.tools" first,
  # so this controls exactly which tools the LLM call sees. DIRECT empties the list
  # (no-tools fast lane) unless `direct_skips_tools` is disabled in config.
  defp apply_preprocessor_tools(values, preproc) do
    direct_skips? =
      Keyword.get(Arbor.Orchestrator.Config.preprocessor(), :direct_skips_tools, true)

    case Arbor.Orchestrator.Preprocessor.tool_override(preproc,
           direct_skips_tools?: direct_skips?
         ) do
      {:override, tools} -> Map.put(values, "session.tools", tools)
      :no_override -> values
    end
  end

  # Drain the next queued turn once the current one has finished. Triggered as a
  # self-message from reset_and_drain/1 (so turn_in_flight is already cleared).
  # Idempotent: a no-op if a turn is somehow still in flight or the queue is empty.
  @impl true
  def handle_info(:drain_queue, %{turn_in_flight: true} = state), do: {:noreply, state}
  def handle_info(:drain_queue, %{turn_queue: []} = state), do: {:noreply, state}

  def handle_info(:drain_queue, %{turn_queue: [{user_message, from} | rest]} = state) do
    start_turn(user_message, from, %{state | turn_queue: rest})
  end

  def handle_info(
        {:turn_result, %Arbor.Contracts.Session.UserMessage{} = user_message, {:ok, result}},
        state
      ) do
    completed = Map.get(result.context, "__completed_nodes__", [])

    new_state =
      state
      |> transition_phase(:processing, :complete, :idle)
      |> Builders.apply_turn_result(user_message.content, result, user_message: user_message)
      |> persist_discovered_tools(result)
      |> Builders.maybe_checkpoint()

    response = Map.get(result.context, "session.response", "")

    tool_history = Map.get(result.context, "session.tool_history", [])
    tool_rounds = Map.get(result.context, "session.tool_round_count", 0)

    Logger.info(
      "[Session] Turn completed for #{state.agent_id}: " <>
        "#{length(completed)} nodes, response=#{if response != "", do: "#{String.length(to_string(response))} chars", else: "EMPTY"}, " <>
        "completed=#{inspect(completed)}"
    )

    Builders.emit_turn_signal(new_state, result)

    # Phase 3: notify ActionCycleServer of chat percept
    maybe_enqueue_chat_percept(state.agent_id, user_message.content)

    usage = Map.get(result.context, "session.usage", %{})

    # NOTE: turn persistence is handled inside `Builders.apply_turn_result/3`
    # via `Persistence.persist_turn_entries/5`. Calling a second persistence
    # path here used to double-write every turn, leaving an orphan duplicate
    # of the user message at the end of restored chat history (the legacy
    # path read `session.response` which is now `""`, so only the user write
    # succeeded — assistant write was gated out, producing the asymmetric
    # duplicate Hysun reported on 2026-04-07).

    # Record turn telemetry
    maybe_record_telemetry(:turn, state.agent_id, %{
      input_tokens: usage["input_tokens"] || usage[:input_tokens] || 0,
      output_tokens: usage["output_tokens"] || usage[:output_tokens] || 0,
      cached_tokens:
        usage["cached_tokens"] || usage[:cached_tokens] ||
          usage["cache_read_input_tokens"] || 0,
      duration_ms: usage["duration_ms"] || usage[:duration_ms],
      provider:
        usage["provider"] || usage[:provider] ||
          Map.get(result.context, "session.provider") ||
          Map.get(result.context, "session.llm_provider")
    })

    emit_turn_telemetry(state.turn_started_at, %{
      agent_id: state.agent_id,
      status: :ok,
      node_count: length(completed)
    })

    reply =
      {:ok,
       PipelineResponse.normalize(%{
         text: response,
         tool_history: tool_history,
         tool_rounds: tool_rounds,
         usage: usage
       })}

    safe_reply(state.turn_from, reply)

    if state.turn_task_ref, do: Process.demonitor(state.turn_task_ref, [:flush])
    if state.turn_caller_ref, do: Process.demonitor(state.turn_caller_ref, [:flush])

    # Normal completion: apply_turn_result already persisted the complete message,
    # so just clear the turn (incl. buffer + timeout).
    reset_and_drain(new_state)
  end

  def handle_info({:turn_result, _user_message, {:error, reason}}, state) do
    Logger.warning("[Session] Turn FAILED for #{state.agent_id}: #{inspect(reason)}")
    new_state = transition_phase(state, :processing, :complete, :idle)

    emit_turn_telemetry(state.turn_started_at, %{agent_id: state.agent_id, status: :error})

    # Engine errors (incl. rescued engine crashes) arrive here — preserve whatever
    # streamed before the failure as an :interrupted partial.
    finalize_partial(state, :interrupted, reason)

    safe_reply(state.turn_from, {:error, reason})

    if state.turn_task_ref, do: Process.demonitor(state.turn_task_ref, [:flush])
    if state.turn_caller_ref, do: Process.demonitor(state.turn_caller_ref, [:flush])

    reset_and_drain(new_state)
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

  # Non-normal :DOWN — either the turn task crashed, or the send_message caller
  # died/timed out (finite timeout). Both must clear in-flight state so the
  # session accepts future turns. Single clause because both match the same
  # {:DOWN, ...} pattern — a separate clause would be unreachable.
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    cond do
      ref == state.turn_task_ref ->
        # Turn task died non-normally (exit/kill/linked death the task's rescue
        # didn't catch) — preserve any streamed partial, reply, reset.
        new_state = transition_phase(state, :processing, :complete, :idle)
        finalize_partial(state, :interrupted, {:task_down, reason})
        safe_reply(state.turn_from, {:error, {:turn_task_crashed, reason}})
        if state.turn_caller_ref, do: Process.demonitor(state.turn_caller_ref, [:flush])

        reset_and_drain(new_state)

      not is_nil(state.turn_caller_ref) and ref == state.turn_caller_ref ->
        # Caller died/timed out. Clear in-flight so future turns are accepted;
        # the background task (if any) completes and hits safe_reply (noop). We do
        # NOT finalize a partial here — the turn isn't interrupted, only the caller
        # left; the task runs on and persists the complete message itself.
        Logger.info(
          "[Session] send_message caller died (timeout or crash) for #{state.agent_id}; clearing in-flight state to unblock future turns"
        )

        if state.turn_task_ref, do: Process.demonitor(state.turn_task_ref, [:flush])
        new_state = transition_phase(state, :processing, :complete, :idle)

        reset_and_drain(new_state)

      true ->
        {:noreply, state}
    end
  end

  # Handle trust profile change signals — rebuild tool visibility
  def handle_info(
        {:signal_received, %{category: :trust, type: type, data: %{agent_id: signal_agent_id}}},
        state
      )
      when type in [:profile_updated, :profile_changed] do
    if signal_agent_id == state.agent_id do
      alias Arbor.Orchestrator.Session.ToolDisclosure

      # Rebuild tool list from updated profile
      resolved_tools =
        ToolDisclosure.resolve_tools(
          state.config,
          state.discovered_tools,
          agent_id: state.agent_id
        )

      # Revoke stale JIT-granted capabilities for this session
      safe_revoke_session_capabilities(state.session_id)

      Logger.debug(
        "Session #{state.session_id}: rebuilt tools after profile change (#{length(resolved_tools)} tools)"
      )

      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  # Streaming partial preservation: the turn's stream callback (running in the
  # turn Task) sends each chunk here so the partial survives a Task crash. We
  # accumulate into the in-flight buffer; if there's no active buffer (late chunk
  # after the turn already finalized), drop it.
  def handle_info({:stream_chunk, text}, %{streaming_buffer: buf} = state)
      when is_map(buf) and is_binary(text) do
    first_token_at = buf.first_token_at || if(text != "", do: DateTime.utc_now())
    updated = %{buf | content: buf.content <> text, first_token_at: first_token_at}
    {:noreply, %{state | streaming_buffer: updated}}
  end

  def handle_info({:stream_chunk, _text}, state), do: {:noreply, state}

  # Hung-task safety net: if the turn task neither completed nor crashed within
  # the timeout, preserve the partial as :interrupted (reason :timeout), kill the
  # task, and unblock the session. Only acts if `ref` is still the active turn.
  def handle_info({:turn_timeout, ref}, %{turn_task_ref: ref} = state) when not is_nil(ref) do
    Logger.warning("[Session] Turn timed out for #{state.agent_id}; preserving partial")
    new_state = transition_phase(state, :processing, :complete, :idle)
    finalize_partial(state, :interrupted, :timeout)
    safe_reply(state.turn_from, {:error, :turn_timeout})

    # Detach + kill the task so its impending :DOWN can't re-finalize.
    if state.turn_task_ref, do: Process.demonitor(state.turn_task_ref, [:flush])
    if state.turn_caller_ref, do: Process.demonitor(state.turn_caller_ref, [:flush])
    if is_pid(state.turn_task_pid), do: Process.exit(state.turn_task_pid, :kill)

    reset_and_drain(new_state)
  end

  # Stale timeout (turn already finished / a different turn now) — ignore.
  def handle_info({:turn_timeout, _ref}, state), do: {:noreply, state}

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Private helpers ──────────────────────────────────────────────────

  # Persist tools discovered via find_tools during this turn into session state.
  # The ToolLoop returns discovered tool names in its result; the LlmHandler
  # propagates them into the engine context as "session.discovered_tool_names".
  defp persist_discovered_tools(state, result) do
    alias Arbor.Orchestrator.Session.ToolDisclosure

    # Check engine context for discovered tool names from LlmHandler/ToolLoop
    new_names =
      case Map.get(result.context, "session.discovered_tool_names") do
        names when is_list(names) and names != [] -> names
        _ -> []
      end

    if new_names == [] do
      state
    else
      # Grant security capabilities for newly discovered tools
      ToolDisclosure.ensure_tool_capabilities(state.agent_id, new_names)

      merged = ToolDisclosure.merge_discovered(state.discovered_tools, new_names)
      %{state | discovered_tools: merged}
    end
  end

  # Reply to a caller safely — the caller may have timed out and died
  defp safe_reply(nil, _reply), do: :ok

  defp safe_reply(from, reply) do
    GenServer.reply(from, reply)
  catch
    _, _ -> :ok
  end

  # ── Streaming partial preservation helpers ───────────────────────────

  # Clear all in-flight turn state (incl. the stream buffer + user message) and
  # cancel the hung-task timeout. Used by every turn-end path.
  # Coerce any incoming shape (bare string, %UserMessage{}, legacy map) into a
  # UserMessage envelope at the entry boundary — the single point where we know
  # the message just arrived from an adapter, so the right place to honor
  # `sent_at` and carry the resolved `engagement_id`.
  defp coerce_user_message(%Arbor.Contracts.Session.UserMessage{} = um), do: um

  defp coerce_user_message(bin) when is_binary(bin),
    do: Arbor.Contracts.Session.UserMessage.from_string(bin)

  defp coerce_user_message(%{"content" => c}) when is_binary(c),
    do: Arbor.Contracts.Session.UserMessage.from_string(c)

  defp coerce_user_message(%{content: c}) when is_binary(c),
    do: Arbor.Contracts.Session.UserMessage.from_string(c)

  defp coerce_user_message(other),
    do: Arbor.Contracts.Session.UserMessage.from_string(inspect(other))

  # Switch the active engagement (single-mind model): stash the current
  # transcript under its id, load the target's (empty list on first contact).
  # No-op when the target is nil (the default/back-compat conversation) or is
  # already active. `messages` always holds the ACTIVE engagement's transcript,
  # so the turn loop / SessionCore / Builders / ContextBuilder need no changes.
  defp maybe_switch_engagement(state, nil), do: state
  defp maybe_switch_engagement(%{current_engagement_id: target} = state, target), do: state

  defp maybe_switch_engagement(state, target) do
    stashed = Map.put(state.transcripts, state.current_engagement_id, state.messages)

    {target_msgs, stashed} =
      if Map.has_key?(stashed, target) do
        # Already loaded in this process — use the in-memory stash.
        Map.pop(stashed, target)
      else
        # First time this engagement is active here. Restore its transcript from
        # the durable store (entries stamped with this engagement_id) so a resumed
        # conversation isn't empty after a restart / on a fresh device. Returns []
        # for a brand-new engagement or if the store is unavailable.
        {Persistence.load_engagement_transcript(state, target), stashed}
      end

    # Mirror the active transcript into session_state — ContextBuilder.get_messages/1
    # reads `session_state.messages` in preference to top-level `messages`, so both
    # must move together or the turn would see the previous engagement's history.
    %{state | messages: target_msgs, transcripts: stashed, current_engagement_id: target}
    |> Persistence.sync_checkpoint_to_session_state()
  end

  # Authorize, then start the turn — shared by direct sends and queue drains.
  # Replies are sent explicitly (GenServer.reply) so this returns {:noreply, _}
  # uniformly, matching do_send_message_async (which replies later from the turn
  # task). On auth failure the caller is told and the session stays idle.
  defp start_turn(user_message, from, state) do
    state = maybe_switch_engagement(state, user_message.engagement_id)

    case authorize_orchestrator(state) do
      :ok ->
        do_send_message_async(user_message, from, state)

      {:error, reason} ->
        safe_reply(from, {:error, {:unauthorized, reason}})
        {:noreply, state}
    end
  end

  # End the current turn and trigger draining of any queued turns. The drain runs
  # as a self-message after this handler returns (turn_in_flight already cleared
  # by reset_turn), so the next queued turn starts cleanly.
  defp reset_and_drain(state) do
    send(self(), :drain_queue)
    {:noreply, reset_turn(state)}
  end

  defp reset_turn(state) do
    cancel_turn_timeout(state)

    %{
      state
      | turn_in_flight: false,
        turn_from: nil,
        turn_task_ref: nil,
        turn_task_pid: nil,
        turn_caller_ref: nil,
        turn_started_at: nil,
        turn_user_message: nil,
        streaming_buffer: nil,
        turn_timeout_ref: nil
    }
  end

  defp cancel_turn_timeout(%{turn_timeout_ref: ref}) when is_reference(ref) do
    Process.cancel_timer(ref)
    :ok
  end

  defp cancel_turn_timeout(_), do: :ok

  defp turn_timeout_ms(state) do
    case state.config do
      %{turn_timeout_ms: ms} when is_integer(ms) and ms > 0 -> ms
      _ -> Arbor.Orchestrator.Config.turn_timeout_ms()
    end
  end

  # Persist whatever streamed before an interruption as a partial AssistantMessage
  # (:interrupted for system failures, :cancelled for user cancel). No-op unless
  # there's accumulated content AND a known in-flight user message. Never raises.
  defp finalize_partial(state, status, reason) do
    buf = state.streaming_buffer

    if is_map(buf) and is_binary(buf.content) and buf.content != "" and
         not is_nil(state.turn_user_message) do
      Builders.apply_turn_interruption(state, status, reason)
    end

    :ok
  rescue
    e ->
      Logger.warning("[Session] partial-preservation persist failed: #{Exception.message(e)}")
      :ok
  end

  # ── Gate-level orchestrator authorization ────────────────────────────
  #
  # Checks arbor://orchestrator/execute once per turn (defense-in-depth with
  # the per-node CapabilityCheck middleware). Uses the centralized
  # Authorization module which is fail-closed by default (see Config).

  defp authorize_orchestrator(state) do
    Arbor.Orchestrator.Authorization.check_orchestrator_access(state.agent_id, state.signer)
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

  # Module references via functions to avoid compile-time warnings
  # when arbor_contracts is not in the dependency tree.
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

  # Subscribe to trust profile change signals for reactive tool updates.
  # arbor_signals is a hard dep; the rescue/catch guards only against the
  # signal bus process not being alive (standalone/test slices).
  defp safe_subscribe_profile_signals(agent_id) do
    Arbor.Signals.subscribe("trust.profile_updated", %{agent_id: agent_id})
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # Revoke session-scoped capabilities (cleanup after profile change or
  # termination). arbor_security is a hard dep; the rescue/catch guards only
  # against the CapabilityStore process not being alive.
  defp safe_revoke_session_capabilities(session_id) do
    Arbor.Security.revoke_by_session(session_id)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # Emit the [:arbor, :session, :turn] telemetry event on turn completion. Async turns
  # can't use :telemetry.span/3 (dispatch and result land in different callbacks), so we
  # time it manually: start captured in do_send_message_async, duration (native units)
  # computed here. No-op when no start time was recorded. Attach a handler via
  # Arbor.Signals.Telemetry to profile turn latency.
  defp emit_turn_telemetry(nil, _meta), do: :ok

  defp emit_turn_telemetry(started_at, meta) do
    duration = System.monotonic_time() - started_at
    :telemetry.execute([:arbor, :session, :turn], %{duration: duration}, meta)
  rescue
    _ -> :ok
  end

  # Record agent telemetry via the Store (non-critical — failures are silently ignored)
  defp maybe_record_telemetry(type, agent_id, data) do
    store = Arbor.Common.AgentTelemetry.Store

    if Code.ensure_loaded?(store) do
      case type do
        :turn ->
          store.record_turn(agent_id, data)

        :tool ->
          store.record_tool(agent_id, data[:name], data[:result], data[:duration_ms])

        :routing ->
          store.record_routing(agent_id, data[:decision])

        :compaction ->
          store.record_compaction(agent_id, data[:utilization])
      end
    end
  rescue
    e ->
      Logger.debug("[Session] Telemetry recording failed: #{inspect(e)}")
      :ok
  catch
    :exit, reason ->
      Logger.debug("[Session] Telemetry recording exit: #{inspect(reason)}")
      :ok
  end
end
