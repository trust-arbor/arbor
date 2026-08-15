defmodule Arbor.Signals.Behaviours.SubscriptionAuthorizer do
  @moduledoc """
  Behaviour for authorizing signal bus subscriptions.

  Restricted topics (e.g., `:security`, `:identity`) require capability-based
  authorization. Open topics allow all subscribers by default.

  The authorizer is configured via application config and resolved at runtime,
  avoiding a compile-time dependency from this library onto an upper
  authorization implementation.

  ## Implementations

  - `Arbor.Signals.Adapters.OpenAuthorizer` — allows all subscriptions (test default)
  - `Arbor.Signals.Adapters.CapabilityAuthorizer` — production authorizer; forwards
    bounded subscribe checks to the configured authorization provider
  """

  @type principal_id :: String.t()
  @type topic :: atom()
  @type auth_result ::
          {:ok, :authorized} | {:error, :unauthorized | :no_capability | :pending_approval}

  @doc """
  Authorize a subscription for a principal to a specific topic.

  Returns `{:ok, :authorized}` if the principal may subscribe, or
  `{:error, reason}` if the subscription should be denied.
  """
  @callback authorize_subscription(principal_id(), topic()) :: auth_result()

  @doc """
  Authorize a subscription with additional caller options.

  Optional. The bus uses arity 3 when exported and otherwise calls arity 2.
  """
  @callback authorize_subscription(principal_id(), topic(), keyword()) :: auth_result()

  @optional_callbacks authorize_subscription: 3
end
