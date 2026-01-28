defmodule Arbor.Security.Config do
  @moduledoc """
  Application configuration for the Arbor.Security library.

  Wraps `Application.get_env/3` with baked-in defaults.

  ## Configuration

      config :arbor_security,
        identity_verification: true,           # require signed requests for authorization
        nonce_ttl_seconds: 300,                 # nonces expire after 5 minutes
        timestamp_max_drift_seconds: 60,        # accept timestamps within ±60s of now
        capability_signing_required: false       # require signed capabilities (false for migration)
  """

  @app :arbor_security

  @doc """
  Whether identity verification is enabled for authorization checks.

  When disabled, `authorize/4` skips signed request verification, allowing
  legacy string agent IDs to work without cryptographic identity.
  """
  @spec identity_verification_enabled?() :: boolean()
  def identity_verification_enabled? do
    Application.get_env(@app, :identity_verification, true)
  end

  @doc """
  How long nonces are remembered for replay protection (in seconds).
  """
  @spec nonce_ttl_seconds() :: pos_integer()
  def nonce_ttl_seconds do
    Application.get_env(@app, :nonce_ttl_seconds, 300)
  end

  @doc """
  Maximum allowed clock drift between request timestamp and server time (in seconds).
  """
  @spec timestamp_max_drift_seconds() :: pos_integer()
  def timestamp_max_drift_seconds do
    Application.get_env(@app, :timestamp_max_drift_seconds, 60)
  end

  @doc """
  Whether capability signing is required for authorization.

  When `false` (default), unsigned capabilities from before Phase 2 are accepted.
  When `true`, all capabilities must have a valid issuer signature to authorize.
  """
  @spec capability_signing_required?() :: boolean()
  def capability_signing_required? do
    Application.get_env(@app, :capability_signing_required, false)
  end

  @doc """
  Whether constraint enforcement is enabled for authorization.

  When `true` (default), constraints on capabilities are evaluated during `authorize/4`.
  When `false`, constraints are metadata-only and not enforced.
  """
  @spec constraint_enforcement_enabled?() :: boolean()
  def constraint_enforcement_enabled? do
    Application.get_env(@app, :constraint_enforcement_enabled, true)
  end

  @doc """
  The period over which rate limit tokens fully refill (in seconds).

  A capability with `rate_limit: 100` gets 100 tokens per refill period.
  Default: 3600 (1 hour).
  """
  @spec rate_limit_refill_period_seconds() :: pos_integer()
  def rate_limit_refill_period_seconds do
    Application.get_env(@app, :rate_limit_refill_period_seconds, 3600)
  end

  @doc """
  How long an inactive rate limit bucket is kept before cleanup (in seconds).

  Default: 3600 (1 hour).
  """
  @spec rate_limit_bucket_ttl_seconds() :: pos_integer()
  def rate_limit_bucket_ttl_seconds do
    Application.get_env(@app, :rate_limit_bucket_ttl_seconds, 3600)
  end

  @doc """
  Interval between stale bucket cleanup sweeps (in milliseconds).

  Default: 300_000 (5 minutes).
  """
  @spec rate_limit_cleanup_interval_ms() :: pos_integer()
  def rate_limit_cleanup_interval_ms do
    Application.get_env(@app, :rate_limit_cleanup_interval_ms, 300_000)
  end

  @doc """
  Whether consensus escalation is enabled for `requires_approval` constraints.

  When `true` (default), capabilities with `requires_approval: true` trigger
  consensus submission through the configured `consensus_module`.
  When `false`, `requires_approval` is ignored (treated as always approved).
  """
  @spec consensus_escalation_enabled?() :: boolean()
  def consensus_escalation_enabled? do
    Application.get_env(@app, :consensus_escalation_enabled, true)
  end

  @doc """
  The module to use for consensus submission.

  Must implement `submit/2` returning `{:ok, proposal_id}` or `{:error, reason}`.
  Default: `Arbor.Consensus` (if available).

  Set to `nil` to disable consensus integration entirely.
  """
  @spec consensus_module() :: module() | nil
  def consensus_module do
    Application.get_env(@app, :consensus_module, Arbor.Consensus)
  end

  # ===========================================================================
  # Quota Configuration (Phase 7)
  # ===========================================================================

  @doc """
  Maximum number of capabilities a single agent can hold.

  Default: 1000. When exceeded, `grant/1` returns
  `{:error, {:quota_exceeded, :per_agent_capability_limit, ...}}`.
  """
  @spec max_capabilities_per_agent() :: pos_integer()
  def max_capabilities_per_agent do
    Application.get_env(@app, :max_capabilities_per_agent, 1000)
  end

  @doc """
  Maximum total capabilities stored in the system.

  Default: 100_000. When exceeded, `grant/1` returns
  `{:error, {:quota_exceeded, :global_capability_limit, ...}}`.
  """
  @spec max_global_capabilities() :: pos_integer()
  def max_global_capabilities do
    Application.get_env(@app, :max_global_capabilities, 100_000)
  end

  @doc """
  Maximum delegation chain depth allowed.

  Default: 10. Capabilities with `delegation_depth > max_delegation_depth`
  are rejected on store with `{:error, {:quota_exceeded, :delegation_depth_limit, ...}}`.
  """
  @spec max_delegation_depth() :: non_neg_integer()
  def max_delegation_depth do
    Application.get_env(@app, :max_delegation_depth, 10)
  end

  @doc """
  Whether quota enforcement is enabled.

  Default: true. When false, all quota checks are skipped.
  Useful for testing or migration scenarios.
  """
  @spec quota_enforcement_enabled?() :: boolean()
  def quota_enforcement_enabled? do
    Application.get_env(@app, :quota_enforcement_enabled, true)
  end
end
