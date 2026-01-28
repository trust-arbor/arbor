defmodule Arbor.Historian.Application do
  @moduledoc """
  Supervisor for the Historian subsystem.

  Starts:
  1. Persistence.EventLog.ETS - Unified event storage (replaces Historian.EventLog.ETS)
  2. StreamRegistry - Tracks stream metadata
  3. Collector - Subscribes to signals Bus and persists events
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Arbor.Persistence.EventLog.ETS, name: Arbor.Historian.EventLog.ETS},
      {Arbor.Historian.StreamRegistry, name: Arbor.Historian.StreamRegistry},
      {Arbor.Historian.Collector, []}
    ]

    opts = [strategy: :one_for_one, name: Arbor.Historian.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
