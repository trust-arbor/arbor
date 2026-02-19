defmodule Arbor.Orchestrator.Middleware.SignalEmit do
  @moduledoc """
  Mandatory middleware that emits execution signals after node completion.

  Bridges to `Arbor.Signals.Bus` when available. Emits signals for state
  changes only — read-only nodes are skipped to avoid feedback loops.

  ## Token Assigns

    - `:skip_signal_emit` — set to true to bypass this middleware
    - `:signal_topic` — custom signal topic (default: "orchestrator.node")
  """

  use Arbor.Orchestrator.Middleware

  # Read-only handler types don't emit signals (avoids feedback loops)
  @read_only_types ~w(read gate start exit branch)

  @impl true
  def after_node(token) do
    cond do
      Map.get(token.assigns, :skip_signal_emit, false) ->
        token

      not signal_bus_available?() ->
        token

      read_only_node?(token) ->
        token

      true ->
        emit_signal(token)
    end
  end

  defp emit_signal(token) do
    topic = Map.get(token.assigns, :signal_topic, "orchestrator.node")
    node_type = Map.get(token.node.attrs, "type", "unknown")
    status = if token.outcome, do: token.outcome.status, else: :unknown

    signal_data = %{
      node_id: token.node.id,
      node_type: node_type,
      status: status,
      graph_id: if(token.graph, do: Map.get(token.graph.attrs, "id")),
      timestamp: System.system_time(:millisecond)
    }

    try do
      apply(Arbor.Signals.Bus, :emit, [topic, signal_data])
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end

    token
  end

  defp read_only_node?(token) do
    node_type = Map.get(token.node.attrs, "type", "")
    canonical = Arbor.Orchestrator.Stdlib.Aliases.canonical_type(node_type)
    canonical in @read_only_types
  end

  defp signal_bus_available? do
    Code.ensure_loaded?(Arbor.Signals.Bus) and
      function_exported?(Arbor.Signals.Bus, :emit, 2)
  end
end
