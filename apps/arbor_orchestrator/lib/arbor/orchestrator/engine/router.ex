defmodule Arbor.Orchestrator.Engine.Router do
  @moduledoc """
  Edge selection and navigation logic for the pipeline engine.

  Handles routing decisions: next-step selection, fan-in/fan-out coordination,
  failure routing, goal gate retry resolution, and edge condition matching.
  """

  alias Arbor.Orchestrator.Engine.{Condition, Outcome}
  alias Arbor.Orchestrator.Graph

  import Arbor.Orchestrator.Handlers.Helpers

  # --- Next step selection ---

  @doc false
  def select_next_step(node, outcome, context, graph) do
    if outcome.status == :fail do
      select_fail_step(node, outcome, context, graph)
    else
      case select_handler_suggested_target(node, outcome, graph) do
        {:node_id, _target} = routed ->
          routed

        nil ->
          case select_next_edge(node, outcome, context, graph) do
            nil -> nil
            edge -> {:edge, edge}
          end
      end
    end
  end

  # Some virtual handlers (for example parallel fan-out) need to jump to an
  # inferred target that is not a direct outgoing edge from the current node.
  # Keep this path separate so ordinary edge routing still follows spec section 3.3.
  defp select_handler_suggested_target(node, %Outcome{suggested_next_ids: ids}, graph) do
    outgoing_target_ids =
      graph
      |> Graph.outgoing_edges(node.id)
      |> Enum.map(& &1.to)
      |> MapSet.new()

    ids
    |> Enum.find(fn target ->
      valid_target?(graph, target) and not MapSet.member?(outgoing_target_ids, target)
    end)
    |> case do
      nil -> nil
      target -> {:node_id, target}
    end
  end

  # Failure routing order (spec 3.7):
  # 1) fail edge condition outcome=fail
  # 2) node retry_target
  # 3) node fallback_retry_target
  # 4) terminate
  defp select_fail_step(node, outcome, context, graph) do
    edges = Graph.outgoing_edges(graph, node.id)

    fail_edges =
      Enum.filter(edges, fn edge ->
        case Map.get(edge.attrs, "condition", "") do
          cond when is_binary(cond) and cond != "" -> Condition.eval(cond, outcome, context)
          _ -> false
        end
      end)

    cond do
      fail_edges != [] ->
        {:edge, best_by_weight_then_lexical(fail_edges)}

      valid_target?(graph, Map.get(node.attrs, "retry_target")) ->
        {:node_id, Map.get(node.attrs, "retry_target")}

      valid_target?(graph, Map.get(node.attrs, "fallback_retry_target")) ->
        {:node_id, Map.get(node.attrs, "fallback_retry_target")}

      true ->
        nil
    end
  end

  defp select_next_edge(node, outcome, context, graph) do
    edges = Graph.outgoing_edges(graph, node.id)

    cond do
      edges == [] ->
        nil

      true ->
        condition_matched = Enum.filter(edges, &edge_condition_matches?(&1, outcome, context))
        unconditional = Enum.filter(edges, &(Map.get(&1.attrs, "condition", "") in ["", nil]))

        cond do
          condition_matched != [] ->
            best_by_weight_then_lexical(condition_matched)

          outcome.preferred_label not in [nil, ""] ->
            Enum.find(unconditional, fn edge ->
              normalize_label(Map.get(edge.attrs, "label", "")) ==
                normalize_label(outcome.preferred_label || "")
            end) || best_by_weight_then_lexical(unconditional_or_all(unconditional, edges))

          outcome.suggested_next_ids != [] ->
            Enum.find_value(outcome.suggested_next_ids, fn suggested_id ->
              Enum.find(unconditional, fn edge -> edge.to == suggested_id end)
            end) || best_by_weight_then_lexical(unconditional_or_all(unconditional, edges))

          true ->
            best_by_weight_then_lexical(unconditional_or_all(unconditional, edges))
        end
    end
  end

  defp unconditional_or_all([], edges), do: edges
  defp unconditional_or_all(unconditional, _edges), do: unconditional

  defp edge_condition_matches?(edge, outcome, context) do
    condition = Map.get(edge.attrs, "condition", "")

    if condition in [nil, ""] do
      false
    else
      Condition.eval(condition, outcome, context)
    end
  end

  # --- Goal gate retry resolution ---

  @doc false
  def resolve_goal_gate_retry_target(graph, outcomes) do
    failed_gate =
      outcomes
      |> Enum.find_value(fn {node_id, outcome} ->
        node = Map.get(graph.nodes, node_id)

        if node != nil and truthy?(Map.get(node.attrs, "goal_gate", false)) and
             outcome.status not in [:success, :partial_success] do
          node
        else
          nil
        end
      end)

    if failed_gate == nil do
      {:ok, nil}
    else
      targets = [
        Map.get(failed_gate.attrs, "retry_target"),
        Map.get(failed_gate.attrs, "fallback_retry_target"),
        Map.get(graph.attrs, "retry_target"),
        Map.get(graph.attrs, "fallback_retry_target")
      ]

      case Enum.find(targets, &valid_target?(graph, &1)) do
        nil -> {:error, :goal_gate_unsatisfied_no_retry_target}
        target -> {:ok, target}
      end
    end
  end

  # --- Fan-in/fan-out helpers ---

  # Returns sibling fan-out edges (unconditional parallel branches) from a node.
  # Fan-out is ON by default for unconditional edges -- multiple outgoing edges
  # without conditions are treated as parallel branches automatically.
  # Set fan_out="false" to force single-path selection (decision nodes).
  @doc false
  def collect_fan_out_siblings(node, outcome, _context, graph) do
    fan_out_disabled = Map.get(node.attrs, "fan_out") == "false"

    if fan_out_disabled or outcome.status == :fail do
      []
    else
      edges = Graph.outgoing_edges(graph, node.id)
      Enum.filter(edges, &(Map.get(&1.attrs, "condition", "") in ["", nil]))
    end
  end

  # Check if all predecessor nodes (incoming edges) are in the completed list.
  @doc false
  def all_predecessors_complete?(graph, node_id, completed) do
    graph
    |> Graph.incoming_edges(node_id)
    |> Enum.all?(fn edge -> edge.from in completed end)
  end

  # Find the first ready node from candidates where all predecessors are complete.
  # Returns {node_id, edge, remaining_candidates} or nil.
  @doc false
  def find_next_ready(candidates, graph, completed) do
    {ready, not_ready} =
      Enum.split_with(candidates, fn {id, _edge} ->
        id not in completed and all_predecessors_complete?(graph, id, completed)
      end)

    case ready do
      [{next_id, next_edge} | rest] ->
        {next_id, next_edge, rest ++ not_ready}

      [] ->
        nil
    end
  end

  # Merge new targets into pending, avoiding duplicates by node_id.
  @doc false
  def merge_pending(new_targets, existing_pending) do
    existing_ids = MapSet.new(existing_pending, fn {id, _} -> id end)

    new_unique =
      Enum.reject(new_targets, fn {id, _} -> MapSet.member?(existing_ids, id) end)

    existing_pending ++ new_unique
  end

  # --- Helpers ---

  @doc false
  def best_by_weight_then_lexical(edges) do
    Enum.sort_by(edges, fn edge -> {-parse_int(Map.get(edge.attrs, "weight", 0), 0), edge.to} end)
    |> List.first()
  end

  @doc false
  def normalize_label(label) do
    label
    |> to_string()
    |> String.downcase()
    |> String.trim()
    |> String.replace(~r/^\[[a-z0-9]\]\s*/i, "")
    |> String.replace(~r/^[a-z0-9]\)\s*/i, "")
    |> String.replace(~r/^[a-z0-9]\s*-\s*/i, "")
  end

  @doc false
  def valid_target?(_graph, target) when target in [nil, ""], do: false
  def valid_target?(graph, target) when is_binary(target), do: Map.has_key?(graph.nodes, target)
  def valid_target?(_graph, _target), do: false

  @doc false
  def terminal?(node) do
    Map.get(node.attrs, "shape") == "Msquare" or String.downcase(node.id) in ["exit", "end"]
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(1), do: true
  defp truthy?(_), do: false
end
