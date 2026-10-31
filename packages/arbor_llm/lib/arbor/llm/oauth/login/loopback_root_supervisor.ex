defmodule Arbor.LLM.OAuth.Login.LoopbackRootSupervisor do
  @moduledoc false

  use Supervisor

  def start_link(_opts), do: Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    children = [
      Arbor.LLM.OAuth.Login.LoopbackRegistryOwner,
      Arbor.LLM.OAuth.Login.LoopbackSupervisor
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
