defmodule Arbor.Orchestrator.IR.Validator do
  @moduledoc """
  Typed validation passes that run on `TypedGraph.t()`.

  These passes are only possible with the typed IR because they require
  resolved handler types, capabilities, data classifications, and parsed
  edge conditions. They complement (not replace) the structural validation
  in `Arbor.Orchestrator.Validation.Validator`.

  ## Passes

  1. **Schema validation** — every node has required attrs with correct types
  2. **Capability analysis** — compute and report all capabilities needed
  3. **Taint reachability** — sensitive data doesn't flow to lower-classification nodes
  4. **Loop detection** — cycles have bounded termination (max_retries or goal_gate)
  5. **Resource bounds** — side-effecting nodes have retry/timeout limits
  6. **Condition completeness** — conditional nodes have both success and failure paths
  """

  alias Arbor.Orchestrator.IR.{TypedGraph, TypedNode, TypedEdge}
  alias Arbor.Orchestrator.Validation.Diagnostic

  @doc "Run all typed validation passes. Returns list of diagnostics."
  @spec validate(TypedGraph.t()) :: [Diagnostic.t()]
  def validate(%TypedGraph{} = graph) do
    []
    |> add_schema_errors(graph)
    |> add_capability_info(graph)
    |> add_taint_errors(graph)
    |> add_loop_warnings(graph)
    |> add_resource_warnings(graph)
    |> add_condition_completeness_warnings(graph)
    |> add_condition_parse_errors(graph)
  end

  @doc "Run only schema validation. Fastest pass."
  @spec validate_schema(TypedGraph.t()) :: [Diagnostic.t()]
  def validate_schema(%TypedGraph{} = graph) do
    add_schema_errors([], graph)
  end

  @doc "Run only taint analysis. Returns taint flow violations."
  @spec validate_taint(TypedGraph.t()) :: [Diagnostic.t()]
  def validate_taint(%TypedGraph{} = graph) do
    add_taint_errors([], graph)
  end

  # --- Pass 1: Schema validation ---

  defp add_schema_errors(diags, %TypedGraph{nodes: nodes}) do
    schema_diags =
      nodes
      |> Enum.flat_map(fn {_id, node} ->
        node.schema_errors
        |> Enum.map(fn {severity, message} ->
          case severity do
            :error ->
              Diagnostic.error("typed_schema", "#{node.id}: #{message}", node_id: node.id)

            :warning ->
              Diagnostic.warning("typed_schema", "#{node.id}: #{message}", node_id: node.id)
          end
        end)
      end)

    schema_diags ++ diags
  end

  # --- Pass 2: Capability analysis ---

  defp add_capability_info(diags, %TypedGraph{} = graph) do
    if MapSet.size(graph.capabilities_required) > 0 do
      caps = graph.capabilities_required |> MapSet.to_list() |> Enum.sort() |> Enum.join(", ")

      cap_diag =
        Diagnostic.warning(
          "capabilities_required",
          "Pipeline requires capabilities: #{caps}"
        )

      [cap_diag | diags]
    else
      diags
    end
  end

  # --- Pass 3: Taint reachability ---

  @classification_rank %{public: 0, internal: 1, sensitive: 2, secret: 3}

  defp add_taint_errors(diags, %TypedGraph{} = graph) do
    taint_diags =
      graph.edges
      |> Enum.flat_map(fn edge ->
        source_node = Map.get(graph.nodes, edge.from)
        target_node = Map.get(graph.nodes, edge.to)

        if source_node && target_node do
          check_taint_flow(source_node, target_node)
        else
          []
        end
      end)

    taint_diags ++ diags
  end

  defp check_taint_flow(%TypedNode{} = source, %TypedNode{} = target) do
    source_rank = Map.get(@classification_rank, source.data_classification, 0)
    target_rank = Map.get(@classification_rank, target.data_classification, 0)

    if source_rank > target_rank do
      # Taint flows are warnings by default. When both nodes use explicit data_class
      # attrs (not schema defaults), escalate to error — the author intentionally
      # classified both sides and the flow is a genuine violation.
      severity =
        if has_explicit_classification?(source) and has_explicit_classification?(target),
          do: :error,
          else: :warning

      diag_fn = if severity == :error, do: &Diagnostic.error/3, else: &Diagnostic.warning/3

      [
        diag_fn.(
          "taint_flow",
          "Data flows from #{source.data_classification} node '#{source.id}' " <>
            "to #{target.data_classification} node '#{target.id}' — potential data leak",
          edge: {source.id, target.id}
        )
      ]
    else
      []
    end
  end

  defp has_explicit_classification?(%TypedNode{attrs: attrs}) do
    Map.has_key?(attrs, "data_class")
  end

  # --- Pass 4: Loop detection ---

  defp add_loop_warnings(diags, %TypedGraph{} = graph) do
    cycles = detect_cycles(graph)

    loop_diags =
      cycles
      |> Enum.flat_map(fn cycle_nodes ->
        bounded = cycle_has_bounds?(cycle_nodes, graph)

        if bounded do
          []
        else
          node_list = Enum.join(cycle_nodes, " → ")

          [
            Diagnostic.warning(
              "unbounded_loop",
              "Cycle detected without termination bounds: #{node_list}. " <>
                "Add max_retries, goal_gate, or a conditional exit to prevent infinite loops.",
              node_id: List.first(cycle_nodes)
            )
          ]
        end
      end)

    loop_diags ++ diags
  end

  defp detect_cycles(%TypedGraph{nodes: nodes} = graph) do
    node_ids = Map.keys(nodes)
    {cycles, _} = Enum.reduce(node_ids, {[], MapSet.new()}, fn id, {found, visited} ->
      if MapSet.member?(visited, id) do
        {found, visited}
      else
        {new_cycles, new_visited} = dfs_cycles(graph, id, [], MapSet.new(), visited)
        {found ++ new_cycles, new_visited}
      end
    end)
    cycles
  end

  defp dfs_cycles(graph, node_id, path, in_stack, visited) do
    if MapSet.member?(in_stack, node_id) do
      cycle_start = Enum.find_index(path, &(&1 == node_id))
      cycle = Enum.slice(path, cycle_start..-1//1) ++ [node_id]
      {[cycle], MapSet.put(visited, node_id)}
    else
      if MapSet.member?(visited, node_id) do
        {[], visited}
      else
        new_path = path ++ [node_id]
        new_stack = MapSet.put(in_stack, node_id)
        neighbors = TypedGraph.outgoing_edges(graph, node_id) |> Enum.map(& &1.to)

        {cycles, final_visited} =
          Enum.reduce(neighbors, {[], MapSet.put(visited, node_id)}, fn neighbor, {acc_cycles, acc_visited} ->
            {new_cycles, new_visited} = dfs_cycles(graph, neighbor, new_path, new_stack, acc_visited)
            {acc_cycles ++ new_cycles, new_visited}
          end)

        {cycles, final_visited}
      end
    end
  end

  defp cycle_has_bounds?(cycle_nodes, %TypedGraph{nodes: nodes}) do
    Enum.any?(cycle_nodes, fn node_id ->
      case Map.get(nodes, node_id) do
        nil ->
          false

        node ->
          has_retry_limit?(node) or has_goal_gate?(node) or has_conditional_exit?(node)
      end
    end)
  end

  defp has_retry_limit?(%TypedNode{resource_bounds: %{max_retries: n}}) when is_integer(n) and n > 0, do: true
  defp has_retry_limit?(%TypedNode{attrs: attrs}) do
    Map.get(attrs, "max_retries") not in [nil, "", 0]
  end

  defp has_goal_gate?(%TypedNode{attrs: attrs}) do
    Map.get(attrs, "goal_gate") in [true, "true"]
  end

  defp has_conditional_exit?(%TypedNode{handler_type: "conditional"}), do: true
  defp has_conditional_exit?(_), do: false

  # --- Pass 5: Resource bounds ---

  defp add_resource_warnings(diags, %TypedGraph{nodes: nodes}) do
    resource_diags =
      nodes
      |> Enum.flat_map(fn {_id, node} ->
        if TypedNode.side_effecting?(node) do
          check_resource_bounds(node)
        else
          []
        end
      end)

    resource_diags ++ diags
  end

  defp check_resource_bounds(%TypedNode{} = node) do
    warnings = []

    warnings =
      if node.handler_type == "tool" and node.resource_bounds.max_retries == nil do
        [
          Diagnostic.warning(
            "missing_resource_bound",
            "Side-effecting tool node '#{node.id}' has no max_retries limit",
            node_id: node.id
          )
          | warnings
        ]
      else
        warnings
      end

    warnings
  end

  # --- Pass 6: Condition completeness ---

  defp add_condition_completeness_warnings(diags, %TypedGraph{} = graph) do
    completeness_diags =
      graph.nodes
      |> Enum.flat_map(fn {_id, node} ->
        if node.handler_type == "conditional" do
          check_condition_completeness(node, graph)
        else
          []
        end
      end)

    completeness_diags ++ diags
  end

  defp check_condition_completeness(%TypedNode{} = node, %TypedGraph{} = graph) do
    outgoing = TypedGraph.outgoing_edges(graph, node.id)

    has_success = Enum.any?(outgoing, &TypedEdge.success_path?/1)
    has_failure = Enum.any?(outgoing, &TypedEdge.failure_path?/1)
    has_unconditional = Enum.any?(outgoing, &TypedEdge.unconditional?/1)

    cond do
      has_unconditional ->
        []

      has_success and not has_failure ->
        [
          Diagnostic.warning(
            "incomplete_conditional",
            "Conditional node '#{node.id}' has success path but no failure path",
            node_id: node.id
          )
        ]

      has_failure and not has_success ->
        [
          Diagnostic.warning(
            "incomplete_conditional",
            "Conditional node '#{node.id}' has failure path but no success path",
            node_id: node.id
          )
        ]

      true ->
        []
    end
  end

  # --- Pass 7: Condition parse errors ---

  defp add_condition_parse_errors(diags, %TypedGraph{edges: edges}) do
    parse_diags =
      edges
      |> Enum.flat_map(fn edge ->
        case edge.condition do
          {:parse_error, raw} ->
            [
              Diagnostic.error(
                "condition_parse",
                "Edge #{edge.from} → #{edge.to} has unparseable condition: #{raw}",
                edge: {edge.from, edge.to}
              )
            ]

          _ ->
            []
        end
      end)

    parse_diags ++ diags
  end
end
