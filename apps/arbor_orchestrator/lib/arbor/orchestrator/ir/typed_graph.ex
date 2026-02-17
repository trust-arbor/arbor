defmodule Arbor.Orchestrator.IR.TypedGraph do
  @moduledoc """
  A typed intermediate representation of a pipeline graph.

  Created by compiling an untyped `Graph.t()` via `IR.Compiler.compile/1`.
  Contains resolved typed nodes/edges and computed aggregates for
  capability analysis, taint tracking, and resource bounds verification.
  """

  alias Arbor.Orchestrator.IR.{TypedEdge, TypedNode}

  @type data_class :: :public | :internal | :sensitive | :secret

  @type t :: %__MODULE__{
          id: String.t(),
          attrs: map(),
          nodes: %{String.t() => TypedNode.t()},
          edges: [TypedEdge.t()],
          adjacency: %{String.t() => [TypedEdge.t()]},
          reverse_adjacency: %{String.t() => [TypedEdge.t()]},
          capabilities_required: MapSet.t(String.t()),
          handler_types: %{String.t() => String.t()},
          max_data_classification: data_class()
        }

  defstruct id: "Pipeline",
            attrs: %{},
            nodes: %{},
            edges: [],
            adjacency: %{},
            reverse_adjacency: %{},
            capabilities_required: MapSet.new(),
            handler_types: %{},
            max_data_classification: :public

  @doc "Returns all node IDs that require the given capability."
  @spec nodes_requiring(t(), String.t()) :: [String.t()]
  def nodes_requiring(%__MODULE__{nodes: nodes}, capability) do
    nodes
    |> Enum.filter(fn {_id, node} -> TypedNode.requires_capability?(node, capability) end)
    |> Enum.map(fn {id, _node} -> id end)
  end

  @doc "Returns all node IDs with side effects."
  @spec side_effecting_nodes(t()) :: [String.t()]
  def side_effecting_nodes(%__MODULE__{nodes: nodes}) do
    nodes
    |> Enum.filter(fn {_id, node} -> TypedNode.side_effecting?(node) end)
    |> Enum.map(fn {id, _node} -> id end)
  end

  @doc "Returns outgoing typed edges for a node."
  @spec outgoing_edges(t(), String.t()) :: [TypedEdge.t()]
  def outgoing_edges(%__MODULE__{adjacency: adj}, node_id) do
    Map.get(adj, node_id, [])
  end

  @doc "Returns incoming typed edges for a node."
  @spec incoming_edges(t(), String.t()) :: [TypedEdge.t()]
  def incoming_edges(%__MODULE__{reverse_adjacency: rev}, node_id) do
    Map.get(rev, node_id, [])
  end

  @doc "Returns true if any node has schema validation errors."
  @spec has_schema_errors?(t()) :: boolean()
  def has_schema_errors?(%__MODULE__{nodes: nodes}) do
    Enum.any?(nodes, fn {_id, node} -> TypedNode.has_errors?(node) end)
  end

  @classification_order %{public: 0, internal: 1, sensitive: 2, secret: 3}

  @doc "Returns the higher of two data classifications."
  @spec max_classification(data_class(), data_class()) :: data_class()
  def max_classification(a, b) do
    if Map.get(@classification_order, a, 0) >= Map.get(@classification_order, b, 0),
      do: a,
      else: b
  end
end
