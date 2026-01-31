defmodule Arbor.Memory.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Arbor.Memory.Registry},
      {Arbor.Memory.IndexSupervisor, []}
    ]

    opts = [strategy: :one_for_one, name: Arbor.Memory.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
