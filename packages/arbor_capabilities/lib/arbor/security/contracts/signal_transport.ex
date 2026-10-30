defmodule Arbor.Security.Contracts.SignalTransport do
  @moduledoc """
  Host transport for load-bearing security synchronization.

  Callbacks execute synchronously in the actual security-store owner process.
  A provider must authenticate that caller for subscriptions and publication,
  return a live local transport PID, and issue an unforgeable delivery reference
  for each subscription. Deliveries use `{:signal_received, reference, signal}`;
  an event payload or an ordinary subscription identifier is not authentication.

  A missing provider is explicitly local-only. Configured providers must implement
  every callback; unavailable, raising or malformed providers cannot silently
  downgrade security-store startup to local-only. Configuration predicates return
  exact booleans and describe configured roles, not transient service health.

  Subscription, unsubscription and publication errors are transport-specific.
  Common failures include `:unauthorized`, `:not_found`, transport unavailability
  and a restart while subscribing. Publication remains best effort after a local
  mutation; it is not a distributed durability or replay-protection guarantee.
  """

  @type subscription_id :: String.t()

  @callback security_sync_transport_configured?() :: boolean()
  @callback security_sync_role_configured?(atom()) :: boolean()
  @callback subscribe_security_sync(atom(), atom()) ::
              {:ok, subscription_id(), pid(), reference()} | {:error, term()}
  @callback unsubscribe(subscription_id()) :: :ok | {:error, term()}
  @callback admit_remote_security_mutation?(atom()) :: boolean()
  @callback emit(atom(), atom(), map(), keyword()) :: :ok | {:error, term()}
end
