defmodule Arbor.Signals.Behaviours.SubscriptionAuthorizer do
  @moduledoc """
  Behaviour for authorizing signal bus subscriptions.

  Restricted topics (e.g., `:security`, `:identity`) require capability-based
  authorization. Open topics allow all subscribers by default.

  The authorizer is configured via application config and resolved at runtime,
  avoiding compile-time dependencies between `arbor_signals` and `arbor_security`.

  ## Implementations

  - `Arbor.Signals.Adapters.OpenAuthorizer` — allows all subscriptions (test default)
  - `Arbor.Signals.Adapters.CapabilityAuthorizer` — fast ETS capability check via `can?/3` (dev/prod default)
  - `Arbor.Signals.Adapters.SecurityAuthorizer` — full authorization pipeline via `authorize/4`
  """

  @type principal_id :: String.t()
  @type topic :: atom()
  @type auth_result :: {:ok, :authorized} | {:error, :unauthorized | :no_capability}

  @doc """
  Authorize a subscription for a principal to a specific topic.

  Returns `{:ok, :authorized}` if the principal may subscribe, or
  `{:error, reason}` if the subscription should be denied.
  """
  @callback authorize_subscription(principal_id(), topic()) :: auth_result()
end
