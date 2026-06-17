defmodule Arbor.Orchestrator.SignalsBridge do
  @moduledoc """
  Bridges orchestrator EventEmitter events to the Arbor Signals bus.

  Subscribes to all pipeline events via EventEmitter and re-emits them
  as signals under the :orchestrator category. This enables dashboard
  LiveView modules to subscribe to "orchestrator.*" for live pipeline updates.
  """

  use GenServer

  alias Arbor.Orchestrator.EventEmitter

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Subscribe to all pipeline events
    {:ok, _} = EventEmitter.subscribe(:all)
    {:ok, %{}}
  end

  @impl true
  def handle_info({:pipeline_event, %{type: type} = event}, state) do
    emit_signal(type, Map.drop(event, [:type]))
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp emit_signal(type, data) when is_atom(type) do
    # arbor_signals is a hard dep; the rescue/catch guards only against the
    # signal bus process not being alive.
    Arbor.Signals.emit(:orchestrator, type, data)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
