defmodule Arbor.Orchestrator.Handlers.WaitHandler do
  @moduledoc """
  Core handler for pipeline coordination and waiting.

  Canonical type: `wait`
  Aliases: `wait.human`

  Dispatches by `source` attribute:
    - `"human"` (default) — delegates to WaitHumanHandler
    - `"timer"` — waits for specified duration
    - `"signal"` — waits for a signal event

  ## Node Attributes

    - `source` — wait source: "human" (default), "timer", "signal"
    - `duration` — timer duration in milliseconds (for source="timer")
    - `signal_topic` — signal topic to wait for (for source="signal")
    - `timeout` — maximum wait time (for source="signal")

  For source="human", all WaitHumanHandler attributes are supported.
  """

  @behaviour Arbor.Orchestrator.Handlers.Handler

  alias Arbor.Orchestrator.Engine.{Outcome, RunAuthorization}
  alias Arbor.Orchestrator.Handlers.WaitHumanHandler

  import Arbor.Orchestrator.Handlers.Helpers

  @impl true
  def execute(node, context, graph, opts) do
    source = Map.get(node.attrs, "source", "human")

    with {:ok, [{slot, module}]} <- execution_delegates(node),
         :ok <-
           RunAuthorization.verify_execution_module(
             Keyword.get(opts, :run_authorization),
             node,
             slot,
             module
           ) do
      dispatch(source, module, node, context, graph, opts)
    else
      {:error, reason} ->
        %Outcome{
          status: :fail,
          failure_reason: "Wait delegate binding rejected for node #{node.id}: #{inspect(reason)}"
        }
    end
  end

  @impl true
  def idempotency, do: :side_effecting

  @doc false
  def execution_delegates(node) do
    source = Map.get(node.attrs, "source", "human")
    module = if source in ["timer", "signal"], do: nil, else: WaitHumanHandler
    {:ok, [{"wait:#{source}", module}]}
  end

  defp dispatch("timer", nil, node, _context, _graph, _opts), do: handle_timer(node)
  defp dispatch("signal", nil, node, _context, _graph, _opts), do: handle_signal(node)

  defp dispatch(_source, module, node, context, graph, opts),
    do: module.execute(node, context, graph, opts)

  defp handle_timer(node) do
    duration = parse_int(Map.get(node.attrs, "duration"), 1000)
    Process.sleep(duration)

    %Outcome{
      status: :success,
      notes: "Timer completed: #{duration}ms",
      context_updates: %{"wait.#{node.id}.duration" => duration}
    }
  end

  defp handle_signal(node) do
    topic = Map.get(node.attrs, "signal_topic", "default")
    timeout = parse_int(Map.get(node.attrs, "timeout"), 30_000)

    # Signal waiting is currently a placeholder — full implementation
    # requires integration with the signal bus subscription system
    %Outcome{
      status: :success,
      notes: "Signal wait placeholder: topic=#{topic}, timeout=#{timeout}ms",
      context_updates: %{
        "wait.#{node.id}.topic" => topic,
        "wait.#{node.id}.source" => "signal"
      }
    }
  end
end
