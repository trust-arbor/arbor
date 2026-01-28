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
end
