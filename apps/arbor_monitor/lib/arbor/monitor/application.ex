defmodule Arbor.Monitor.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:arbor_monitor, :start_children, true) do
        [
          Arbor.Monitor.MetricsStore,
          Arbor.Monitor.Poller
        ]
      else
        []
      end

    opts = [strategy: :rest_for_one, name: Arbor.Monitor.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
