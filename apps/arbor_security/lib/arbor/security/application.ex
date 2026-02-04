defmodule Arbor.Security.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:arbor_security, :start_children, true) do
        [
          {Arbor.Security.Identity.Registry, []},
          {Arbor.Security.Identity.NonceCache, []},
          {Arbor.Security.SystemAuthority, []},
          {Arbor.Security.Constraint.RateLimiter, []},
          {Arbor.Security.CapabilityStore, []},
          {Arbor.Security.Reflex.Registry, []}
        ]
      else
        []
      end

    opts = [strategy: :one_for_one, name: Arbor.Security.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
