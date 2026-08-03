defmodule Arbor.Voice.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Arbor.Voice.Registry},
      Arbor.Voice.ResourceCleanupTaskSupervisor,
      Arbor.Voice.ResourceSupervisor,
      Arbor.Voice.SessionSupervisor
    ]

    opts = [strategy: :one_for_one, name: Arbor.Voice.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
