defmodule Arbor.Consensus.Config do
  @moduledoc """
  Configuration for the consensus system.

  Centralizes quorum rules, perspective assignments, timeouts,
  and concurrency limits. Built from keyword opts or defaults.
  """

  use TypedStruct

  @default_evaluation_timeout_ms 90_000
  @default_max_concurrent 10

  typedstruct do
    @typedoc "Consensus system configuration"

    field(:evaluation_timeout_ms, pos_integer(), default: @default_evaluation_timeout_ms)
    field(:max_concurrent_proposals, pos_integer(), default: @default_max_concurrent)
    field(:auto_execute_approved, boolean(), default: false)
    # Per-coordinator quota settings (override Application env if set)
    field(:max_proposals_per_agent, pos_integer() | nil, default: nil)
    field(:proposal_quota_enabled, boolean() | nil, default: nil)
  end

  @doc """
  Create a new config from keyword options.

  ## Options

    * `:evaluation_timeout_ms` - Timeout for evaluator tasks (default: 90_000)
    * `:max_concurrent_proposals` - Max proposals being evaluated at once (default: 10)
    * `:auto_execute_approved` - Whether to auto-execute approved proposals (default: false)
    * `:max_proposals_per_agent` - Per-instance override for agent quota (default: nil, uses Application env)
    * `:proposal_quota_enabled` - Per-instance override for quota enabled (default: nil, uses Application env)
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      evaluation_timeout_ms:
        Keyword.get(opts, :evaluation_timeout_ms, @default_evaluation_timeout_ms),
      max_concurrent_proposals:
        Keyword.get(opts, :max_concurrent_proposals, @default_max_concurrent),
      auto_execute_approved: Keyword.get(opts, :auto_execute_approved, false),
      max_proposals_per_agent: Keyword.get(opts, :max_proposals_per_agent),
      proposal_quota_enabled: Keyword.get(opts, :proposal_quota_enabled)
    }
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
    Application.get_env(@app, :llm_evaluator_timeout, 180_000)
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
  Whether LLM-based topic classification is enabled in TopicMatcher.

  Default: true. When false, TopicMatcher uses only pattern-based matching
  and falls back to `:general` for unmatched proposals.
  Useful for environments without LLM API access or for testing.
  """
  @spec llm_topic_classification_enabled?() :: boolean()
  def llm_topic_classification_enabled? do
    Application.get_env(@app, :llm_topic_classification_enabled, true)
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

  # ===========================================================================
  # Event Recording Decoupling (Phase 6a)
  # ===========================================================================

  @doc """
  Event persistence strategy.

  Controls which persistence layers are used for consensus events:
  - `:signals_only` - Only emit signals (default, lightweight)
  - `:with_event_store` - Signals + in-memory EventStore
  - `:with_event_log` - Signals + durable EventLog (requires event_log config)
  - `:full` - Signals + EventStore + EventLog

  Signals are always emitted for real-time observability regardless of strategy.
  EventStore provides in-memory queryable storage for the current session.
  EventLog provides durable persistence across restarts.

  Default: :signals_only
  """
  @spec event_persistence_strategy() ::
          :signals_only | :with_event_store | :with_event_log | :full
  def event_persistence_strategy do
    Application.get_env(@app, :event_persistence_strategy, :signals_only)
  end

  @doc """
  Whether to record events to the in-memory EventStore.

  Returns true if strategy is `:with_event_store` or `:full`.
  """
  @spec event_store_enabled?() :: boolean()
  def event_store_enabled? do
    event_persistence_strategy() in [:with_event_store, :full]
  end

  @doc """
  Whether to record events to the durable EventLog.

  Returns true if strategy is `:with_event_log` or `:full`, AND
  an event_log backend is configured.
  """
  @spec event_log_enabled?() :: boolean()
  def event_log_enabled? do
    event_persistence_strategy() in [:with_event_log, :full] and event_log() != nil
  end
end
