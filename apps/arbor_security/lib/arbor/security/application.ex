defmodule Arbor.Security.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Arbor.Security.Identity.Registry, []},
      {Arbor.Security.Identity.NonceCache, []},
      {Arbor.Security.SystemAuthority, []},
      {Arbor.Security.CapabilityStore, []}
    ]

    opts = [strategy: :one_for_one, name: Arbor.Security.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
