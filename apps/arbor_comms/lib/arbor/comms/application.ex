defmodule Arbor.Comms.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Arbor.Comms.Supervisor
    ]

    opts = [strategy: :one_for_one, name: Arbor.Comms.AppSupervisor]
    Supervisor.start_link(children, opts)
  end
end
