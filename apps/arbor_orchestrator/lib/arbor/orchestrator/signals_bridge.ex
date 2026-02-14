defmodule Arbor.Orchestrator.SignalsBridge do
  @moduledoc """
  Bridges orchestrator EventEmitter events to the Arbor Signals bus.

  Subscribes to all pipeline events via EventEmitter and re-emits them
  as signals under the :orchestrator category. This enables dashboard
  LiveView modules to subscribe to "orchestrator.*" for live pipeline updates.
  """

  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Subscribe to all pipeline events
    {:ok, _} = Arbor.Orchestrator.EventEmitter.subscribe(:all)
    {:ok, %{}}
  end

  @impl true
  def handle_info({:pipeline_event, %{type: type} = event}, state) do
    emit_signal(type, Map.drop(event, [:type]))
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp emit_signal(type, data) when is_atom(type) do
    # Runtime bridge: orchestrator (standalone) doesn't depend on arbor_signals
    if Code.ensure_loaded?(Arbor.Signals) do
      apply(Arbor.Signals, :emit, [:orchestrator, type, data])
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
