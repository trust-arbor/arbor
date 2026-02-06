defmodule Arbor.Demo.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:arbor_demo, :start_children, true) do
        [
          {Arbor.Demo.Timing, []},
          {Arbor.Demo.Supervisor, []},
          {Arbor.Demo.FaultInjector, []},
          {Arbor.Demo.Orchestrator, []}
        ]
      else
        []
      end

    opts = [strategy: :rest_for_one, name: Arbor.Demo.AppSupervisor]
    Supervisor.start_link(children, opts)
  end
end
