defmodule Arbor.KernelRuntime.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      %{
        id: Arbor.Common.Application,
        start: {Arbor.Common.Application, :start, [:normal, []]},
        type: :supervisor
      },
      %{
        id: Arbor.Signals.Application,
        start: {Arbor.Signals.Application, :start, [:normal, []]},
        type: :supervisor
      },
      %{
        id: Arbor.Monitor.Application,
        start: {Arbor.Monitor.Application, :start, [:normal, []]},
        type: :supervisor
      }
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Arbor.KernelRuntime.Supervisor)
  end
end
