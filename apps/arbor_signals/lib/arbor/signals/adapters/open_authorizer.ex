defmodule Arbor.Signals.Adapters.OpenAuthorizer do
  @moduledoc """
  Default authorizer that allows all subscriptions.

  Used when no security kernel is configured, providing full backward
  compatibility with the existing signal bus behavior.
  """

  @behaviour Arbor.Signals.Behaviours.SubscriptionAuthorizer

  @impl true
  def authorize_subscription(_principal_id, _topic) do
    {:ok, :authorized}
  end
end
