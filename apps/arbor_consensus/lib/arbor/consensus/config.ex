defmodule Arbor.Consensus.Config do
  @moduledoc """
  Configuration for the consensus system.

  Centralizes quorum rules, perspective assignments, timeouts,
  and concurrency limits. Built from keyword opts or defaults.
  """

  use TypedStruct

  alias Arbor.Contracts.Consensus.Protocol

  @default_council_size 7
  @default_evaluation_timeout_ms 90_000
  @default_max_concurrent 10

  @default_quorum_rules %{
    governance_change: 6,
    code_modification: 5,
    capability_change: 5,
    configuration_change: 5,
    dependency_change: 5,
    layer_modification: 5,
    documentation_change: 4,
    test_change: 4,
    sdlc_decision: 5
  }

  @default_perspectives %{
    code_modification: [
      :security,
      :stability,
      :capability,
      :adversarial,
      :resource,
      :emergence,
      :random
    ],
    governance_change: [
      :security,
      :stability,
      :capability,
      :adversarial,
      :resource,
      :emergence,
      :random
    ],
    capability_change: [
      :security,
      :stability,
      :capability,
      :adversarial,
      :resource,
      :emergence,
      :random
    ],
    configuration_change: [
      :security,
      :stability,
      :capability,
      :resource,
      :emergence,
      :code_review,
      :random
    ],
    dependency_change: [
      :security,
      :stability,
      :adversarial,
      :resource,
      :code_review,
      :test_runner,
      :random
    ],
    layer_modification: [
      :security,
      :stability,
      :capability,
      :adversarial,
      :resource,
      :emergence,
      :random
    ],
    documentation_change: [
      :code_review,
      :capability,
      :stability,
      :resource,
      :random,
      :emergence,
      :test_runner
    ],
    test_change: [
      :test_runner,
      :code_review,
      :stability,
      :capability,
      :resource,
      :random,
      :emergence
    ],
    sdlc_decision: [
      :scope,
      :feasibility,
      :priority,
      :architecture,
      :consistency,
      :adversarial,
      :random
    ]
  }

  typedstruct do
    @typedoc "Consensus system configuration"

    field(:council_size, pos_integer(), default: @default_council_size)
    field(:evaluation_timeout_ms, pos_integer(), default: @default_evaluation_timeout_ms)
    field(:max_concurrent_proposals, pos_integer(), default: @default_max_concurrent)
    field(:auto_execute_approved, boolean(), default: false)
    field(:quorum_rules, map(), default: @default_quorum_rules)
    field(:perspectives_for_change_type, map(), default: @default_perspectives)
  end

  @doc """
  Create a new config from keyword options.

  ## Options

    * `:council_size` - Number of evaluators per council (default: 7)
    * `:evaluation_timeout_ms` - Timeout for evaluator tasks (default: 90_000)
    * `:max_concurrent_proposals` - Max proposals being evaluated at once (default: 10)
    * `:auto_execute_approved` - Whether to auto-execute approved proposals (default: false)
    * `:quorum_rules` - Map of change_type => required approvals
    * `:perspectives_for_change_type` - Map of change_type => [perspective]
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      council_size: Keyword.get(opts, :council_size, @default_council_size),
      evaluation_timeout_ms:
        Keyword.get(opts, :evaluation_timeout_ms, @default_evaluation_timeout_ms),
      max_concurrent_proposals:
        Keyword.get(opts, :max_concurrent_proposals, @default_max_concurrent),
      auto_execute_approved: Keyword.get(opts, :auto_execute_approved, false),
      quorum_rules:
        Map.merge(@default_quorum_rules, Keyword.get(opts, :quorum_rules, %{})),
      perspectives_for_change_type:
        Map.merge(
          @default_perspectives,
          Keyword.get(opts, :perspectives_for_change_type, %{})
        )
    }
  end

  @doc """
  Get the required quorum for a change type.
  """
  @spec quorum_for(t(), atom()) :: pos_integer()
  def quorum_for(%__MODULE__{quorum_rules: rules}, change_type) do
    Map.get(rules, change_type, Protocol.standard_quorum())
  end

  @doc """
  Get the perspectives to evaluate for a change type.
  """
  @spec perspectives_for(t(), atom()) :: [atom()]
  def perspectives_for(%__MODULE__{perspectives_for_change_type: perspectives}, change_type) do
    Map.get(perspectives, change_type, Protocol.perspectives() -- [:human])
  end

  @doc """
  Check if a change type requires supermajority (6/7 or higher).
  """
  @spec requires_supermajority?(t(), atom()) :: boolean()
  def requires_supermajority?(%__MODULE__{} = config, change_type) do
    quorum_for(config, change_type) >= Protocol.meta_quorum()
  end

  # ===========================================================================
  # Application-level config (read from Application env)
  # ===========================================================================

  @app :arbor_consensus

  @doc """
  Timeout for deterministic evaluator commands (default: 60_000ms).
  """
  @spec deterministic_evaluator_timeout() :: pos_integer()
  def deterministic_evaluator_timeout do
    Application.get_env(@app, :deterministic_evaluator_timeout, 60_000)
  end

  @doc """
  Sandbox mode for deterministic evaluator shell commands (default: :strict).
  """
  @spec deterministic_evaluator_sandbox() :: atom()
  def deterministic_evaluator_sandbox do
    Application.get_env(@app, :deterministic_evaluator_sandbox, :strict)
  end

  @doc """
  Default working directory for deterministic evaluator (default: nil).

  If nil, requires project_path in proposal metadata.
  """
  @spec deterministic_evaluator_default_cwd() :: String.t() | nil
  def deterministic_evaluator_default_cwd do
    Application.get_env(@app, :deterministic_evaluator_default_cwd, nil)
  end

  # ===========================================================================
  # Quota Configuration (Phase 7)
  # ===========================================================================

  @doc """
  Maximum number of active proposals a single agent can have simultaneously.

  Default: 10. When exceeded, `submit/2` returns `{:error, :agent_proposal_quota_exceeded}`.
  """
  @spec max_proposals_per_agent() :: pos_integer()
  def max_proposals_per_agent do
    Application.get_env(@app, :max_proposals_per_agent, 10)
  end

  @doc """
  Whether per-agent proposal quota enforcement is enabled.

  Default: true. When false, agents can submit unlimited proposals.
  """
  @spec proposal_quota_enabled?() :: boolean()
  def proposal_quota_enabled? do
    Application.get_env(@app, :proposal_quota_enabled, true)
  end

  # ===========================================================================
  # LLM Evaluator Configuration (Phase 8)
  # ===========================================================================

  @doc """
  Timeout for LLM evaluator calls in milliseconds.

  Default: 60_000 (60 seconds). LLM calls can be slow; this should be
  long enough for complex analysis but not indefinite.
  """
  @spec llm_evaluator_timeout() :: pos_integer()
  def llm_evaluator_timeout do
    Application.get_env(@app, :llm_evaluator_timeout, 60_000)
  end

  @doc """
  Module implementing `Arbor.Contracts.API.AI` for LLM evaluators.

  Default: `Arbor.AI`. Override for testing or custom providers.
  """
  @spec llm_evaluator_ai_module() :: module()
  def llm_evaluator_ai_module do
    Application.get_env(@app, :llm_evaluator_ai_module, Arbor.AI)
  end

  @doc """
  Whether LLM evaluators are enabled.

  Default: true. When false, LLM perspectives are skipped and return abstain.
  Useful for environments without LLM API access.
  """
  @spec llm_evaluators_enabled?() :: boolean()
  def llm_evaluators_enabled? do
    Application.get_env(@app, :llm_evaluators_enabled, true)
  end

  @doc """
  LLM-based perspectives available for consensus evaluation.

  These perspectives use LLM analysis for subjective review.
  """
  @spec llm_perspectives() :: [atom()]
  def llm_perspectives do
    [:security_llm, :architecture_llm, :code_quality_llm, :performance_llm]
  end

  # ===========================================================================
  # Event Sourcing Configuration
  # ===========================================================================

  @doc """
  Event log backend configuration for crash recovery.

  Returns `{module, opts}` tuple for the configured event log, or `nil` if
  event logging is disabled.

  ## Configuration

      config :arbor_consensus,
        event_log: {Arbor.Persistence.EventLog.ETS, name: :consensus_events}

  Or for production with Postgres:

      config :arbor_consensus,
        event_log: {Arbor.Persistence.Ecto.EventLog, []}
  """
  @spec event_log() :: {module(), keyword()} | nil
  def event_log do
    Application.get_env(@app, :event_log, nil)
  end

  @doc """
  Stream name for consensus events.

  All consensus events are written to this single stream for simple
  replay and subscription patterns.

  Default: "arbor:consensus"
  """
  @spec event_stream() :: String.t()
  def event_stream do
    Application.get_env(@app, :event_stream, "arbor:consensus")
  end

  @doc """
  Recovery strategy for interrupted evaluations.

  When the Coordinator restarts and finds evaluations that were in progress:
  - `:deadlock` - Mark as deadlocked, require re-submission (default, safest)
  - `:resume` - Re-spawn only the missing evaluations
  - `:restart` - Re-spawn the entire council

  Default: :deadlock
  """
  @spec recovery_strategy() :: :deadlock | :resume | :restart
  def recovery_strategy do
    Application.get_env(@app, :recovery_strategy, :deadlock)
  end

  @doc """
  Whether to emit events on startup/recovery.

  Default: true. Set to false for testing without event persistence.
  """
  @spec emit_recovery_events?() :: boolean()
  def emit_recovery_events? do
    Application.get_env(@app, :emit_recovery_events, true)
  end
end
