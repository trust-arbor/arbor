defmodule Arbor.Consensus.Application do
  @moduledoc """
  Supervisor for the consensus system.

  Starts the EventStore and Coordinator under supervision.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Arbor.Consensus.EventStore,
      Arbor.Consensus.Coordinator
    ]

    opts = [strategy: :one_for_one, name: Arbor.Consensus.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
