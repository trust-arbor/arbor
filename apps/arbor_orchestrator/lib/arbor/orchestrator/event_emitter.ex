defmodule Arbor.Orchestrator.EventEmitter do
  @moduledoc """
  Registry-based event PubSub for pipeline execution.

  Subscribers receive `{:pipeline_event, event}` messages for matching
  pipeline runs. Subscribe with a specific pipeline ID or `:all`.

  ## Usage

      # Subscribe to all pipeline events
      EventEmitter.subscribe()

      # Subscribe to a specific run
      EventEmitter.subscribe("run-123")

      # In a GenServer/LiveView handle_info:
      def handle_info({:pipeline_event, %{type: :stage_completed} = event}, state) do
        ...
      end
  """

  @registry Arbor.Orchestrator.EventRegistry

  @doc """
  Subscribe the calling process to pipeline events.

  - `subscribe()` or `subscribe(:all)` — receive all events
  - `subscribe(pipeline_id)` — receive events for a specific run
  """
  @spec subscribe(term()) :: {:ok, pid()} | {:error, term()}
  def subscribe(pipeline_id \\ :all) do
    Registry.register(@registry, pipeline_id, [])
  end

  @doc """
  Unsubscribe the calling process from a specific pipeline ID.
  """
  @spec unsubscribe(term()) :: :ok
  def unsubscribe(pipeline_id \\ :all) do
    Registry.unregister(@registry, pipeline_id)
  end

  @doc """
  Emit an event to all subscribers of the given pipeline ID and `:all`.

  Also invokes the legacy `:on_event` callback if present in opts.
  """
  @spec emit(term(), map(), keyword()) :: :ok
  def emit(pipeline_id \\ :all, event, opts \\ []) do
    # Registry-based dispatch to pipeline-specific subscribers
    if pipeline_id != :all do
      Registry.dispatch(@registry, pipeline_id, fn entries ->
        for {pid, _value} <- entries, do: send(pid, {:pipeline_event, event})
      end)
    end

    # Always dispatch to :all subscribers
    Registry.dispatch(@registry, :all, fn entries ->
      for {pid, _value} <- entries, do: send(pid, {:pipeline_event, event})
    end)

    # Backward-compatible callback support
    case Keyword.get(opts, :on_event) do
      nil -> :ok
      callback when is_function(callback, 1) -> callback.(event)
    end

    :ok
  end
end
