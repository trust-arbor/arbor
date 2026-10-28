defmodule Arbor.Security.Adapters.SignalsTransport do
  @moduledoc """
  Arbor's security-sync transport through the public Signals facade.

  The caller remains the real security-store owner so Signals can enforce its
  existing supervised-owner provenance and private delivery custody.
  """

  @behaviour Arbor.Security.Contracts.SignalTransport

  alias Arbor.Signals

  @impl true
  defdelegate security_sync_transport_configured?(), to: Signals

  @impl true
  defdelegate security_sync_role_configured?(role), to: Signals

  @impl true
  defdelegate subscribe_security_sync(role, event), to: Signals

  @impl true
  defdelegate unsubscribe(subscription_id), to: Signals

  @impl true
  defdelegate admit_remote_security_mutation?(type), to: Signals

  @impl true
  defdelegate emit(category, type, data, opts), to: Signals
end
