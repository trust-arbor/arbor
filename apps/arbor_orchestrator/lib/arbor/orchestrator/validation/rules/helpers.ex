defmodule Arbor.Orchestrator.Validation.Rules.Helpers do
  @moduledoc false

  alias Arbor.Orchestrator.Graph

  @spec find_start_nodes(Graph.t()) :: [Graph.Node.t()]
  def find_start_nodes(graph) do
    graph.nodes
    |> Map.values()
    |> Enum.filter(fn node ->
      Map.get(node.attrs, "shape") == "Mdiamond" or String.downcase(node.id) == "start"
    end)
  end

  @spec find_terminal_nodes(Graph.t()) :: [Graph.Node.t()]
  def find_terminal_nodes(graph) do
    graph.nodes
    |> Map.values()
    |> Enum.filter(fn node ->
      Map.get(node.attrs, "shape") == "Msquare" or String.downcase(node.id) in ["exit", "end"]
    end)
  end

  @spec truthy?(term()) :: boolean()
  def truthy?(true), do: true
  def truthy?("true"), do: true
  def truthy?(1), do: true
  def truthy?(_), do: false

  @spec dfs(Graph.t(), MapSet.t(), [String.t()]) :: MapSet.t()
  def dfs(_graph, visited, []), do: visited

  def dfs(graph, visited, [node_id | rest]) do
    if MapSet.member?(visited, node_id) do
      dfs(graph, visited, rest)
    else
      node = Map.get(graph.nodes, node_id)

      next_ids =
        (graph
         |> Graph.outgoing_edges(node_id)
         |> Enum.map(& &1.to)) ++
          implicit_targets(node)

      dfs(graph, MapSet.put(visited, node_id), rest ++ next_ids)
    end
  end

  @spec implicit_targets(Graph.Node.t() | nil) :: [String.t()]
  def implicit_targets(nil), do: []

  def implicit_targets(node) do
    [Map.get(node.attrs, "retry_target"), Map.get(node.attrs, "fallback_retry_target")]
    |> Enum.reject(&(&1 in [nil, ""]))
  end
end
