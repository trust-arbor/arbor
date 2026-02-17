defmodule Arbor.Orchestrator.GraphMutation do
  @moduledoc """
  Parses, validates, and applies mutation operations to a pipeline Graph.

  Mutations are JSON-encoded arrays of operations that modify the graph structure
  at runtime. Used by the `graph.adapt` handler for self-modifying pipelines.

  Supported operations:
    - `add_node`:    `{"op": "add_node", "id": "new_id", "attrs": {"type": "tool", ...}}`
    - `remove_node`: `{"op": "remove_node", "id": "node_id"}`
    - `modify_attrs`: `{"op": "modify_attrs", "id": "node_id", "attrs": {"prompt": "new"}}`
    - `add_edge`:    `{"op": "add_edge", "from": "a", "to": "b", "attrs": {"label": "..."}}`
    - `remove_edge`: `{"op": "remove_edge", "from": "a", "to": "b"}`

  Ported from homelab Attractor, adapted for arbor_orchestrator's Graph/Node/Edge structs.
  """

  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.{Edge, Node}

  @doc "Decodes a JSON string into a list of operation maps."
  @spec parse(String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def parse(json_string) do
    case Jason.decode(json_string) do
      {:ok, ops} when is_list(ops) ->
        case validate_keys(ops) do
          :ok -> {:ok, ops}
          {:error, _} = err -> err
        end

      {:ok, _} ->
        {:error, "mutations must be a JSON array"}

      {:error, %Jason.DecodeError{} = err} ->
        {:error, "JSON decode error: #{Exception.message(err)}"}
    end
  end

  @doc "Validates that all operations are safe to apply against the given graph and completed nodes."
  @spec validate([map()], Graph.t(), MapSet.t()) :: :ok | {:error, String.t()}
  def validate(operations, graph, completed_nodes) do
    # Pre-compute the final node set after all add/remove ops
    # so add_edge can reference nodes being added in the same batch
    projected_nodes = project_node_ids(operations, graph)

    Enum.reduce_while(operations, :ok, fn op, :ok ->
      case validate_op(op, graph, completed_nodes, projected_nodes) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  @doc "Applies validated operations sequentially to produce a new Graph."
  @spec apply_mutations([map()], Graph.t()) :: {:ok, Graph.t()} | {:error, String.t()}
  def apply_mutations(operations, graph) do
    result =
      Enum.reduce_while(operations, graph, fn op, acc_graph ->
        case apply_op(op, acc_graph) do
          {:ok, new_graph} -> {:cont, new_graph}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case result do
      {:error, _} = err ->
        err

      %Graph{} = new_graph ->
        version = Map.get(new_graph.attrs, "__mutation_version__", 0) + 1
        final = %{new_graph | attrs: Map.put(new_graph.attrs, "__mutation_version__", version)}
        {:ok, rebuild_adjacency(final)}
    end
  end

  # --- Projected node set for batch-aware validation ---

  defp project_node_ids(operations, graph) do
    initial = graph.nodes |> Map.keys() |> MapSet.new()

    Enum.reduce(operations, initial, fn
      %{"op" => "add_node", "id" => id}, acc -> MapSet.put(acc, id)
      %{"op" => "remove_node", "id" => id}, acc -> MapSet.delete(acc, id)
      _, acc -> acc
    end)
  end

  # --- Key validation ---

  defp validate_keys(ops) do
    Enum.reduce_while(ops, :ok, fn op, :ok ->
      case validate_required_keys(op) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp validate_required_keys(%{"op" => "add_node", "id" => id}) when is_binary(id), do: :ok
  defp validate_required_keys(%{"op" => "add_node"}), do: {:error, "add_node requires \"id\""}

  defp validate_required_keys(%{"op" => "remove_node", "id" => id}) when is_binary(id), do: :ok

  defp validate_required_keys(%{"op" => "remove_node"}),
    do: {:error, "remove_node requires \"id\""}

  defp validate_required_keys(%{"op" => "modify_attrs", "id" => id, "attrs" => attrs})
       when is_binary(id) and is_map(attrs),
       do: :ok

  defp validate_required_keys(%{"op" => "modify_attrs"}),
    do: {:error, "modify_attrs requires \"id\" and \"attrs\""}

  defp validate_required_keys(%{"op" => "add_edge", "from" => from, "to" => to})
       when is_binary(from) and is_binary(to),
       do: :ok

  defp validate_required_keys(%{"op" => "add_edge"}),
    do: {:error, "add_edge requires \"from\" and \"to\""}

  defp validate_required_keys(%{"op" => "remove_edge", "from" => from, "to" => to})
       when is_binary(from) and is_binary(to),
       do: :ok

  defp validate_required_keys(%{"op" => "remove_edge"}),
    do: {:error, "remove_edge requires \"from\" and \"to\""}

  defp validate_required_keys(%{"op" => op}) when is_binary(op),
    do: {:error, "unknown operation: #{op}"}

  defp validate_required_keys(_), do: {:error, "operation missing \"op\" key"}

  # --- Single operation validation ---

  defp validate_op(%{"op" => "add_node", "id" => id}, graph, _completed, _projected) do
    if Map.has_key?(graph.nodes, id) do
      {:error, "cannot add node \"#{id}\": already exists"}
    else
      :ok
    end
  end

  defp validate_op(%{"op" => "remove_node", "id" => id}, graph, completed, _projected) do
    case Map.get(graph.nodes, id) do
      nil ->
        {:error, "cannot remove node \"#{id}\": not found"}

      node ->
        cond do
          Map.get(node.attrs, "shape") == "Mdiamond" ->
            {:error, "cannot remove start node \"#{id}\""}

          Map.get(node.attrs, "shape") == "Msquare" ->
            {:error, "cannot remove exit node \"#{id}\""}

          MapSet.member?(completed, id) ->
            {:error, "cannot remove node \"#{id}\": already completed"}

          true ->
            :ok
        end
    end
  end

  defp validate_op(%{"op" => "modify_attrs", "id" => id}, graph, completed, _projected) do
    cond do
      not Map.has_key?(graph.nodes, id) ->
        {:error, "cannot modify node \"#{id}\": not found"}

      MapSet.member?(completed, id) ->
        {:error, "cannot modify node \"#{id}\": already completed"}

      true ->
        :ok
    end
  end

  defp validate_op(
         %{"op" => "add_edge", "from" => from, "to" => to},
         _graph,
         _completed,
         projected
       ) do
    cond do
      not MapSet.member?(projected, from) ->
        {:error, "cannot add edge: source node \"#{from}\" not found"}

      not MapSet.member?(projected, to) ->
        {:error, "cannot add edge: target node \"#{to}\" not found"}

      true ->
        :ok
    end
  end

  defp validate_op(
         %{"op" => "remove_edge", "from" => from, "to" => to},
         graph,
         _completed,
         _projected
       ) do
    edge_exists? =
      Enum.any?(graph.edges, fn edge -> edge.from == from and edge.to == to end)

    if edge_exists? do
      :ok
    else
      {:error, "cannot remove edge from \"#{from}\" to \"#{to}\": not found"}
    end
  end

  defp validate_op(%{"op" => op}, _graph, _completed, _projected) do
    {:error, "unknown operation: #{op}"}
  end

  # --- Single operation application ---

  defp apply_op(%{"op" => "add_node", "id" => id} = op, graph) do
    attrs = Map.get(op, "attrs", %{})
    node = %Node{id: id, attrs: attrs}
    {:ok, %{graph | nodes: Map.put(graph.nodes, id, node)}}
  end

  defp apply_op(%{"op" => "remove_node", "id" => id}, graph) do
    new_nodes = Map.delete(graph.nodes, id)

    new_edges =
      Enum.reject(graph.edges, fn edge -> edge.from == id or edge.to == id end)

    {:ok, %{graph | nodes: new_nodes, edges: new_edges}}
  end

  defp apply_op(%{"op" => "modify_attrs", "id" => id, "attrs" => new_attrs}, graph) do
    case Map.get(graph.nodes, id) do
      nil ->
        {:error, "cannot modify node \"#{id}\": not found"}

      node ->
        merged_attrs = Map.merge(node.attrs, new_attrs)
        updated_node = %{node | attrs: merged_attrs}
        {:ok, %{graph | nodes: Map.put(graph.nodes, id, updated_node)}}
    end
  end

  defp apply_op(%{"op" => "add_edge", "from" => from, "to" => to} = op, graph) do
    attrs = Map.get(op, "attrs", %{})
    edge = %Edge{from: from, to: to, attrs: attrs}
    {:ok, %{graph | edges: graph.edges ++ [edge]}}
  end

  defp apply_op(%{"op" => "remove_edge", "from" => from, "to" => to}, graph) do
    new_edges =
      Enum.reject(graph.edges, fn edge -> edge.from == from and edge.to == to end)

    {:ok, %{graph | edges: new_edges}}
  end

  defp apply_op(%{"op" => op}, _graph) do
    {:error, "unknown operation: #{op}"}
  end

  # --- Rebuild adjacency indexes after mutation ---

  defp rebuild_adjacency(%Graph{edges: edges} = graph) do
    adjacency =
      Enum.reduce(edges, %{}, fn edge, acc ->
        Map.update(acc, edge.from, [edge], &(&1 ++ [edge]))
      end)

    reverse_adjacency =
      Enum.reduce(edges, %{}, fn edge, acc ->
        Map.update(acc, edge.to, [edge], &(&1 ++ [edge]))
      end)

    %{graph | adjacency: adjacency, reverse_adjacency: reverse_adjacency}
  end
end
