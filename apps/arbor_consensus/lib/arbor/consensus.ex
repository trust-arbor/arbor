defmodule Arbor.Consensus do
  @moduledoc """
  Pure deliberation engine for multi-perspective consensus on system changes.

  Provides a facade API for submitting proposals, querying decisions,
  and managing the consensus lifecycle. Delegates to the Coordinator
  GenServer.

  ## Architecture

      Proposal  →  Coordinator  →  Council  →  Evaluators (behaviour)
                       │                           │
                  EventStore (ETS)          Evaluator.evaluate/3
                       │                     (rule-based default)
                  Decision rendered          (LLM / deterministic / advisory)
                       │
              on_decision callback  →  host app executes

  ## Pluggable Behaviours

    * `Evaluator` — Required. Evaluates proposals from a perspective.
      Default: `Evaluator.RuleBased`
    * `Authorizer` — Optional. Pre-submit and pre-execution authorization.
    * `Executor` — Optional. Executes approved proposals.
    * `EventSink` — Optional. Persists events to external storage.

  ## Quick Start

      # Submit a proposal
      {:ok, proposal_id} = Arbor.Consensus.submit(%{
        proposer: "agent_1",
        topic: :code_modification,
        description: "Add caching to API calls",
        context: %{new_code: "defmodule Cache do ... end"}
      })

      # Check status
      {:ok, :evaluating} = Arbor.Consensus.get_status(proposal_id)

      # Get decision (once evaluated)
      {:ok, decision} = Arbor.Consensus.get_decision(proposal_id)
  """

  @behaviour Arbor.Contracts.API.Consensus

  alias Arbor.Consensus.{ConsultationLog, Coordinator, EventStore, ReviewerOutcomes}
  alias Arbor.Consensus.Evaluators.Consult

  # Conservative upper bound for the post-deadline persist-retry window.
  # Default grace is 5s; anything larger than 30s is rejected at the facade.
  @max_finalizer_grace_ms 30_000
  # Conservative upper bound for one persist attempt. Must not exceed the
  # default finalizer persist budget so a hung first attempt cannot retain
  # a finalizer task arbitrarily long.
  @max_persist_timeout_ms 5_000

  @doc "Conservative upper bound for `:finalizer_grace_ms` (milliseconds)."
  @spec max_finalizer_grace_ms() :: pos_integer()
  def max_finalizer_grace_ms, do: @max_finalizer_grace_ms

  @doc "Conservative upper bound for `:persist_timeout_ms` (milliseconds)."
  @spec max_persist_timeout_ms() :: pos_integer()
  def max_persist_timeout_ms, do: @max_persist_timeout_ms

  @doc false
  defdelegate sanitize_reviewer_outcomes(outcomes), to: ReviewerOutcomes, as: :sanitize

  # ============================================================================
  # Proposal Lifecycle
  # ============================================================================

  @doc """
  Submit a proposal for consensus evaluation.

  Accepts a map of proposal attributes or a `Proposal.t()` struct.
  Returns the proposal ID on success.

  ## Options

    * `:server` - Coordinator server (default: `Coordinator`)
    * `:evaluator_backend` - Override the evaluator backend for this proposal
  """
  @spec submit(map() | Arbor.Contracts.Consensus.Proposal.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  defdelegate submit(proposal_or_attrs, opts \\ []), to: Coordinator

  @doc """
  Get the current status of a proposal.
  """
  @spec get_status(String.t(), GenServer.server()) ::
          {:ok, atom()} | {:error, :not_found}
  defdelegate get_status(proposal_id, server \\ Coordinator), to: Coordinator

  @doc """
  Get the decision for a proposal.
  """
  @spec get_decision(String.t(), GenServer.server()) ::
          {:ok, Arbor.Contracts.Consensus.CouncilDecision.t()} | {:error, term()}
  defdelegate get_decision(proposal_id, server \\ Coordinator), to: Coordinator

  @doc """
  Get a proposal by ID.
  """
  @spec get_proposal(String.t(), GenServer.server()) ::
          {:ok, Arbor.Contracts.Consensus.Proposal.t()} | {:error, :not_found}
  defdelegate get_proposal(proposal_id, server \\ Coordinator), to: Coordinator

  # ============================================================================
  # Listing & Querying
  # ============================================================================

  @doc """
  List all pending proposals.
  """
  @spec list_pending(GenServer.server()) :: [Arbor.Contracts.Consensus.Proposal.t()]
  defdelegate list_pending(server \\ Coordinator), to: Coordinator

  @doc """
  List all proposals.
  """
  @spec list_proposals(GenServer.server()) :: [Arbor.Contracts.Consensus.Proposal.t()]
  defdelegate list_proposals(server \\ Coordinator), to: Coordinator

  @doc """
  List all decisions.
  """
  @spec list_decisions(GenServer.server()) :: [Arbor.Contracts.Consensus.CouncilDecision.t()]
  defdelegate list_decisions(server \\ Coordinator), to: Coordinator

  @doc """
  Get recent decisions (most recent first).
  """
  @spec recent_decisions(pos_integer(), GenServer.server()) ::
          [Arbor.Contracts.Consensus.CouncilDecision.t()]
  defdelegate recent_decisions(limit \\ 10, server \\ Coordinator), to: Coordinator

  # ============================================================================
  # Management
  # ============================================================================

  @doc """
  Cancel a pending proposal.
  """
  @spec cancel(String.t(), GenServer.server()) :: :ok | {:error, term()}
  defdelegate cancel(proposal_id, server \\ Coordinator), to: Coordinator

  @doc """
  Source-owned compare-and-settle for a pending authorization-request approval.

  Settlement cancels/vetoes the exact pending proposal after reprojecting its
  closed identity. Never approves. Returns JSON-clean `settled` or
  `already_absent` receipts.
  """
  @spec compare_and_settle_pending_approval(map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def compare_and_settle_pending_approval(fields, opts \\ [])

  def compare_and_settle_pending_approval(fields, opts)
      when is_map(fields) and is_list(opts) do
    server = Keyword.get(opts, :server, Coordinator)
    Coordinator.compare_and_settle_pending_approval(fields, server)
  end

  def compare_and_settle_pending_approval(_fields, _opts),
    do: {:error, :invalid_reconciliation_settle_fields}

  @doc """
  Force-approve a proposal (human override).
  """
  @spec force_approve(String.t(), String.t(), GenServer.server()) :: :ok | {:error, term()}
  defdelegate force_approve(proposal_id, approver_id, server \\ Coordinator), to: Coordinator

  @doc """
  Force-reject a proposal (human override).
  """
  @spec force_reject(String.t(), String.t(), GenServer.server()) :: :ok | {:error, term()}
  defdelegate force_reject(proposal_id, rejector_id, server \\ Coordinator), to: Coordinator

  @doc """
  Answer a pending authorization-request proposal.

  This is narrower than `force_approve/3` and `force_reject/3`: it only applies
  to proposals whose topic is `:authorization_request`, and authorizes the actor
  against `arbor://approval/answer` (or the per-agent subtree) instead of the
  broader `arbor://consensus/admin` override.
  """
  @spec answer_authorization_request(
          String.t(),
          :approve | :deny | :rework,
          String.t(),
          keyword()
        ) ::
          :ok | {:error, term()}
  def answer_authorization_request(proposal_id, decision, actor_id, opts \\ []) do
    server = Keyword.get(opts, :server, Coordinator)
    opts = Keyword.delete(opts, :server)
    Coordinator.answer_authorization_request(proposal_id, decision, actor_id, opts, server)
  end

  @doc """
  Get coordinator statistics.
  """
  @spec stats(GenServer.server()) :: map()
  defdelegate stats(server \\ Coordinator), to: Coordinator

  # ============================================================================
  # Async Agent-Facing API
  # ============================================================================

  @doc """
  Submit a formal proposal for consensus evaluation.

  Full Coordinator enforcement: dedup, quota, authorization, capacity.
  Returns immediately with the proposal ID. Use `await/2` for results.

  ## Options

    * `:server` - Coordinator server (default: `Coordinator`)
    * `:context` - Domain-specific context map
    * `:evaluator_backend` - Override evaluator backend
  """
  @impl Arbor.Contracts.API.Consensus
  @spec propose(map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def propose(attrs, opts \\ []) do
    # Ensure topic is set (default :general if missing)
    attrs = Map.put_new(attrs, :topic, :general)
    attrs = Map.put_new(attrs, :mode, :decision)

    # OQ-5: propose/2 now ALWAYS requires an authenticated :caller_id and routes
    # through authorize_propose/3 so callers can't bypass the capability gate by
    # going through this facade. There is NO dev/test permissive submit — an
    # unauthenticated propose (no :caller_id) FAILS CLOSED in every environment.
    # System-internal callers that legitimately need an un-gated submit must call
    # Coordinator.submit/2 (or Arbor.Consensus.submit/2) directly and own that
    # bypass explicitly, rather than smuggling it through propose/2.
    case Keyword.fetch(opts, :caller_id) do
      {:ok, caller_id} when is_binary(caller_id) ->
        authorize_propose(caller_id, attrs, Keyword.delete(opts, :caller_id))

      _ ->
        {:error, {:unauthorized, :caller_id_required}}
    end
  end

  @doc """
  Ask an advisory question through the consensus system.

  Routes through Coordinator for TopicMatcher routing but with
  relaxed enforcement (no dedup, no quota, no quorum requirement).
  Use `await/2` for results, or fire-and-forget.

  For direct evaluator invocation (developer mode), use
  `Arbor.Consensus.Evaluators.Consult.ask/3` instead.

  ## Options

    * `:server` - Coordinator server (default: `Coordinator`)
    * `:context` - Domain-specific context map
    * `:perspectives` - Override which perspectives to consult
    * `:proposer` - Identity of the asker (default: "system")
  """
  @impl Arbor.Contracts.API.Consensus
  @spec ask(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def ask(description, opts \\ []) do
    context = Keyword.get(opts, :context, %{})

    attrs = %{
      proposer: Keyword.get(opts, :proposer, "system"),
      topic: :advisory,
      mode: :advisory,
      description: description,
      target_layer: Keyword.get(opts, :target_layer, 4),
      context: context
    }

    Coordinator.submit(attrs, Keyword.put(opts, :advisory, true))
  end

  @doc """
  Wait for a proposal's result.

  Registers as a waiter in the Coordinator and receives the result
  via direct message. No polling, no signal bus.

  ## Options

    * `:timeout` - Maximum wait time in ms (default: 30_000)
    * `:server` - Coordinator server (default: `Coordinator`)
  """
  @impl Arbor.Contracts.API.Consensus
  @spec await(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  defdelegate await(proposal_id, opts \\ []), to: Coordinator

  @doc """
  Run a binding council decision via the DOT engine pipeline.

  Loads `council-decision.dot`, fans out to all perspectives in parallel,
  tallies votes, and returns a CouncilDecision with quorum enforcement.

  Unlike `ask/2` (advisory, non-binding), this produces real approve/reject/deadlock
  decisions. Perspectives, models, quorum — all configurable via the DOT file
  without recompilation.

  ## Options

    * `:graph` — path to custom council DOT file
    * `:quorum` — "majority" | "supermajority" | "unanimous"
    * `:mode` — "decision" | "advisory"
    * `:timeout` — engine timeout in ms (default: 600_000)
    * `:context` — additional context map
  """
  @spec decide(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def decide(description, opts \\ []) do
    evaluator = Keyword.get(opts, :evaluator, Arbor.Consensus.Evaluators.AdvisoryLLM)
    Consult.decide(evaluator, description, opts)
  end

  @doc """
  Consult the advisory council and return evaluations plus the ConsultationLog run id.

  This is the facade entry for design-time advisory review. It uses the 13
  `AdvisoryLLM` perspectives (distinct from the binding code-review council).
  Inject `:evaluator` to override the seat module in tests. Inject
  `:consultation_log` to control the persistence boundary.

  Pass `:deadline_unix_ms` for one consultation-wide absolute wall-clock
  deadline. Remaining time is recomputed from a live clock immediately
  before every blocking step. A supervised temporary finalizer, started
  before the `running` row is exposed, best-effort CAS-terminalizes the
  ConsultationLog run after that deadline plus a small grace. Retries
  continue until deadline plus grace and log loudly on exhaustion. A
  stored row may remain `running` only if persistence is unavailable for
  that whole window. Invalid options return
  `{:error, {:invalid_option, key}}` and never raise. `:evaluator` must
  be a loadable module that exports the required evaluator callbacks
  `name/0`, `perspectives/0`, and `evaluate/3`. `strategy/0` is optional.
  `:consultation_log` must be a loadable module that exports `new_run_id/0`,
  `create_bound_run/3`, and `finalize_run/2`. Normal completion succeeds
  only when the stored run is proven `completed`; a run the timeout
  finalizer already terminalized as failed is returned as an error, never
  as a successful consultation. `:finalizer_grace_ms` must be a
  non-negative integer no greater than `#{@max_finalizer_grace_ms}` ms
  (conservative upper bound so a hung persist retry cannot outlive the
  consult by an arbitrary amount). `:persist_timeout_ms` must be a
  positive integer no greater than `#{@max_persist_timeout_ms}` ms (the
  default persist-attempt budget). An oversized value is rejected; the
  finalizer also clamps any received value to this cap so a hung first
  persist attempt cannot retain a task arbitrarily long. A zero grace is
  accepted; the finalizer still performs one bounded terminalization
  attempt at the deadline.

  Returns `{:ok, %{evaluations: list(), run_id: String.t() | nil}}` or
  `{:error, reason}`. A timeout or consult failure is an error, never an
  approval. A nil `run_id` means persistence was unavailable; callers that
  require an evidence id must fail closed.
  """
  @spec consult(String.t(), keyword()) ::
          {:ok, %{evaluations: list(), run_id: String.t() | nil}} | {:error, term()}
  def consult(description, opts \\ [])

  def consult(description, opts) when is_binary(description) and is_list(opts) do
    case validate_consult_opts(opts) do
      :ok ->
        evaluator = Keyword.get(opts, :evaluator, Arbor.Consensus.Evaluators.AdvisoryLLM)
        Consult.ask_logged(evaluator, description, opts)

      {:error, _} = error ->
        error
    end
  end

  def consult(_description, _opts), do: {:error, :invalid_consult_input}

  defp validate_consult_opts(opts) do
    if Keyword.keyword?(opts) do
      Enum.reduce_while(opts, :ok, fn {key, value}, :ok ->
        case validate_consult_option(key, value) do
          :ok -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end
      end)
    else
      {:error, {:invalid_option, :opts}}
    end
  end

  defp validate_consult_option(:evaluator, module) when is_atom(module) do
    if evaluator_module?(module) do
      :ok
    else
      {:error, {:invalid_option, :evaluator}}
    end
  end

  defp validate_consult_option(:consultation_log, module)
       when is_atom(module) and not is_nil(module) do
    if consultation_log_module?(module) do
      :ok
    else
      {:error, {:invalid_option, :consultation_log}}
    end
  end

  defp validate_consult_option(:seat_owner, module)
       when is_atom(module) and not is_nil(module) do
    if seat_owner_module?(module) do
      :ok
    else
      {:error, {:invalid_option, :seat_owner}}
    end
  end

  defp validate_consult_option(:finalizer_grace_ms, grace)
       when is_integer(grace) and grace >= 0 and grace <= @max_finalizer_grace_ms,
       do: :ok

  defp validate_consult_option(:deadline_unix_ms, deadline)
       when is_integer(deadline) and deadline > 0,
       do: :ok

  defp validate_consult_option(:timeout, timeout) when is_integer(timeout) and timeout > 0,
    do: :ok

  defp validate_consult_option(:context, context) when is_map(context), do: :ok
  defp validate_consult_option(:research, research) when is_boolean(research), do: :ok
  defp validate_consult_option(:ai_module, module) when is_atom(module), do: :ok
  defp validate_consult_option(:provider_model, model) when is_binary(model), do: :ok

  defp validate_consult_option(:finalizer_supervisor, name)
       when is_atom(name) and not is_nil(name),
       do: :ok

  defp validate_consult_option(:persist_timeout_ms, timeout)
       when is_integer(timeout) and timeout > 0 and timeout <= @max_persist_timeout_ms,
       do: :ok

  defp validate_consult_option(key, _value) when is_atom(key) do
    {:error, {:invalid_option, key}}
  end

  defp validate_consult_option(key, _value), do: {:error, {:invalid_option, key}}

  defp evaluator_module?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and
      function_exported?(module, :evaluate, 3) and
      function_exported?(module, :perspectives, 0) and
      function_exported?(module, :name, 0)
  end

  defp evaluator_module?(_module), do: false

  defp consultation_log_module?(module) when is_atom(module) and not is_nil(module) do
    Code.ensure_loaded?(module) and
      function_exported?(module, :new_run_id, 0) and
      function_exported?(module, :create_bound_run, 3) and
      function_exported?(module, :finalize_run, 2)
  end

  defp consultation_log_module?(_module), do: false

  defp seat_owner_module?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and
      function_exported?(module, :start, 2) and
      function_exported?(module, :supervisor, 2) and
      function_exported?(module, :stop, 1)
  end

  defp seat_owner_module?(_module), do: false

  # ============================================================================
  # Consultations (Advisory Council)
  # ============================================================================

  @doc """
  List advisory council consultations.

  Delegates to `ConsultationLog.list_consultations/1`.

  ## Filters

    * `:limit` — max results (default: 50)
    * `:status` — "completed", "failed"
  """
  @spec list_consultations(keyword()) :: {:ok, [map()]} | {:error, :unavailable}
  defdelegate list_consultations(filters \\ []), to: ConsultationLog

  @doc """
  Get a single consultation with all perspective results preloaded.

  Delegates to `ConsultationLog.get_consultation/1`.
  """
  @spec get_consultation(String.t()) :: {:ok, map()} | {:error, term()}
  defdelegate get_consultation(run_id), to: ConsultationLog

  # ============================================================================
  # Authorized API (for agent callers — facade-level authorization)
  # ============================================================================

  @doc """
  Submit a proposal with authorization check.

  Verifies the caller has the `arbor://consensus/propose` capability.

  ## Parameters

  - `caller_id` - The ID of the entity submitting the proposal
  - `attrs` - Proposal attributes map
  - `opts` - Options passed to `propose/2`
  """
  @spec authorize_propose(String.t(), map(), keyword()) ::
          {:ok, String.t()} | {:error, {:unauthorized, term()} | term()}
  def authorize_propose(caller_id, attrs, opts \\ []) do
    case authorize(caller_id, "arbor://consensus/propose") do
      :ok ->
        # The cap check just passed — submit DIRECTLY. Do NOT call propose/2
        # here: it would re-apply its own :caller_id gate (we already stripped
        # caller_id), denying this authorized caller with :caller_id_required.
        # Mirror propose/2's attrs normalization since direct callers pass raw
        # attrs.
        attrs =
          attrs
          |> Map.put_new(:topic, :general)
          |> Map.put_new(:mode, :decision)

        Coordinator.submit(attrs, opts)

      {:error, reason} ->
        {:error, {:unauthorized, reason}}
    end
  end

  @doc """
  Ask an advisory question with authorization check.

  Verifies the caller has the `arbor://consensus/ask` capability.

  ## Parameters

  - `caller_id` - The ID of the entity asking
  - `description` - The question to ask
  - `opts` - Options passed to `ask/2`
  """
  @spec authorize_ask(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, {:unauthorized, term()} | term()}
  def authorize_ask(caller_id, description, opts \\ []) do
    case authorize(caller_id, "arbor://consensus/ask") do
      :ok -> ask(description, opts)
      {:error, reason} -> {:error, {:unauthorized, reason}}
    end
  end

  @doc """
  Run a binding council decision with authorization check.

  Verifies the caller has the `arbor://consensus/decide` capability.

  ## Parameters

  - `caller_id` - The ID of the entity requesting the decision
  - `description` - The decision description
  - `opts` - Options passed to `decide/2`
  """
  @spec authorize_decide(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, {:unauthorized, term()} | term()}
  def authorize_decide(caller_id, description, opts \\ []) do
    case authorize(caller_id, "arbor://consensus/decide") do
      :ok -> decide(description, opts)
      {:error, reason} -> {:error, {:unauthorized, reason}}
    end
  end

  @doc """
  Cancel a proposal with authorization check.

  Verifies the caller has the `arbor://consensus/cancel` capability.

  ## Parameters

  - `caller_id` - The ID of the entity requesting cancellation
  - `proposal_id` - The proposal to cancel
  - `opts` - Options (e.g., `:server`)
  """
  @spec authorize_cancel(String.t(), String.t(), keyword()) ::
          :ok | {:error, {:unauthorized, term()} | term()}
  def authorize_cancel(caller_id, proposal_id, opts \\ []) do
    server = Keyword.get(opts, :server, Coordinator)

    case authorize(caller_id, "arbor://consensus/cancel") do
      :ok -> cancel(proposal_id, server)
      {:error, reason} -> {:error, {:unauthorized, reason}}
    end
  end

  @doc """
  Force-approve a proposal with authorization check.

  Verifies the caller has the `arbor://consensus/force_approve` capability.
  This is a high-privilege operation.

  ## Parameters

  - `caller_id` - The ID of the entity forcing approval
  - `proposal_id` - The proposal to approve
  - `approver_id` - The identity recorded as the approver
  - `opts` - Options (e.g., `:server`)
  """
  @spec authorize_force_approve(String.t(), String.t(), String.t(), keyword()) ::
          :ok | {:error, {:unauthorized, term()} | term()}
  def authorize_force_approve(caller_id, proposal_id, approver_id, opts \\ []) do
    server = Keyword.get(opts, :server, Coordinator)

    case authorize(caller_id, "arbor://consensus/force_approve") do
      :ok -> force_approve(proposal_id, approver_id, server)
      {:error, reason} -> {:error, {:unauthorized, reason}}
    end
  end

  @doc """
  Force-reject a proposal with authorization check.

  Verifies the caller has the `arbor://consensus/force_reject` capability.
  This is a high-privilege operation.

  ## Parameters

  - `caller_id` - The ID of the entity forcing rejection
  - `proposal_id` - The proposal to reject
  - `rejector_id` - The identity recorded as the rejector
  - `opts` - Options (e.g., `:server`)
  """
  @spec authorize_force_reject(String.t(), String.t(), String.t(), keyword()) ::
          :ok | {:error, {:unauthorized, term()} | term()}
  def authorize_force_reject(caller_id, proposal_id, rejector_id, opts \\ []) do
    server = Keyword.get(opts, :server, Coordinator)

    case authorize(caller_id, "arbor://consensus/force_reject") do
      :ok -> force_reject(proposal_id, rejector_id, server)
      {:error, reason} -> {:error, {:unauthorized, reason}}
    end
  end

  # ============================================================================
  # Event Store
  # ============================================================================

  @doc """
  Query consensus events.

  ## Filters

    * `:proposal_id` - Filter by proposal ID
    * `:event_type` - Filter by event type
    * `:agent_id` - Filter by agent ID
    * `:since` / `:until` - Time range
    * `:limit` - Max results (default: 100)
  """
  @spec query_events(keyword(), GenServer.server()) ::
          [Arbor.Contracts.Consensus.ConsensusEvent.t()]
  defdelegate query_events(filters \\ [], server \\ EventStore), to: EventStore, as: :query

  @doc """
  Get all events for a proposal.
  """
  @spec events_for(String.t(), GenServer.server()) ::
          [Arbor.Contracts.Consensus.ConsensusEvent.t()]
  defdelegate events_for(proposal_id, server \\ EventStore), to: EventStore, as: :get_by_proposal

  @doc """
  Get a chronological timeline of events for a proposal.
  """
  @spec timeline(String.t(), GenServer.server()) ::
          [{non_neg_integer(), Arbor.Contracts.Consensus.ConsensusEvent.t()}]
  defdelegate timeline(proposal_id, server \\ EventStore), to: EventStore, as: :get_timeline

  # ============================================================================
  # Contract Callbacks (Arbor.Contracts.API.Consensus)
  # ============================================================================

  @impl Arbor.Contracts.API.Consensus
  def submit_proposal_for_consensus_evaluation(proposal_or_attrs, opts),
    do: Coordinator.submit(proposal_or_attrs, opts)

  @impl Arbor.Contracts.API.Consensus
  def get_proposal_status_by_id(proposal_id),
    do: Coordinator.get_status(proposal_id)

  @impl Arbor.Contracts.API.Consensus
  def get_council_decision_for_proposal(proposal_id),
    do: Coordinator.get_decision(proposal_id)

  @impl Arbor.Contracts.API.Consensus
  def get_proposal_by_id(proposal_id),
    do: Coordinator.get_proposal(proposal_id)

  @impl Arbor.Contracts.API.Consensus
  def cancel_proposal_by_id(proposal_id),
    do: Coordinator.cancel(proposal_id)

  @impl Arbor.Contracts.API.Consensus
  def start_link(opts) do
    children = [
      Arbor.Consensus.EventStore,
      {Arbor.Consensus.Coordinator, opts}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Arbor.Consensus.Supervisor)
  end

  @impl Arbor.Contracts.API.Consensus
  def healthy? do
    case Process.whereis(Arbor.Consensus.Supervisor) do
      pid when is_pid(pid) -> Process.alive?(pid)
      _ -> false
    end
  end

  @impl Arbor.Contracts.API.Consensus
  def list_pending_proposals, do: Coordinator.list_pending()

  @impl Arbor.Contracts.API.Consensus
  def list_all_proposals, do: Coordinator.list_proposals()

  @impl Arbor.Contracts.API.Consensus
  def list_all_decisions, do: Coordinator.list_decisions()

  @impl Arbor.Contracts.API.Consensus
  def get_recent_decisions_with_limit(limit),
    do: Coordinator.recent_decisions(limit)

  @impl Arbor.Contracts.API.Consensus
  def force_approve_proposal_by_authority(proposal_id, approver_id),
    do: Coordinator.force_approve(proposal_id, approver_id)

  @impl Arbor.Contracts.API.Consensus
  def force_reject_proposal_by_authority(proposal_id, rejector_id),
    do: Coordinator.force_reject(proposal_id, rejector_id)

  @impl Arbor.Contracts.API.Consensus
  def get_consensus_system_stats, do: Coordinator.stats()

  @impl Arbor.Contracts.API.Consensus
  def query_consensus_events_with_filters(filters),
    do: EventStore.query(filters)

  @impl Arbor.Contracts.API.Consensus
  def get_events_for_proposal(proposal_id),
    do: EventStore.get_by_proposal(proposal_id)

  @impl Arbor.Contracts.API.Consensus
  def get_timeline_for_proposal(proposal_id),
    do: EventStore.get_timeline(proposal_id)

  # ============================================================================
  # Private — Runtime authorization bridge
  # ============================================================================

  # arbor_security is a hard dep (so the module is always loaded — no
  # Code.ensure_loaded?/function_exported? module-presence guard). The runtime
  # security_available?/0 LIVENESS probe still matters: the Security subsystem
  # can be loaded-but-unhealthy, in which case we route to the
  # when_security_unavailable/0 H6 seam rather than calling authorize.
  defp authorize(caller_id, resource_uri) do
    if security_available?() do
      # Identity already verified at action layer — just check capability
      case Arbor.Security.authorize(caller_id, resource_uri, :execute, verify_identity: false) do
        {:ok, :authorized} -> :ok
        {:ok, :pending_approval, _proposal_id} = pending -> pending
        {:error, reason} -> {:error, reason}
      end
    else
      # H6: pre-fix, this branch returned :ok unconditionally — partial
      # security outages silently became unconditional authorization. It now
      # fails closed in every environment via when_security_unavailable/0.
      when_security_unavailable()
    end
  end

  # Public (@doc false) for the H6 regression test. See Memory facade for
  # rationale; mirroring the shape here so all three Level-2 facades expose
  # the same testable seam. Fails closed everywhere — a loaded-but-unhealthy
  # Security subsystem can never be treated as an implicit authorization.
  @doc false
  @spec when_security_unavailable() :: {:error, :security_unavailable}
  def when_security_unavailable do
    {:error, :security_unavailable}
  end

  defp security_available? do
    Arbor.Security.healthy?()
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end
end
