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

      send_message/2  →  Engine.run(turn_graph, initial_values)
                      →  admit final_outcome (:success | :partial_success)
                      →  apply_turn_result/...

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
  the result is sent back as `{:turn_result, turn_token, message, result}` and
  `GenServer.reply/2` unblocks the original caller. Only one turn can be
  in-flight at a time (concurrent turns get `{:error, :turn_in_progress}`).
  Stale or forged tokens are ignored so a detached background task cannot
  finalize a newer turn.

  `Engine.run/2` returning `{:ok, run_result}` only proves an envelope was
  produced — it is **not** success. Session admits only
  `final_outcome.status` of `:success` or `:partial_success` before
  `apply_turn_result` / success signaling; every other final outcome fails
  closed with a bounded `{:error, :turn_failed}`.

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
  alias Arbor.Contracts.Comms.Engagement
  alias Arbor.Contracts.Security.DeliveryReceipt
  alias Arbor.Contracts.Security.Taint
  alias Arbor.Contracts.Session.SteeringMessage
  alias Arbor.Contracts.Session.TurnAuthority
  alias Arbor.Contracts.Session.UserMessage
  alias Arbor.Identifiers

  alias Arbor.Orchestrator.Engine
  alias Arbor.Orchestrator.Session.Builders
  alias Arbor.Orchestrator.Session.Persistence
  alias Arbor.Orchestrator.Session.TurnEgress

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
    # Context compactor for progressive forgetting (nil = disabled). The
    # construction spec is process-local configuration used only to initialize
    # a fresh engagement; inactive compactors are stashed alongside transcripts.
    :compactor,
    :compactor_spec,
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
    # Callers whose mid-turn messages were folded into THIS turn as steering — they receive
    # the same turn result as turn_from when it completes.
    steer_froms: [],
    # Process-local ownership for accepted steering callers. Each bounded record
    # retains the caller monitor and source task id; no steering content or
    # provenance is retained here or projected publicly.
    steer_caller_ownership: [],
    turn_task_ref: nil,
    # Monitor ref for the GenServer.call caller (so we can clean in_flight state
    # if the caller times out or dies, preventing permanent :turn_in_progress lock)
    turn_caller_ref: nil,
    # Monotonic start time of the in-flight turn (native units), for the
    # [:arbor, :session, :turn] telemetry event emitted on completion.
    turn_started_at: nil,
    # Legacy signer compatibility only. Production Lifecycle wiring stores the
    # reload-stable authority below and leaves this nil.
    signer: nil,
    signing_authority: nil,
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
    # Process-local authenticated-turn identity (nil for direct/unauthenticated sends).
    # Never enters Engine values, checkpoints, signals, or public errors.
    turn_authority: nil,
    # VP-05D2A1P5: private process-local fence for the active turn-egress authorizer.
    # Deactivated before kill/revoke on every terminal path. Never public.
    turn_egress_fence: nil,
    # VP-05D2A1P5: process-local turn result token. Real task results must carry
    # the exact reference; stale/detached/forged results are ignored. Never
    # public, never Engine context.
    turn_token: nil,
    # VP-05D2B: process-local steering replay/resource accounting. Boundary
    # references and counters never enter Engine values, checkpoints, or the
    # public state projection.
    steering_boundaries: MapSet.new(),
    steering_message_count: 0,
    steering_byte_count: 0,
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
    # Queue entries: {UserMessage, TurnAuthority | nil, GenServer.from()}.
    current_engagement_id: nil,
    transcripts: %{},
    compactors: %{},
    turn_queue: [],
    # Bounded task-id cancellation tombstones: reject a later send_message that
    # still carries a cancelled async-task id (race: cancel before Session sees
    # the task, or cancel while the matching turn is only queued). FIFO-capped.
    cancelled_task_ids: %{},
    cancelled_task_id_order: []
  ]

  # Max tombstones retained per session. Async task ids are unique; once the
  # TaskStore has marked the task cancelled the runner is dead, so a short
  # retention window is enough for in-flight queue/start races.
  @max_cancelled_task_ids 64

  # Reversible process-local admission policy. Bounding queued turns also bounds
  # every steering scan, including cross-engagement retention scans.
  @max_turn_queue_entries 128

  # A callback process exit/timeout cannot prove whether Session accepted a
  # boundary before the caller lost the reply. Keep one closed local error for
  # the ToolLoop worker to classify as delivery ambiguity.
  @steering_delivery_ambiguous {:error, :steering_delivery_ambiguous}

  # Admitted Engine terminal statuses for Session turn application.
  # Engine.run/2 returning {:ok, run_result} alone is not success.
  @admitted_final_statuses [:success, :partial_success]

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
          signer: (binary() -> {:ok, term()} | {:error, term()}) | nil,
          signing_authority: Arbor.Contracts.Security.SigningAuthority.t() | nil,
          turn_in_flight: boolean(),
          turn_from: GenServer.from() | nil,
          turn_task_ref: reference() | nil,
          turn_caller_ref: reference() | nil,
          turn_started_at: integer() | nil,
          compactor: struct() | nil,
          compactor_spec: {module(), keyword()} | nil,
          session_config: struct() | nil,
          session_state: struct() | nil,
          behavior: struct() | nil,
          discovered_tools: MapSet.t(),
          pid: pid() | nil,
          turn_user_message: Arbor.Contracts.Session.UserMessage.t() | nil,
          turn_authority: TurnAuthority.t() | nil,
          turn_egress_fence: term() | nil,
          turn_token: reference() | nil,
          steering_boundaries: MapSet.t() | nil,
          steering_message_count: non_neg_integer() | nil,
          steering_byte_count: non_neg_integer() | nil,
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
  and the response is returned as `%Arbor.Contracts.Pipeline.Response{}`.
  """
  @spec send_message(
          GenServer.server(),
          String.t() | map() | Arbor.Contracts.Session.UserMessage.t()
        ) ::
          {:ok, PipelineResponse.t()}
          | {:error, term()}
  def send_message(session, message) do
    GenServer.call(session, {:send_message, message}, Arbor.Orchestrator.Config.turn_timeout_ms())
  end

  @doc """
  Send a user message authenticated by a one-use Security delivery receipt.

  Accepts only an exact `%UserMessage{}` (native key set) and opaque
  `%DeliveryReceipt{}`. Session derives the chat resource exclusively from
  `state.agent_id`, consumes the receipt, binds the Security-owned principal to
  `UserMessage.sender_id`, resolves that principal's canonical private user
  engagement through `Arbor.Comms`, and allocates a fresh process-local
  `TurnAuthority` with `disclosure_capability_id: nil`. Receipt, identity, and
  engagement failures collapse to `{:error, :unauthenticated}`. Does not accept
  caller-supplied authority, engagement, turn ids, targets, routes, capability
  ids, or taint.

  On success returns `{:ok, %Arbor.Contracts.Pipeline.Response{}}` (same shape
  as ordinary `send_message/2`).

  The three-argument form uses `Arbor.Orchestrator.Config.turn_timeout_ms/0`.
  Callers that already validated a shorter bound use the four-argument form
  with an explicit positive timeout. Both issue the same synchronous
  `GenServer.call` from the invoking process (no helper Task/process).
  A call timeout is ordinary `GenServer.call` exit behavior — it does not
  by itself cancel or settle a queued/active turn.
  """
  @spec send_authenticated_message(
          GenServer.server(),
          UserMessage.t(),
          DeliveryReceipt.t()
        ) ::
          {:ok, PipelineResponse.t()}
          | {:error, :unauthenticated | :legacy_mode | :cancelled | term()}
  def send_authenticated_message(session, %UserMessage{} = message, %DeliveryReceipt{} = receipt) do
    send_authenticated_message(
      session,
      message,
      receipt,
      Arbor.Orchestrator.Config.turn_timeout_ms()
    )
  end

  def send_authenticated_message(_session, _message, _receipt), do: {:error, :unauthenticated}

  @doc """
  Authenticated send with an explicit positive `GenServer.call` timeout (ms).

  Same exact `%UserMessage{}` / `%DeliveryReceipt{}` contract and message
  tuple as `send_authenticated_message/3`. On success returns
  `{:ok, %Arbor.Contracts.Pipeline.Response{}}`. Invalid arguments (including
  zero/non-integer timeout) return
  `{:error, :invalid_authenticated_message_request}` before any message is
  sent; the unsubmitted receipt remains caller-owned.
  """
  @spec send_authenticated_message(
          GenServer.server(),
          UserMessage.t(),
          DeliveryReceipt.t(),
          pos_integer()
        ) ::
          {:ok, PipelineResponse.t()}
          | {:error,
             :unauthenticated
             | :legacy_mode
             | :cancelled
             | :invalid_authenticated_message_request
             | term()}
  def send_authenticated_message(
        session,
        %UserMessage{} = message,
        %DeliveryReceipt{} = receipt,
        timeout_ms
      )
      when is_integer(timeout_ms) and timeout_ms > 0 do
    GenServer.call(
      session,
      {:send_authenticated_message, message, receipt},
      timeout_ms
    )
  end

  def send_authenticated_message(_session, _message, _receipt, _timeout_ms),
    do: {:error, :invalid_authenticated_message_request}

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
  Cancel a specific async orchestration task on this session.

  Unlike `cancel_turn/1` (user-initiated, unscoped — always kills the active
  turn), this is **task-scoped** and race-safe:

    * If the active turn carries `task_id` in `UserMessage.transport_metadata`
      (also exposed as `session.task_id` in the engine context), cancel it.
    * If an accepted steering caller owns `task_id`, cancel the whole active
      turn because that instruction may already have influenced effects.
    * If an unrelated active/interactive turn is running, leave it alone.
    * Matching queued turns are removed and their callers receive
      `{:error, :cancelled}`.
    * A bounded tombstone rejects a later `send_message` with the same
      `task_id` so a cancel that races ahead of Session still cannot run.

  Always records the tombstone (when `task_id` is non-empty) so late arrivals
  are deterministic. Returns `:ok`, or `{:error, :invalid_task_id}`.
  """
  @spec cancel_task(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def cancel_task(session, task_id) when is_binary(task_id) do
    GenServer.call(session, {:cancel_task, task_id})
  end

  def cancel_task(_session, _task_id), do: {:error, :invalid_task_id}

  @doc """
  Take a bounded batch of queued messages for one active-turn boundary.

  The process-local turn token and source-owned engagement must exactly match
  the active turn. A boundary is an exact `{attempt_ref, positive_sequence}`
  tuple and may be observed only once. Invalid, stale, duplicate, or over-limit
  reads fail closed as `:none`. Session call exits/timeouts return the closed
  process-local `{:error, :steering_delivery_ambiguous}` result instead of
  claiming that no message was present.
  """
  @spec take_steering(GenServer.server(), reference(), String.t() | nil, term()) ::
          :none
          | {:ok, [SteeringMessage.t()]}
          | {:error, :steering_delivery_ambiguous}
  def take_steering(session, turn_token, engagement_id, boundary) do
    GenServer.call(
      session,
      {:take_steering, turn_token, engagement_id, boundary},
      5_000
    )
  catch
    :exit, _ -> @steering_delivery_ambiguous
  end

  @doc """
  Return a public projection of the current session state.

  Active and queued `TurnAuthority` material is stripped (set to `nil`), and
  identity-bearing fields on their associated `UserMessage` values are cleared,
  so callers cannot read turn/principal/capability ids. Internal GenServer state
  is unchanged; nil-authority compatibility messages are preserved.
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
  Pin the session's exposed tool list — sets `config["tools"]`, which
  `ToolDisclosure.resolve_tools` treats as AUTHORITATIVE (verbatim, bypassing
  the capability→tool reverse-map and the profile-derived tool set). Reflected on
  the next turn.

  Used by the eval harness to give a throwaway agent an EXACT tool set (e.g.
  `["web_search_eval", "web_browse"]`) so its behavior isn't confounded by a
  flooded/ambiguous tool list. Not a normal operator surface.
  """
  @spec set_tools(GenServer.server(), [String.t()]) :: {:ok, [String.t()]} | {:error, term()}
  def set_tools(session, tools) when is_list(tools) do
    GenServer.call(session, {:set_tools, tools})
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
    legacy_signer = Keyword.get(opts, :signer)
    tenant_context = Keyword.get(opts, :tenant_context)

    # Initialize compactor if configured (runtime bridge — module lives in arbor_agent).
    # Retain the trusted construction spec so every engagement starts with the
    # same configuration without deriving a new instance from another user's state.
    requested_compactor_spec = Keyword.get(opts, :compactor)
    compactor = Builders.init_compactor(requested_compactor_spec)
    compactor_spec = if is_nil(compactor), do: nil, else: requested_compactor_spec

    with {:ok, signing_authority} <- claim_signing_authority(opts),
         :ok <- reject_mixed_credentials(signing_authority, legacy_signer),
         {:ok, turn_graph} <- Builders.parse_dot_file(turn_dot_path) do
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
        compactor_spec: compactor_spec,
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
        signer: if(signing_authority, do: nil, else: legacy_signer),
        signing_authority: signing_authority,
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
      {:error, reason} -> {:stop, {:session_init_failed, reason}}
    end
  end

  @impl true
  def handle_call({:send_message, _message}, _from, %{execution_mode: :legacy} = state) do
    {:reply, {:error, :legacy_mode}, state}
  end

  def handle_call(
        {:send_authenticated_message, _message, receipt},
        _from,
        %{execution_mode: :legacy} = state
      ) do
    best_effort_discard_receipt(receipt)
    {:reply, {:error, :legacy_mode}, state}
  end

  # A send arriving mid-turn is QUEUED, not rejected. Single-mind serialization:
  # the one mind finishes its current turn, then drains the queue in FIFO order
  # (across all engagements). The caller's GenServer.call blocks until its turn
  # actually runs and replies (via turn_from). Coerce here so the queued entry is
  # already a typed envelope (carrying its engagement_id).
  # Reject immediately when the message's task_id was already cancelled (tombstone).
  # Direct/compatibility calls always carry nil turn authority.
  def handle_call({:send_message, message}, from, %{turn_in_flight: true} = state) do
    user_message = coerce_user_message(message)

    if task_cancelled?(state, user_message_task_id(user_message)) do
      {:reply, {:error, :cancelled}, state}
    else
      case enqueue_turn(state, {user_message, nil, from}) do
        {:ok, queued_state} -> {:noreply, queued_state}
        {:error, :turn_queue_full} -> {:reply, {:error, :turn_queue_full}, state}
      end
    end
  end

  def handle_call({:send_authenticated_message, message, receipt}, from, state) do
    handle_authenticated_message(message, receipt, from, state)
  rescue
    _ ->
      best_effort_discard_receipt(receipt)
      {:reply, {:error, :unauthenticated}, state}
  catch
    :throw, _ ->
      best_effort_discard_receipt(receipt)
      {:reply, {:error, :unauthenticated}, state}

    :exit, _ ->
      best_effort_discard_receipt(receipt)
      {:reply, {:error, :unauthenticated}, state}
  end

  # STEERING: one process-local callback is bound to the exact live turn and
  # engagement. A valid boundary is marked before scanning, including when no
  # message is eligible. Invalid/stale/duplicate reads do not touch the queue.
  def handle_call(
        {:take_steering, turn_token, engagement_id, boundary},
        _from,
        state
      ) do
    case admit_steering_boundary(state, turn_token, engagement_id, boundary) do
      {:ok, boundary_state} ->
        {messages, new_state} = take_steering_batch(boundary_state, engagement_id)

        if messages == [] do
          {:reply, :none, new_state}
        else
          Logger.info(
            "[Session] steering: folding #{length(messages)} mid-turn message(s) into the active turn for #{state.agent_id}"
          )

          {:reply, {:ok, messages}, new_state}
        end

      :error ->
        {:reply, :none, state}
    end
  end

  # Removed unbound and malformed callback shapes fail closed.
  def handle_call(:take_steering, _from, state), do: {:reply, :none, state}

  def handle_call({:send_message, message}, from, state) do
    # Slash commands are parsed at each adapter's intake (CommandIntake), not
    # here; by the time a message reaches Session it has been classified as a
    # regular prompt. Session stays a pure runtime container.
    user_message = coerce_user_message(message)

    if task_cancelled?(state, user_message_task_id(user_message)) do
      {:reply, {:error, :cancelled}, state}
    else
      start_turn(user_message, nil, from, state)
    end
  end

  def handle_call(:get_state, _from, state) do
    # Public status projection: never leak TurnAuthority fields/ids to callers.
    # Internal process state (including turn_authority / queue authorities) is unchanged.
    {:reply, public_state_projection(state), state}
  end

  # User cancellation: preserve whatever streamed as a :cancelled partial, kill the
  # turn task, unblock the original caller and the session. The demonitor [:flush]
  # before the kill means the task's :DOWN is dropped and can't re-finalize.
  # Unscoped — used by explicit user cancel surfaces (e.g. chat socket).
  def handle_call(:cancel_turn, _from, %{turn_in_flight: true} = state) do
    {:reply, :ok, do_cancel_active_turn(state, :user_cancelled)}
  end

  def handle_call(:cancel_turn, _from, state) do
    {:reply, {:error, :no_turn_in_flight}, state}
  end

  # Task-scoped cancel for async orchestration (TaskStore → SessionManager).
  def handle_call({:cancel_task, task_id}, _from, state)
      when is_binary(task_id) and task_id != "" do
    state =
      state
      |> mark_task_cancelled(task_id)
      |> purge_queued_task(task_id)

    state =
      if state.turn_in_flight and
           (active_turn_task_id(state) == task_id or
              accepted_steering_task_id?(state, task_id)) do
        do_cancel_active_turn(state, :task_cancelled)
      else
        state
      end

    {:reply, :ok, state}
  end

  def handle_call({:cancel_task, _task_id}, _from, state) do
    {:reply, {:error, :invalid_task_id}, state}
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

  def handle_call({:set_tools, tools}, _from, state) do
    new_config = Map.put(state.config || %{}, "tools", tools)

    Logger.info(
      "[Session #{state.agent_id}] tools pinned → #{inspect(tools)} (effective on next turn)"
    )

    {:reply, {:ok, tools}, %{state | config: new_config}}
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

  defp do_send_message_async(
         %UserMessage{} = user_message,
         turn_authority,
         from,
         state,
         prepared
       ) do
    state = transition_phase(state, :idle, :input_received, :processing)
    # TurnAuthority / receipts / disclosure ids never enter builders, engine
    # values, or preprocessor maps. Only process-local function opts + taint.
    engine_opts = prepared.engine_opts
    fence = prepared.fence
    turn_token = prepared.turn_token

    session_pid = self()
    turn_graph = state.turn_graph

    # Load-bearing: deactivate fence BEFORE send so Session cannot observe an
    # active fence while handling the terminal result. The `after` block is an
    # idempotent crash/exit backstop only. Session remains sole revocation owner.
    task_fn = fn ->
      try do
        result =
          try do
            Engine.run(turn_graph, engine_opts)
          rescue
            e -> {:error, {:engine_crash, Exception.message(e)}}
          end

        TurnEgress.deactivate_fence(fence)
        send(session_pid, {:turn_result, turn_token, user_message, result})
      after
        TurnEgress.deactivate_fence(fence)
      end
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
        turn_authority: turn_authority,
        turn_egress_fence: fence,
        turn_token: turn_token,
        steer_froms: [],
        steer_caller_ownership: [],
        steering_boundaries: MapSet.new(),
        steering_message_count: 0,
        steering_byte_count: 0,
        streaming_buffer: %{content: "", started_at: DateTime.utc_now(), first_token_at: nil},
        turn_timeout_ref: timeout_ref
    }

    {:noreply, new_state}
  rescue
    _ ->
      cleanup_prepared_partial(prepared)
      {:error, :turn_preparation_refused}
  catch
    _, _ ->
      cleanup_prepared_partial(prepared)
      {:error, :turn_preparation_refused}
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

  defp maybe_put_user_message_task_id(values, user_message) do
    case user_message_task_id(user_message) do
      task_id when is_binary(task_id) and task_id != "" ->
        Map.put(values, "session.task_id", task_id)

      _ ->
        values
    end
  end

  defp user_message_task_id(%Arbor.Contracts.Session.UserMessage{transport_metadata: metadata}) do
    case metadata_value(metadata, :task_id) do
      task_id when is_binary(task_id) and task_id != "" -> task_id
      _ -> nil
    end
  end

  defp user_message_task_id(_), do: nil

  defp active_turn_task_id(%{turn_user_message: user_message}),
    do: user_message_task_id(user_message)

  defp active_turn_task_id(_), do: nil

  defp metadata_value(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, to_string(key)))

  defp metadata_value(_map, _key), do: nil

  # Queue admission is shared by compatibility and authenticated mid-turn
  # ingress. The bounded length walk inspects at most limit + 1 cells and fails
  # closed for malformed/improper queues.
  defp enqueue_turn(state, entry) do
    case bounded_list_length(state.turn_queue, @max_turn_queue_entries) do
      {:ok, count} when count < @max_turn_queue_entries ->
        {:ok, %{state | turn_queue: state.turn_queue ++ [entry]}}

      _ ->
        {:error, :turn_queue_full}
    end
  end

  defp bounded_list_length(list, limit), do: bounded_list_length(list, limit, 0)

  defp bounded_list_length([], _limit, count), do: {:ok, count}

  defp bounded_list_length([_entry | rest], limit, count) when count < limit,
    do: bounded_list_length(rest, limit, count + 1)

  defp bounded_list_length(_malformed_or_over_limit, _limit, _count), do: :error

  # ── Task-scoped cancellation helpers ─────────────────────────────────

  defp task_cancelled?(_state, nil), do: false
  defp task_cancelled?(_state, ""), do: false

  defp task_cancelled?(state, task_id) when is_binary(task_id) do
    Map.has_key?(state.cancelled_task_ids || %{}, task_id)
  end

  defp accepted_steering_task_id?(state, task_id)
       when is_binary(task_id) and task_id != "" do
    Enum.any?(state.steer_caller_ownership || [], fn
      %{task_id: ^task_id} -> true
      _ -> false
    end)
  end

  defp accepted_steering_task_id?(_state, _task_id), do: false

  defp mark_task_cancelled(state, task_id) when is_binary(task_id) and task_id != "" do
    # Newest-first FIFO; drop oldest beyond the cap so cancellation state stays bounded.
    order =
      [task_id | Enum.reject(state.cancelled_task_id_order || [], &(&1 == task_id))]
      |> Enum.take(@max_cancelled_task_ids)

    cancelled = Map.new(order, &{&1, true})
    %{state | cancelled_task_ids: cancelled, cancelled_task_id_order: order}
  end

  defp mark_task_cancelled(state, _task_id), do: state

  defp purge_queued_task(state, task_id) when is_binary(task_id) do
    {kept, removed} =
      Enum.split_with(state.turn_queue || [], fn {user_message, _authority, _from} ->
        user_message_task_id(user_message) != task_id
      end)

    Enum.each(removed, fn {_msg, _authority, from} ->
      safe_reply(from, {:error, :cancelled})
    end)

    %{state | turn_queue: kept}
  end

  defp do_cancel_active_turn(state, reason, reply \\ {:error, :cancelled}) do
    new_state = transition_phase(state, :processing, :complete, :idle)
    # Fence → kill (await DOWN) → revoke, then finalize/reply/reset so the
    # task cannot authorize another wave during partial persistence.
    state = cleanup_turn_terminal(state, kill_task?: true)
    lifecycle_probe(:before_finalize, %{reason: reason})
    finalize_partial(state, :cancelled, reason)
    lifecycle_probe(:before_reply, %{reply: reply})
    reply_turn(state, reply)
    lifecycle_probe(:after_reply, %{reply: reply})

    # Cancelling the active turn frees the mind — let queued turns proceed.
    send(self(), :drain_queue)
    reset_turn(new_state)
  end

  # Drain the next queued turn once the current one has finished. Triggered as a
  # self-message from reset_and_drain/1 (so turn_in_flight is already cleared).
  # Idempotent: a no-op if a turn is somehow still in flight or the queue is empty.
  # Skip tombstoned task turns (cancel raced ahead of drain).
  @impl true
  def handle_info(:drain_queue, %{turn_in_flight: true} = state), do: {:noreply, state}
  def handle_info(:drain_queue, %{turn_queue: []} = state), do: {:noreply, state}

  def handle_info(
        :drain_queue,
        %{turn_queue: [{user_message, turn_authority, from} | rest]} = state
      ) do
    state = %{state | turn_queue: rest}

    cond do
      task_cancelled?(state, user_message_task_id(user_message)) ->
        safe_reply(from, {:error, :cancelled})
        send(self(), :drain_queue)
        {:noreply, state}

      not caller_alive?(from) ->
        # Dead queued caller: never prepare/issue disclosure.
        send(self(), :drain_queue)
        {:noreply, state}

      true ->
        start_turn(user_message, turn_authority, from, state)
    end
  end

  def handle_info(
        {:turn_result, token, %Arbor.Contracts.Session.UserMessage{} = user_message,
         {:ok, result}},
        state
      ) do
    if matching_turn_token?(state, token) do
      # Engine.run/2 returning {:ok, run_result} only proves an envelope was
      # produced. Admit only :success / :partial_success before apply/checkpoint/
      # success signals; all other final outcomes fail closed with a bounded error.
      case admit_engine_run_result(result) do
        :ok ->
          complete_turn_success(user_message, result, state)

        {:error, :turn_failed} ->
          complete_turn_error(state, :turn_failed)
      end
    else
      # Stale/detached/forged result — ignore so a background nil-authority task
      # cannot finalize, reply to, reset, or revoke a newer authenticated turn.
      {:noreply, state}
    end
  end

  def handle_info({:turn_result, token, _user_message, {:error, reason}}, state) do
    if matching_turn_token?(state, token) do
      # Elixir-level Engine errors (and rescued crashes) continue on the ordinary
      # failure path — reason may still be Engine-shaped for those cases.
      complete_turn_error(state, reason)
    else
      {:noreply, state}
    end
  end

  # Legacy results carry no process-local authority token and always fail closed.
  def handle_info({:turn_result, _user_message, _result}, state), do: {:noreply, state}

  # One DOWN classifier covers normal and abnormal exits. Caller ownership is
  # determined by exact monitor references, so a normal caller exit cannot be
  # mistaken for a successfully completed turn task or silently ignored.
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    cond do
      ref == state.turn_task_ref and reason == :normal ->
        {:noreply, %{state | turn_task_ref: nil}}

      ref == state.turn_task_ref ->
        # Turn task died non-normally (exit/kill/linked death the task's rescue
        # didn't catch) — fence/revoke first (task already dead), then partial.
        new_state = transition_phase(state, :processing, :complete, :idle)
        state = cleanup_turn_terminal(state, kill_task?: false)
        finalize_partial(state, :interrupted, {:task_down, reason})
        reply_turn(state, {:error, {:turn_task_crashed, reason}})

        reset_and_drain(new_state)

      not is_nil(state.turn_caller_ref) and ref == state.turn_caller_ref ->
        handle_caller_down(state)

      accepted_steering_monitor_ref?(state, ref) ->
        handle_steering_caller_down(state)

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
    # Fence → kill (await DOWN) → revoke before finalize/reply so a late wave
    # cannot authorize during partial persistence.
    state = cleanup_turn_terminal(state, kill_task?: true)
    lifecycle_probe(:before_finalize, %{reason: :timeout})
    finalize_partial(state, :interrupted, :timeout)
    lifecycle_probe(:before_reply, %{reply: :turn_timeout})
    reply_turn(state, {:error, :turn_timeout})
    lifecycle_probe(:after_reply, %{reply: :turn_timeout})

    reset_and_drain(new_state)
  end

  # Stale timeout (turn already finished / a different turn now) — ignore.
  def handle_info({:turn_timeout, _ref}, state), do: {:noreply, state}

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Orderly shutdown: fence/kill/revoke any active authority-bearing turn.
    if state.turn_in_flight do
      _ = cleanup_turn_terminal(state, kill_task?: true)
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # ── Private helpers ──────────────────────────────────────────────────

  # Deterministic terminal order: deactivate fence → kill/await task DOWN →
  # revoke by exact capability id. Process.exit(:kill) is asynchronous; we
  # boundedly await the monitor DOWN before revoke so kill-before-revoke is
  # observationally true. Each step is independently catch-safe so a fault
  # after fence deactivation cannot skip revocation (cap leak).
  @task_kill_await_ms 5_000

  defp matching_turn_token?(%{turn_in_flight: true, turn_token: token}, token)
       when is_reference(token),
       do: true

  defp matching_turn_token?(_state, _token), do: false

  defp cleanup_turn_terminal(state, opts) when is_list(opts) do
    kill_task? = Keyword.get(opts, :kill_task?, false)
    task_pid = state.turn_task_pid

    TurnEgress.deactivate_fence(state.turn_egress_fence)
    lifecycle_probe(:fence_deactivated, %{task_alive?: task_alive?(task_pid)})

    try do
      if kill_task? do
        kill_task_and_await_down(state)

        lifecycle_probe(:task_kill_awaited, %{
          task_alive?: task_alive?(task_pid),
          task_pid: task_pid
        })
      else
        if state.turn_task_ref, do: Process.demonitor(state.turn_task_ref, [:flush])
      end

      if state.turn_caller_ref, do: Process.demonitor(state.turn_caller_ref, [:flush])
      demonitor_steering_callers(state)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    # Revoke only after kill has been observed (or task was already dead).
    lifecycle_probe(:before_revoke, %{task_alive?: task_alive?(task_pid)})

    TurnEgress.safe_revoke_disclosure(
      TurnEgress.disclosure_id_from_authority(state.turn_authority)
    )

    lifecycle_probe(:revoked, %{task_alive?: task_alive?(task_pid)})

    state
  end

  defp task_alive?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp task_alive?(_), do: false

  # Test/observability probe for terminal ordering. No-op unless a test pid is set.
  defp lifecycle_probe(event, meta) when is_atom(event) and is_map(meta) do
    case Application.get_env(:arbor_orchestrator, :_session_lifecycle_probe) do
      pid when is_pid(pid) ->
        send(pid, {:lifecycle_probe, event, Map.put(meta, :mono, System.monotonic_time())})

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # Kill the turn task and wait for its monitor DOWN before returning.
  # Prefer the existing turn_task_ref; if absent, install a fresh monitor.
  defp kill_task_and_await_down(state) do
    pid = state.turn_task_pid
    ref = state.turn_task_ref

    cond do
      not is_pid(pid) ->
        if is_reference(ref), do: Process.demonitor(ref, [:flush])
        :ok

      not Process.alive?(pid) ->
        if is_reference(ref), do: Process.demonitor(ref, [:flush])
        :ok

      is_reference(ref) ->
        # Do not flush before kill — we need this DOWN for ordering.
        Process.exit(pid, :kill)
        await_task_down(ref)

      true ->
        mon = Process.monitor(pid)
        Process.exit(pid, :kill)
        await_task_down(mon)
    end
  end

  defp await_task_down(ref) when is_reference(ref) do
    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> :ok
    after
      @task_kill_await_ms ->
        Process.demonitor(ref, [:flush])
        :ok
    end
  end

  defp await_task_down(_), do: :ok

  defp demonitor_steering_callers(state) do
    Enum.each(state.steer_caller_ownership || [], fn
      %{monitor_ref: ref} when is_reference(ref) -> Process.demonitor(ref, [:flush])
      _ -> :ok
    end)

    :ok
  end

  defp accepted_steering_monitor_ref?(state, ref) when is_reference(ref) do
    Enum.any?(state.steer_caller_ownership || [], fn
      %{monitor_ref: ^ref} -> true
      _ -> false
    end)
  end

  defp accepted_steering_monitor_ref?(_state, _ref), do: false

  defp accepted_steering?(state) do
    (is_integer(state.steering_message_count) and state.steering_message_count > 0) or
      state.steer_froms not in [nil, []] or state.steer_caller_ownership not in [nil, []]
  end

  defp handle_steering_caller_down(state) do
    Logger.info(
      "[Session] accepted steering caller exited for #{state.agent_id}; cancelling the influenced turn"
    )

    {:noreply,
     do_cancel_active_turn(
       state,
       :steering_caller_down,
       @steering_delivery_ambiguous
     )}
  end

  # Nil-authority: deactivate fence (task-owned waves cannot authorize), detach
  # monitors, and leave the task running only before any steering was accepted.
  # Authority-bearing or steering-influenced turns are fenced/killed before reset.
  defp handle_caller_down(state) do
    Logger.info(
      "[Session] send_message caller died (timeout or crash) for #{state.agent_id}; clearing in-flight state to unblock future turns"
    )

    new_state = transition_phase(state, :processing, :complete, :idle)

    cond do
      accepted_steering?(state) ->
        {:noreply,
         do_cancel_active_turn(
           state,
           :primary_caller_down_after_steering,
           @steering_delivery_ambiguous
         )}

      match?(%TurnAuthority{}, state.turn_authority) ->
        _ = cleanup_turn_terminal(state, kill_task?: true)
        lifecycle_probe(:after_reply, %{reply: :caller_down_auth})
        reset_and_drain(new_state)

      true ->
        # Task continues; fence deactivation is the load-bearing close for any
        # process-local authorizer the task still holds.
        TurnEgress.deactivate_fence(state.turn_egress_fence)
        lifecycle_probe(:fence_deactivated, %{task_alive?: task_alive?(state.turn_task_pid)})
        if state.turn_task_ref, do: Process.demonitor(state.turn_task_ref, [:flush])
        if state.turn_caller_ref, do: Process.demonitor(state.turn_caller_ref, [:flush])
        lifecycle_probe(:after_reply, %{reply: :caller_down_nil})
        reset_and_drain(new_state)
    end
  end

  @turn_authority_keys [
    :__struct__,
    :turn_id,
    :authenticated_principal_id,
    :disclosure_capability_id
  ]

  defp admit_steering_boundary(state, turn_token, engagement_id, boundary) do
    boundaries = state.steering_boundaries

    cond do
      not matching_turn_token?(state, turn_token) ->
        :error

      not active_steering_engagement?(state, engagement_id) ->
        :error

      not valid_steering_boundary?(boundary) ->
        :error

      not match?(%MapSet{}, boundaries) ->
        :error

      not match?({:ok, _}, bounded_list_length(state.turn_queue, @max_turn_queue_entries)) ->
        :error

      not valid_steering_counters?(state) ->
        :error

      not valid_steering_ownership?(state) ->
        :error

      MapSet.member?(boundaries, boundary) ->
        :error

      MapSet.size(boundaries) >= SteeringMessage.max_boundaries_per_turn() ->
        :error

      true ->
        {:ok, %{state | steering_boundaries: MapSet.put(boundaries, boundary)}}
    end
  end

  defp active_steering_engagement?(
         %{
           turn_in_flight: true,
           current_engagement_id: engagement_id,
           turn_user_message: %UserMessage{engagement_id: engagement_id}
         },
         engagement_id
       ),
       do: true

  defp active_steering_engagement?(_state, _engagement_id), do: false

  defp valid_steering_boundary?({attempt_ref, sequence}) do
    is_reference(attempt_ref) and is_integer(sequence) and sequence > 0
  end

  defp valid_steering_boundary?(_boundary), do: false

  defp valid_steering_counters?(state) do
    is_integer(state.steering_message_count) and state.steering_message_count >= 0 and
      state.steering_message_count <= SteeringMessage.max_messages_per_turn() and
      is_integer(state.steering_byte_count) and state.steering_byte_count >= 0 and
      state.steering_byte_count <= SteeringMessage.max_bytes_per_turn()
  end

  defp valid_steering_ownership?(state) do
    maximum = SteeringMessage.max_messages_per_turn()

    with {:ok, from_count} <- bounded_list_length(state.steer_froms, maximum),
         {:ok, owner_count} <- bounded_list_length(state.steer_caller_ownership, maximum),
         true <- from_count == owner_count,
         true <- owner_count == state.steering_message_count,
         true <- Enum.all?(state.steer_froms, &valid_caller_from?/1),
         true <- Enum.all?(state.steer_caller_ownership, &valid_steering_owner?/1),
         true <- Enum.map(state.steer_caller_ownership, & &1.from) == state.steer_froms do
      true
    else
      _ -> false
    end
  end

  defp valid_caller_from?({pid, _tag}) when is_pid(pid), do: true
  defp valid_caller_from?(_from), do: false

  defp valid_steering_owner?(%{
         from: from,
         monitor_ref: monitor_ref,
         task_id: task_id
       }) do
    valid_caller_from?(from) and is_reference(monitor_ref) and
      (is_nil(task_id) or (is_binary(task_id) and task_id != ""))
  end

  defp valid_steering_owner?(_owner), do: false

  # Scan the whole queue once. Cross-engagement, authority-ineligible, malformed,
  # and over-limit entries retain their original relative order. After an eligible
  # active-engagement entry hits capacity, later eligible entries from that
  # engagement remain queued behind it. Dead and cancelled entries are still
  # removed wherever they occur.
  defp take_steering_batch(state, engagement_id) do
    acc = %{
      queue_rev: [],
      messages_rev: [],
      froms_rev: [],
      ownership_sources_rev: [],
      boundary_message_count: 0,
      boundary_byte_count: 0,
      active_engagement_capacity_blocked?: false
    }

    acc =
      scan_steering_queue(
        state.turn_queue || [],
        state,
        engagement_id,
        acc
      )

    messages = Enum.reverse(acc.messages_rev)
    accepted_froms = Enum.reverse(acc.froms_rev)

    accepted_ownership =
      acc.ownership_sources_rev
      |> Enum.reverse()
      |> Enum.map(fn {from, task_id} -> monitor_steering_caller(from, task_id) end)

    new_state = %{
      state
      | turn_queue: Enum.reverse(acc.queue_rev),
        steer_froms: (state.steer_froms || []) ++ accepted_froms,
        steer_caller_ownership: (state.steer_caller_ownership || []) ++ accepted_ownership,
        steering_message_count: state.steering_message_count + acc.boundary_message_count,
        steering_byte_count: state.steering_byte_count + acc.boundary_byte_count
    }

    {messages, new_state}
  end

  defp scan_steering_queue([], _state, _engagement_id, acc), do: acc

  defp scan_steering_queue(
         [{user_message, queued_authority, caller_from} = entry | rest],
         state,
         engagement_id,
         acc
       ) do
    cond do
      task_cancelled?(state, user_message_task_id(user_message)) ->
        safe_reply(caller_from, {:error, :cancelled})
        scan_steering_queue(rest, state, engagement_id, acc)

      not caller_alive?(caller_from) ->
        scan_steering_queue(rest, state, engagement_id, acc)

      steering_entry_eligible?(
        user_message,
        queued_authority,
        state,
        engagement_id
      ) ->
        if acc.active_engagement_capacity_blocked? do
          scan_steering_queue(rest, state, engagement_id, %{
            acc
            | queue_rev: [entry | acc.queue_rev]
          })
        else
          case maybe_build_steering_message(user_message, state, acc) do
            {:ok, message, byte_count} ->
              next_acc = %{
                acc
                | messages_rev: [message | acc.messages_rev],
                  froms_rev: [caller_from | acc.froms_rev],
                  ownership_sources_rev: [
                    {caller_from, user_message_task_id(user_message)}
                    | acc.ownership_sources_rev
                  ],
                  boundary_message_count: acc.boundary_message_count + 1,
                  boundary_byte_count: acc.boundary_byte_count + byte_count
              }

              scan_steering_queue(rest, state, engagement_id, next_acc)

            :capacity_exhausted ->
              scan_steering_queue(rest, state, engagement_id, %{
                acc
                | queue_rev: [entry | acc.queue_rev],
                  active_engagement_capacity_blocked?: true
              })

            :error ->
              scan_steering_queue(rest, state, engagement_id, %{
                acc
                | queue_rev: [entry | acc.queue_rev]
              })
          end
        end

      true ->
        scan_steering_queue(rest, state, engagement_id, %{
          acc
          | queue_rev: [entry | acc.queue_rev]
        })
    end
  end

  defp scan_steering_queue([entry | rest], state, engagement_id, acc) do
    scan_steering_queue(rest, state, engagement_id, %{
      acc
      | queue_rev: [entry | acc.queue_rev]
    })
  end

  defp monitor_steering_caller({pid, _tag} = from, task_id) when is_pid(pid) do
    %{from: from, monitor_ref: Process.monitor(pid), task_id: task_id}
  end

  defp steering_entry_eligible?(
         %UserMessage{engagement_id: engagement_id} = queued_message,
         queued_authority,
         state,
         engagement_id
       ) do
    steering_authority_match?(
      state.turn_authority,
      queued_authority,
      state.turn_user_message,
      queued_message
    )
  end

  defp steering_entry_eligible?(_message, _authority, _state, _engagement_id), do: false

  defp steering_authority_match?(nil, nil, _active_message, _queued_message), do: true

  defp steering_authority_match?(
         active_authority,
         queued_authority,
         active_message,
         queued_message
       ) do
    with {:ok, active} <- canonical_turn_authority(active_authority),
         {:ok, queued} <- canonical_turn_authority(queued_authority),
         true <- active.authenticated_principal_id == queued.authenticated_principal_id,
         true <- authenticated_message_owner?(active_message, active),
         true <- authenticated_message_owner?(queued_message, queued) do
      true
    else
      _ -> false
    end
  end

  defp canonical_turn_authority(%TurnAuthority{} = authority) do
    if map_size(authority) == length(@turn_authority_keys) and
         Enum.sort(Map.keys(authority)) == Enum.sort(@turn_authority_keys) do
      attrs = %{
        turn_id: authority.turn_id,
        authenticated_principal_id: authority.authenticated_principal_id,
        disclosure_capability_id: authority.disclosure_capability_id
      }

      case TurnAuthority.new(attrs) do
        {:ok, ^authority} -> {:ok, authority}
        _ -> :error
      end
    else
      :error
    end
  end

  defp canonical_turn_authority(_authority), do: :error

  defp authenticated_message_owner?(
         %UserMessage{sender_id: principal_id},
         %TurnAuthority{authenticated_principal_id: principal_id}
       ),
       do: true

  defp authenticated_message_owner?(_message, _authority), do: false

  defp maybe_build_steering_message(%UserMessage{content: content} = user_message, state, acc)
       when is_binary(content) do
    byte_count = byte_size(content)

    if steering_capacity?(state, acc, byte_count) do
      taint = %Taint{
        level: :untrusted,
        sensitivity: :internal,
        sanitizations: 0,
        confidence: :unverified,
        source: steering_transport_label(user_message),
        chain: ["session_steering"]
      }

      case SteeringMessage.new(%{
             message_id: Identifiers.generate_id("steer_"),
             engagement_id: user_message.engagement_id,
             content: content,
             taint: taint
           }) do
        {:ok, message} -> {:ok, message, byte_count}
        {:error, _} -> :error
      end
    else
      :capacity_exhausted
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp maybe_build_steering_message(_user_message, _state, _acc), do: :error

  defp steering_capacity?(state, acc, byte_count) do
    acc.boundary_message_count < SteeringMessage.max_messages_per_boundary() and
      acc.boundary_byte_count + byte_count <= SteeringMessage.max_bytes_per_boundary() and
      state.steering_message_count + acc.boundary_message_count <
        SteeringMessage.max_messages_per_turn() and
      state.steering_byte_count + acc.boundary_byte_count + byte_count <=
        SteeringMessage.max_bytes_per_turn()
  end

  defp steering_transport_label(%UserMessage{transport: :dashboard}),
    do: "session_steering_dashboard"

  defp steering_transport_label(%UserMessage{transport: :cli}), do: "session_steering_cli"
  defp steering_transport_label(%UserMessage{transport: :acp}), do: "session_steering_acp"
  defp steering_transport_label(%UserMessage{transport: :signal}), do: "session_steering_signal"

  defp steering_transport_label(%UserMessage{transport: :discord}),
    do: "session_steering_discord"

  defp steering_transport_label(%UserMessage{transport: :slack}), do: "session_steering_slack"
  defp steering_transport_label(%UserMessage{transport: :http}), do: "session_steering_http"
  defp steering_transport_label(%UserMessage{transport: :voice}), do: "session_steering_voice"
  defp steering_transport_label(_message), do: "session_steering_unknown"

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

  defp admit_engine_run_result(%{final_outcome: %{status: status}})
       when status in @admitted_final_statuses,
       do: :ok

  defp admit_engine_run_result(_), do: {:error, :turn_failed}

  defp complete_turn_success(user_message, result, state) do
    completed = Map.get(result.context, "__completed_nodes__", [])

    # Fence/revoke before reply/reset so a late wave cannot authorize.
    state = cleanup_turn_terminal(state, kill_task?: false)

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

    reply_turn(state, reply)

    # Normal completion: apply_turn_result already persisted the complete message,
    # so just clear the turn (incl. buffer + timeout).
    reset_and_drain(new_state)
  end

  defp complete_turn_error(state, reason) do
    Logger.warning("[Session] Turn FAILED for #{state.agent_id}: #{inspect(reason)}")
    new_state = transition_phase(state, :processing, :complete, :idle)

    emit_turn_telemetry(state.turn_started_at, %{agent_id: state.agent_id, status: :error})

    # Fence/revoke before partial persistence so a late wave cannot authorize.
    state = cleanup_turn_terminal(state, kill_task?: false)

    # Preserve whatever streamed before the failure as an :interrupted partial.
    # For rejected Engine envelopes, reason is the closed atom :turn_failed only.
    finalize_partial(state, :interrupted, reason)
    reply_turn(state, {:error, reason})

    reset_and_drain(new_state)
  end

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
  # Reply to the turn's primary caller AND any callers whose mid-turn messages were folded in
  # as steering — they all get the same result for the turn they contributed to.
  defp reply_turn(state, reply) do
    safe_reply(state.turn_from, reply)
    reply_steering_callers(state, reply)
  end

  defp reply_steering_callers(state, reply) do
    Enum.each(state.steer_froms || [], &safe_reply(&1, reply))
  end

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
  # transcript and compactor under its id, then restore the target pair. nil is
  # the real default engagement, so it follows the same switching rules as a
  # named engagement and is a no-op only while already active.
  defp maybe_switch_engagement(%{current_engagement_id: target} = state, target), do: state

  defp maybe_switch_engagement(state, target) do
    stashed = Map.put(state.transcripts, state.current_engagement_id, state.messages)
    stashed_compactors = stash_active_compactor(state)

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

    {target_compactor, stashed_compactors} =
      case Map.pop(stashed_compactors, target) do
        {nil, remaining} ->
          {Builders.init_compactor(state.compactor_spec, target_msgs), remaining}

        {compactor, remaining} ->
          {compactor, remaining}
      end

    # Mirror the active transcript into session_state — ContextBuilder.get_messages/1
    # reads `session_state.messages` in preference to top-level `messages`, so both
    # must move together or the turn would see the previous engagement's history.
    %{
      state
      | messages: target_msgs,
        compactor: target_compactor,
        transcripts: stashed,
        compactors: stashed_compactors,
        current_engagement_id: target
    }
    |> Persistence.sync_checkpoint_to_session_state()
  end

  defp stash_active_compactor(%{compactor: nil} = state), do: state.compactors

  defp stash_active_compactor(state) do
    Map.put(state.compactors, state.current_engagement_id, state.compactor)
  end

  # Authorize, then prepare (freeze route / taint / disclosure / authorizer),
  # then start the turn — shared by direct sends and queue drains.
  # Replies are sent explicitly (GenServer.reply) so this returns {:noreply, _}
  # uniformly, matching do_send_message_async (which replies later from the turn
  # task). On auth failure the caller is told and the session stays idle.
  # `turn_authority` is process-local only and never enters builders/engine.
  defp start_turn(user_message, turn_authority, from, state) do
    state = maybe_switch_engagement(state, user_message.engagement_id)

    if caller_alive?(from) do
      case authorize_orchestrator(state) do
        :ok ->
          # Allocate once before preparation. Builders closes over this exact
          # token, the task result carries it, and Session stores it for matching.
          turn_token = make_ref()

          case prepare_live_turn(user_message, turn_authority, turn_token, state) do
            {:ok, prepared} ->
              case do_send_message_async(
                     user_message,
                     prepared.authority,
                     from,
                     state,
                     prepared
                   ) do
                {:noreply, _} = ok ->
                  ok

                {:error, reason} ->
                  cleanup_prepared_partial(prepared)
                  safe_reply(from, {:error, reason})
                  {:noreply, state}
              end

            {:error, reason} ->
              safe_reply(from, {:error, reason})
              {:noreply, state}
          end

        {:error, reason} ->
          safe_reply(from, {:error, {:unauthorized, reason}})
          {:noreply, state}
      end
    else
      # Dead caller: never prepare/issue; silently drop.
      {:noreply, state}
    end
  end

  defp caller_alive?({pid, _tag}) when is_pid(pid), do: Process.alive?(pid)
  defp caller_alive?(_), do: false

  # VP-05D2A1P5: after orchestrator authorize, before Task start. Freeze one
  # source-owned route, derive final-value taint, issue D2A0 only for
  # authenticated external, install process-local fence + authorizer.
  # Any fault after disclosure issue deactivates the fence and revokes the cap.
  defp prepare_live_turn(user_message, turn_authority, turn_token, state)
       when is_reference(turn_token) do
    pre_values =
      state
      |> Builders.build_turn_values(user_message.content)
      |> maybe_put_user_message_task_id(user_message)

    final_values = maybe_preprocess(pre_values, user_message.content)
    initial_taint = TurnEgress.derive_initial_taint(pre_values, final_values)

    with {:ok, %{route: route, provider_route_input: route_input}} <-
           TurnEgress.resolve_frozen_route(state, state.turn_graph),
         {:ok, frozen_tier} <-
           TurnEgress.admit_frozen_tier(Arbor.AI.egress_tier_for(route.provider)),
         fence = TurnEgress.new_fence(),
         {:ok, authority, cap_id} <-
           TurnEgress.issue_disclosure_if_needed(
             state,
             turn_authority,
             route,
             frozen_tier
           ) do
      try do
        authorizer =
          TurnEgress.build_taint_authorizer(%{
            fence: fence,
            frozen_route: route,
            frozen_tier: frozen_tier,
            agent_id: state.agent_id,
            session_id: state.session_id,
            turn_id: authority && authority.turn_id,
            human_id: authority && authority.authenticated_principal_id,
            disclosure_capability_id: TurnEgress.disclosure_id_from_authority(authority)
          })

        engine_opts =
          state
          |> Builders.build_engine_opts(final_values,
            source: :turn,
            steering_binding: {turn_token, user_message.engagement_id}
          )
          |> Keyword.put(:initial_taint, initial_taint)
          |> Keyword.put(:frozen_egress_route, route)
          |> Keyword.put(:turn_egress_authorizer, authorizer)
          |> maybe_put_provider_route_input(route_input)

        {:ok,
         %{
           authority: authority,
           fence: fence,
           cap_id: cap_id,
           turn_token: turn_token,
           engine_opts: engine_opts,
           values: final_values
         }}
      rescue
        _ ->
          TurnEgress.deactivate_fence(fence)
          TurnEgress.safe_revoke_disclosure(cap_id)
          {:error, :turn_preparation_refused}
      catch
        _, _ ->
          TurnEgress.deactivate_fence(fence)
          TurnEgress.safe_revoke_disclosure(cap_id)
          {:error, :turn_preparation_refused}
      end
    else
      {:error, reason} ->
        # issue_disclosure_if_needed already revokes on bind failure.
        {:error, map_prepare_error(reason)}
    end
  rescue
    _ -> {:error, :turn_preparation_refused}
  catch
    _, _ -> {:error, :turn_preparation_refused}
  end

  defp cleanup_prepared_partial(prepared) when is_map(prepared) do
    TurnEgress.deactivate_fence(Map.get(prepared, :fence))
    TurnEgress.safe_revoke_disclosure(Map.get(prepared, :cap_id))
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp maybe_put_provider_route_input(opts, nil), do: opts

  defp maybe_put_provider_route_input(opts, input) when is_map(input) do
    Keyword.put(opts, :provider_route_input, input)
  end

  defp map_prepare_error(reason)
       when reason in [
              :missing_configured_route,
              :ambiguous_compute_route,
              :ambiguous_task_class,
              :invalid_task_class,
              :route_assembly_failed,
              :route_freeze_failed,
              :invalid_frozen_tier,
              :disclosure_bind_failed,
              :disclosure_issue_failed
            ],
       do: :turn_preparation_refused

  defp map_prepare_error(reason) when is_atom(reason), do: :turn_preparation_refused
  defp map_prepare_error(_), do: :turn_preparation_refused

  # Receipt-authenticated ingress: consume one-use receipt, bind principal,
  # resolve the principal's source-owned engagement, and allocate TurnAuthority.
  # Receipt never enters state/queue.
  # Caller-supplied engagement_id is a route claim — reject before consume.
  defp handle_authenticated_message(message, receipt, from, state) do
    with {:ok, user_message} <- canonicalize_authenticated_user_message(message),
         :ok <- reject_authenticated_engagement_route(user_message),
         {:ok, valid_receipt} <- DeliveryReceipt.canonicalize(receipt),
         {:ok, authority} <- exchange_receipt_for_authority(valid_receipt, user_message, state),
         {:ok, user_message} <- bind_authenticated_engagement(user_message, authority, state) do
      if task_cancelled?(state, user_message_task_id(user_message)) do
        {:reply, {:error, :cancelled}, state}
      else
        if state.turn_in_flight do
          case enqueue_turn(state, {user_message, authority, from}) do
            {:ok, queued_state} -> {:noreply, queued_state}
            {:error, :turn_queue_full} -> {:reply, {:error, :turn_queue_full}, state}
          end
        else
          start_turn(user_message, authority, from, state)
        end
      end
    else
      {:error, :unauthenticated} ->
        best_effort_discard_receipt(receipt)
        {:reply, {:error, :unauthenticated}, state}

      {:error, _} ->
        best_effort_discard_receipt(receipt)
        {:reply, {:error, :unauthenticated}, state}
    end
  end

  @user_message_native_keys [
    :__struct__,
    :content,
    :engagement_id,
    :sender,
    :sender_id,
    :sent_at,
    :transport,
    :transport_metadata
  ]

  # Exact native key set only — embellished forged struct maps fail closed.
  defp canonicalize_authenticated_user_message(%UserMessage{} = msg) do
    if Enum.sort(Map.keys(msg)) == @user_message_native_keys do
      {:ok,
       %UserMessage{
         content: msg.content,
         sent_at: msg.sent_at,
         sender: msg.sender,
         sender_id: msg.sender_id,
         transport: msg.transport,
         transport_metadata: msg.transport_metadata,
         engagement_id: msg.engagement_id
       }}
    else
      {:error, :unauthenticated}
    end
  end

  defp canonicalize_authenticated_user_message(_), do: {:error, :unauthenticated}

  # Receipt binds agent only — engagement switch is a caller-supplied route.
  # Reject any non-nil engagement_id before receipt exchange / turn routing.
  defp reject_authenticated_engagement_route(%UserMessage{engagement_id: nil}), do: :ok
  defp reject_authenticated_engagement_route(%UserMessage{}), do: {:error, :unauthenticated}

  defp exchange_receipt_for_authority(receipt, user_message, state) do
    resource = "arbor://chat/agent/" <> state.agent_id

    case Arbor.Security.consume_delivery_receipt(receipt, resource, :chat) do
      {:ok, principal} when is_binary(principal) ->
        if principal == user_message.sender_id do
          turn_id = Identifiers.generate_id("turn_")

          case TurnAuthority.new(
                 turn_id: turn_id,
                 authenticated_principal_id: principal,
                 disclosure_capability_id: nil
               ) do
            {:ok, authority} -> {:ok, authority}
            {:error, _} -> {:error, :unauthenticated}
          end
        else
          # Receipt already consumed — destructive; cannot retry with corrected claim.
          {:error, :unauthenticated}
        end

      {:error, _} ->
        {:error, :unauthenticated}

      _ ->
        {:error, :unauthenticated}
    end
  end

  defp bind_authenticated_engagement(user_message, authority, state) do
    principal = authority.authenticated_principal_id

    case Arbor.Comms.resolve_user_engagement(state.agent_id, principal) do
      {:ok,
       %Engagement{
         id: engagement_id,
         agent_id: agent_id,
         owner_tenant: owner_tenant,
         scope: :user,
         visibility: :private
       }}
      when agent_id == state.agent_id and owner_tenant == principal and is_binary(engagement_id) ->
        {:ok, UserMessage.with_engagement(user_message, engagement_id)}

      _other ->
        {:error, :unauthenticated}
    end
  rescue
    _ -> {:error, :unauthenticated}
  catch
    _, _ -> {:error, :unauthenticated}
  end

  defp best_effort_discard_receipt(receipt) do
    _ = Arbor.Security.discard_delivery_receipt(receipt)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # Strip process-local turn authority from any public status surface.
  # Authority-bearing messages also lose identity-bearing adapter fields; nil-
  # authority compatibility messages remain byte-for-byte unchanged.
  defp public_state_projection(state) do
    sanitized_queue =
      Enum.map(state.turn_queue || [], fn
        {msg, authority, from} -> {sanitize_authority_message(msg, authority), nil, from}
        other -> other
      end)

    sanitized_turn_message =
      sanitize_authority_message(state.turn_user_message, state.turn_authority)

    %{
      state
      | turn_from: nil,
        steer_froms: nil,
        steer_caller_ownership: nil,
        turn_task_ref: nil,
        turn_task_pid: nil,
        turn_caller_ref: nil,
        turn_timeout_ref: nil,
        turn_authority: nil,
        turn_egress_fence: nil,
        turn_token: nil,
        steering_boundaries: nil,
        steering_message_count: nil,
        steering_byte_count: nil,
        turn_user_message: sanitized_turn_message,
        turn_queue: sanitized_queue
    }
  end

  defp sanitize_authority_message(message, nil), do: message

  defp sanitize_authority_message(%UserMessage{} = message, %TurnAuthority{}) do
    %{message | sender: nil, sender_id: nil, transport_metadata: %{}}
  end

  defp sanitize_authority_message(message, %TurnAuthority{}), do: message

  # End the current turn and trigger draining of any queued turns. The drain runs
  # as a self-message after this handler returns (turn_in_flight already cleared
  # by reset_turn), so the next queued turn starts cleanly.
  defp reset_and_drain(state) do
    send(self(), :drain_queue)
    {:noreply, reset_turn(state)}
  end

  defp reset_turn(state) do
    cancel_turn_timeout(state)
    demonitor_steering_callers(state)

    %{
      state
      | turn_in_flight: false,
        turn_from: nil,
        steer_froms: [],
        steer_caller_ownership: [],
        turn_task_ref: nil,
        turn_task_pid: nil,
        turn_caller_ref: nil,
        turn_started_at: nil,
        turn_user_message: nil,
        turn_authority: nil,
        turn_egress_fence: nil,
        turn_token: nil,
        steering_boundaries: MapSet.new(),
        steering_message_count: 0,
        steering_byte_count: 0,
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
    Arbor.Orchestrator.Authorization.check_orchestrator_access(
      state.agent_id,
      state.signing_authority || state.signer
    )
  end

  @authority_claim_attempts 3
  @authority_claim_delay_ms 10

  defp claim_signing_authority(opts) do
    case Keyword.fetch(opts, :signing_authority_bootstrap) do
      :error -> {:ok, nil}
      {:ok, bootstrap} -> claim_signing_authority(bootstrap, @authority_claim_attempts)
    end
  end

  defp claim_signing_authority(bootstrap, attempts_left) do
    case Arbor.Security.claim_signing_authority(bootstrap) do
      {:ok, authority} ->
        {:ok, authority}

      {:error, :authority_already_claimed} when attempts_left > 1 ->
        Process.sleep(@authority_claim_delay_ms)
        claim_signing_authority(bootstrap, attempts_left - 1)

      {:error, reason} ->
        {:error, {:signing_authority_claim_failed, reason}}
    end
  end

  defp reject_mixed_credentials(nil, _legacy_signer), do: :ok
  defp reject_mixed_credentials(_authority, nil), do: :ok

  defp reject_mixed_credentials(_authority, _legacy_signer),
    do: {:error, :mixed_signing_credentials}

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
