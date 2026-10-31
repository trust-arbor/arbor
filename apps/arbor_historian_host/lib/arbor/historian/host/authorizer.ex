defmodule Arbor.Historian.Host.Authorizer do
  @moduledoc false
  @behaviour Arbor.Historian.Contracts.Authorizer
  @impl true
  def authorize(principal, resource, action, opts),
    do: Arbor.Security.authorize(principal, resource, action, opts)

  @impl true
  def authorize_self_scoped(principal, resource, owner, prefix, action, opts),
    do: Arbor.Security.authorize_self_scoped(principal, resource, owner, prefix, action, opts)
end
