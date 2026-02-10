defmodule Arbor.Orchestrator.Graph do
  @moduledoc """
  Typed graph model for Attractor DOT pipelines.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          attrs: map(),
          nodes: %{String.t() => Arbor.Orchestrator.Graph.Node.t()},
          edges: [Arbor.Orchestrator.Graph.Edge.t()]
        }

  defstruct id: "Pipeline", attrs: %{}, nodes: %{}, edges: []

  @spec add_node(t(), Arbor.Orchestrator.Graph.Node.t()) :: t()
  def add_node(%__MODULE__{} = graph, %Arbor.Orchestrator.Graph.Node{} = node) do
    %{graph | nodes: Map.put(graph.nodes, node.id, node)}
  end

  @spec add_edge(t(), Arbor.Orchestrator.Graph.Edge.t()) :: t()
  def add_edge(%__MODULE__{} = graph, %Arbor.Orchestrator.Graph.Edge{} = edge) do
    %{graph | edges: graph.edges ++ [edge]}
  end

  @spec outgoing_edges(t(), String.t()) :: [Arbor.Orchestrator.Graph.Edge.t()]
  def outgoing_edges(%__MODULE__{} = graph, node_id) do
    Enum.filter(graph.edges, &(&1.from == node_id))
  end

  @spec incoming_edges(t(), String.t()) :: [Arbor.Orchestrator.Graph.Edge.t()]
  def incoming_edges(%__MODULE__{} = graph, node_id) do
    Enum.filter(graph.edges, &(&1.to == node_id))
  end
end
