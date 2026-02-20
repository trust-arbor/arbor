defmodule Arbor.Orchestrator.IR.Compiler do
  @moduledoc """
  Compiles an untyped `Graph.t()` into an enriched `Graph.t()`.

  The compilation step enriches the graph in-place:
  1. Resolve each node's handler type and module
  2. Validate node attrs against handler schema
  3. Extract capabilities, data classifications, resource bounds
  4. Parse edge conditions into typed AST
  5. Compute graph-level aggregates (total capabilities, max classification)
  6. Rebuild adjacency maps with enriched edges

  Design: generic attrs at parse → enriched Graph at compile → validate on compiled Graph → execute
  """

  alias Arbor.Orchestrator.Dot.Duration
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.{Edge, Node}
  alias Arbor.Orchestrator.Handlers.{Handler, Registry}
  alias Arbor.Orchestrator.IR.HandlerSchema

  @doc "Compile an untyped graph into an enriched graph with typed IR fields."
  @spec compile(Graph.t()) :: {:ok, Graph.t()} | {:error, term()}
  def compile(%Graph{} = graph) do
    enriched_nodes =
      graph.nodes
      |> Enum.map(fn {id, node} -> {id, compile_node(node)} end)
      |> Map.new()

    enriched_edges = Enum.map(graph.edges, &compile_edge(&1, enriched_nodes))

    adjacency = build_adjacency(enriched_edges, :from)
    reverse_adjacency = build_adjacency(enriched_edges, :to)

    capabilities = aggregate_capabilities(enriched_nodes)

    handler_types =
      Map.new(enriched_nodes, fn {id, node} ->
        {id, Registry.node_type(node)}
      end)

    max_class = compute_max_classification(enriched_nodes)

    enriched_graph = %Graph{
      graph
      | nodes: enriched_nodes,
        edges: enriched_edges,
        adjacency: adjacency,
        reverse_adjacency: reverse_adjacency,
        compiled: true,
        capabilities_required: capabilities,
        handler_types: handler_types,
        max_data_classification: max_class
    }

    {:ok, enriched_graph}
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc "Compile, raising on error."
  @spec compile!(Graph.t()) :: Graph.t()
  def compile!(%Graph{} = graph) do
    case compile(graph) do
      {:ok, enriched} -> enriched
      {:error, reason} -> raise "IR compilation failed: #{reason}"
    end
  end

  # --- Node compilation ---

  defp compile_node(%Node{} = node) do
    handler_type = Registry.node_type(node)

    if handler_type == "adapt" do
      compile_adapt_node(node, handler_type)
    else
      compile_standard_node(node, handler_type)
    end
  end

  # Adapt nodes get pessimistic (maximally restrictive) enrichment.
  # They can self-modify pipeline topology at runtime, so we treat them
  # as side-effecting, restricted, and requiring graph_mutation capability.
  defp compile_adapt_node(%Node{} = node, handler_type) do
    handler_module = resolve_handler_module(node)
    schema = HandlerSchema.for_type(handler_type)
    schema_errors = HandlerSchema.validate_attrs(handler_type, node.attrs)

    %Node{
      node
      | handler_module: handler_module,
        handler_schema: schema,
        capabilities_required: ["graph_mutation"],
        data_classification: :secret,
        idempotency: :side_effecting,
        schema_errors: schema_errors
    }
  end

  defp compile_standard_node(%Node{} = node, handler_type) do
    {handler_module, %Node{} = prepared_node} = resolve_handler_with_attrs(node)
    schema = HandlerSchema.for_type(handler_type)
    schema_errors = HandlerSchema.validate_attrs(handler_type, prepared_node.attrs)
    idempotency = Handler.idempotency_of(handler_module)
    data_class = resolve_data_classification(prepared_node, schema)
    capabilities = resolve_capabilities(prepared_node, schema)
    _resource_bounds = extract_resource_bounds(prepared_node)

    %Node{
      prepared_node
      | handler_module: handler_module,
        handler_schema: schema,
        capabilities_required: capabilities,
        data_classification: data_class,
        idempotency: idempotency,
        schema_errors: schema_errors
    }
  end

  # Use resolve_with_attrs to get BOTH the handler module AND alias-injected attrs.
  # This ensures compiled nodes carry the same attrs they'd get at runtime.
  defp resolve_handler_with_attrs(%Node{} = node) do
    Registry.resolve_with_attrs(node)
  end

  defp resolve_handler_module(%Node{} = node) do
    Registry.resolve(node)
  end

  defp resolve_data_classification(%Node{} = node, %HandlerSchema{} = schema) do
    case Map.get(node.attrs, "data_class") do
      nil -> schema.default_classification
      "public" -> :public
      "internal" -> :internal
      "sensitive" -> :sensitive
      "secret" -> :secret
      _ -> schema.default_classification
    end
  end

  defp resolve_capabilities(%Node{} = node, %HandlerSchema{} = schema) do
    explicit = parse_capabilities_attr(Map.get(node.attrs, "capabilities"))
    schema.capabilities ++ explicit
  end

  defp parse_capabilities_attr(nil), do: []
  defp parse_capabilities_attr(""), do: []

  defp parse_capabilities_attr(caps) when is_binary(caps) do
    caps |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  defp parse_capabilities_attr(_), do: []

  defp extract_resource_bounds(%Node{attrs: attrs}) do
    %{
      max_retries: parse_int(Map.get(attrs, "max_retries")),
      timeout_ms: Duration.parse(Map.get(attrs, "timeout")),
      max_tokens: parse_int(Map.get(attrs, "max_tokens"))
    }
  end

  defp parse_int(nil), do: nil
  defp parse_int(n) when is_integer(n), do: n

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_int(_), do: nil

  # --- Edge compilation ---

  defp compile_edge(%Edge{} = edge, enriched_nodes) do
    parsed = Edge.parse_condition(Map.get(edge.attrs, "condition"))
    source_class = get_node_classification(enriched_nodes, edge.from)
    target_class = get_node_classification(enriched_nodes, edge.to)

    %Edge{
      edge
      | parsed_condition: parsed,
        source_classification: source_class,
        target_classification: target_class
    }
  end

  defp get_node_classification(enriched_nodes, node_id) do
    case Map.get(enriched_nodes, node_id) do
      nil -> :public
      node -> node.data_classification
    end
  end

  # --- Aggregation ---

  # Use group_by to preserve edge ordering from the parser.
  # The parser stores edges in reverse-DOT order (prepend on insert),
  # and outgoing_edges/2 reverses to recover DOT order. We must maintain
  # that same ordering — group_by preserves iteration order within groups.
  defp build_adjacency(edges, direction_key) do
    Enum.group_by(edges, &Map.get(&1, direction_key))
  end

  defp aggregate_capabilities(enriched_nodes) do
    enriched_nodes
    |> Enum.flat_map(fn {_id, node} -> node.capabilities_required end)
    |> MapSet.new()
  end

  defp compute_max_classification(enriched_nodes) do
    enriched_nodes
    |> Enum.reduce(:public, fn {_id, node}, acc ->
      Graph.max_classification(acc, node.data_classification)
    end)
  end
end
