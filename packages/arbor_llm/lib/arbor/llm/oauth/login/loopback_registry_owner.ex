defmodule Arbor.LLM.OAuth.Login.LoopbackRegistryOwner do
  @moduledoc false

  use GenServer

  @registry Arbor.LLM.OAuth.Login.LoopbackRegistry

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok)

  @impl true
  def init(:ok) do
    Process.flag(:trap_exit, true)

    case Registry.start_link(keys: :unique, name: @registry) do
      {:ok, registry} -> {:ok, registry}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_info({:EXIT, registry, _reason}, registry) do
    {:stop, {:registry_down, :closed}, registry}
  end

  def handle_info(_message, registry), do: {:noreply, registry}

  @impl true
  def terminate(_reason, registry) do
    if Process.alive?(registry), do: Process.exit(registry, :shutdown)
    :ok
  end
end
