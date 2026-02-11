defmodule Arbor.Orchestrator.Graph do
  @moduledoc """
  Typed graph model for Attractor DOT pipelines.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          attrs: map(),
          nodes: %{String.t() => Arbor.Orchestrator.Graph.Node.t()},
          edges: [Arbor.Orchestrator.Graph.Edge.t()],
          adjacency: %{String.t() => [Arbor.Orchestrator.Graph.Edge.t()]},
          reverse_adjacency: %{String.t() => [Arbor.Orchestrator.Graph.Edge.t()]},
          subgraphs: [map()],
          node_defaults: map(),
          edge_defaults: map()
        }

  defstruct id: "Pipeline",
            attrs: %{},
            nodes: %{},
            edges: [],
            adjacency: %{},
            reverse_adjacency: %{},
            subgraphs: [],
            node_defaults: %{},
            edge_defaults: %{}

  @spec add_node(t(), Arbor.Orchestrator.Graph.Node.t()) :: t()
  def add_node(%__MODULE__{} = graph, %Arbor.Orchestrator.Graph.Node{} = node) do
    %{graph | nodes: Map.put(graph.nodes, node.id, node)}
  end

  @spec add_edge(t(), Arbor.Orchestrator.Graph.Edge.t()) :: t()
  def add_edge(%__MODULE__{} = graph, %Arbor.Orchestrator.Graph.Edge{} = edge) do
    %{
      graph
      | edges: [edge | graph.edges],
        adjacency: Map.update(graph.adjacency, edge.from, [edge], &[edge | &1]),
        reverse_adjacency: Map.update(graph.reverse_adjacency, edge.to, [edge], &[edge | &1])
    }
  end

  @spec outgoing_edges(t(), String.t()) :: [Arbor.Orchestrator.Graph.Edge.t()]
  def outgoing_edges(%__MODULE__{adjacency: adj}, node_id) when map_size(adj) > 0 do
    adj |> Map.get(node_id, []) |> Enum.reverse()
  end

  def outgoing_edges(%__MODULE__{} = graph, node_id) do
    Enum.filter(graph.edges, &(&1.from == node_id))
  end

  @spec incoming_edges(t(), String.t()) :: [Arbor.Orchestrator.Graph.Edge.t()]
  def incoming_edges(%__MODULE__{reverse_adjacency: rev}, node_id)
      when map_size(rev) > 0 do
    rev |> Map.get(node_id, []) |> Enum.reverse()
  end

  def incoming_edges(%__MODULE__{} = graph, node_id) do
    Enum.filter(graph.edges, &(&1.to == node_id))
  end

  @doc "Returns the first start node (shape=Mdiamond or id=start), or nil."
  @spec find_start_node(t()) :: Arbor.Orchestrator.Graph.Node.t() | nil
  def find_start_node(%__MODULE__{nodes: nodes}) do
    nodes
    |> Map.values()
    |> Enum.find(fn node ->
      node.attrs["shape"] == "Mdiamond" or node.id == "start"
    end)
  end

  @doc "Returns all exit nodes (shape=Msquare)."
  @spec find_exit_nodes(t()) :: [Arbor.Orchestrator.Graph.Node.t()]
  def find_exit_nodes(%__MODULE__{nodes: nodes}) do
    nodes
    |> Map.values()
    |> Enum.filter(fn node -> node.attrs["shape"] == "Msquare" end)
  end

  @doc "Returns true if the given node is an exit node."
  @spec terminal?(t(), Arbor.Orchestrator.Graph.Node.t()) :: boolean()
  def terminal?(%__MODULE__{} = graph, %Arbor.Orchestrator.Graph.Node{} = node) do
    node in find_exit_nodes(graph)
  end

  @doc "Returns the graph-level goal attribute."
  @spec goal(t()) :: String.t() | nil
  def goal(%__MODULE__{attrs: attrs}), do: attrs["goal"]

  @doc "Returns the graph-level label attribute."
  @spec label(t()) :: String.t() | nil
  def label(%__MODULE__{attrs: attrs}), do: attrs["label"]
end
