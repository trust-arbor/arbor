defmodule Arbor.AI.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Backend availability registry with ETS caching
      Arbor.AI.BackendRegistry,

      # Quota tracking for CLI backends
      Arbor.AI.QuotaTracker,

      # Session tracking for multi-turn conversations
      Arbor.AI.SessionRegistry
    ]

    opts = [strategy: :one_for_one, name: Arbor.AI.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
