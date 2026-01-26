defmodule Arbor.Sandbox.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Arbor.Sandbox.Registry
    ]

    opts = [strategy: :one_for_one, name: Arbor.Sandbox.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
