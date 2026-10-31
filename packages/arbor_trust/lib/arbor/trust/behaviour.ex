defmodule Arbor.Trust.Behaviour do
  @moduledoc """
  Internal behaviour for the progressive trust system.

  This behaviour defines the interface that `Arbor.Trust.Manager` implements.
  It lives inside arbor_trust because it is an internal contract — only
  `Trust.Manager` implements it, and no other library depends on it.

  For the **public API** contract that external consumers use, see
  `Arbor.Contracts.API.Trust`.

  ## Safety Mechanisms

  - **Circuit Breaker**: Freezes trust on anomalous behavior
  """

  alias Arbor.Contracts.Trust.Profile

  # Types
  @type agent_id :: String.t()

  @type trust_event_type ::
          :action_success
          | :action_failure
          | :test_passed
          | :test_failed
          | :rollback_executed
          | :security_violation
          | :improvement_applied
          | :trust_frozen
          | :trust_unfrozen

  @callback get_trust_profile(agent_id()) ::
              {:ok, Profile.t()} | {:error, :not_found | term()}

  @callback record_trust_event(agent_id(), trust_event_type(), metadata :: map()) :: :ok

  @callback freeze_trust(agent_id(), reason :: atom()) :: :ok | {:error, term()}

  @callback unfreeze_trust(agent_id()) :: :ok | {:error, term()}

  @callback create_trust_profile(agent_id()) :: {:ok, Profile.t()} | {:error, term()}

  @callback delete_trust_profile(agent_id()) :: :ok | {:error, term()}
end
