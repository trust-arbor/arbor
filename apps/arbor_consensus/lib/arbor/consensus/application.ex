defmodule Arbor.Consensus.Application do
  @moduledoc """
  Supervisor for the consensus system.

  Starts the EventStore, Coordinator, EvaluatorAgent Registry, and
  EvaluatorAgent Supervisor under supervision.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:arbor_consensus, :start_children, true) do
        [
          Arbor.Consensus.EventStore,
          # Registry for EvaluatorAgent name lookups
          {Registry, keys: :unique, name: Arbor.Consensus.EvaluatorAgent.Registry},
          # DynamicSupervisor for persistent EvaluatorAgents
          Arbor.Consensus.EvaluatorAgent.Supervisor,
          # Coordinator starts after agents are available
          Arbor.Consensus.Coordinator
        ]
      else
        []
      end

    opts = [strategy: :one_for_one, name: Arbor.Consensus.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
