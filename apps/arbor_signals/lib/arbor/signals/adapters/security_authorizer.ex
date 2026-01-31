defmodule Arbor.Signals.Adapters.SecurityAuthorizer do
  @moduledoc """
  Capability-based subscription authorizer.

  Checks whether a principal has the `arbor://signals/subscribe/{topic}`
  capability via the security kernel. Uses `apply/3` for runtime module
  resolution to avoid a compile-time dependency on `arbor_security`.

  ## Configuration

  The security facade module is resolved via:

      Application.get_env(:arbor_signals, :security_module, Arbor.Security)
  """

  @behaviour Arbor.Signals.Behaviours.SubscriptionAuthorizer

  @impl true
  def authorize_subscription(principal_id, topic) do
    resource_uri = "arbor://signals/subscribe/#{topic}"
    security_module = Application.get_env(:arbor_signals, :security_module, Arbor.Security)

    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    case apply(security_module, :authorize, [principal_id, resource_uri, :subscribe]) do
      {:ok, :authorized} -> {:ok, :authorized}
      {:error, _reason} -> {:error, :no_capability}
    end
  end
end
