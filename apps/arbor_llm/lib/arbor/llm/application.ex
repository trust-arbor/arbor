defmodule Arbor.LLM.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Arbor.LLM.OAuth.Login.PendingStore,
      Arbor.LLM.OAuth.RecoveryProofStore,
      {Registry, keys: :unique, name: Arbor.LLM.OAuth.Login.LoopbackRegistry},
      {Task.Supervisor, name: Arbor.LLM.OAuth.Login.LoopbackTaskSupervisor},
      Arbor.LLM.OAuth.Login.LoopbackSupervisor
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Arbor.LLM.Supervisor)
  end
end
