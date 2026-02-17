defmodule Arbor.Orchestrator.Validation.Validator do
  @moduledoc """
  Built-in validator/linter for Attractor graph rules.

  First milestone implements core hard-errors:
  - exactly one start node
  - exactly one terminal node
  - all edge targets exist
  """

  alias Arbor.Orchestrator.Engine.Condition
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Validation.Diagnostic

  defmodule ValidationError do
    defexception [:diagnostics, message: "Pipeline validation failed"]
  end

  @spec validate(Graph.t()) :: [Diagnostic.t()]
  def validate(%Graph{} = graph) do
    []
    |> add_start_node_errors(graph)
    |> add_terminal_node_errors(graph)
    |> add_start_incoming_errors(graph)
    |> add_exit_outgoing_errors(graph)
    |> add_edge_target_errors(graph)
    |> add_reachability_errors(graph)
    |> add_condition_syntax_errors(graph)
    |> add_retry_target_warnings(graph)
    |> add_goal_gate_retry_warnings(graph)
    |> add_codergen_prompt_warnings(graph)
  end

  @spec validate_or_error(Graph.t()) :: :ok | {:error, [Diagnostic.t()]}
  def validate_or_error(%Graph{} = graph) do
    diagnostics = validate(graph)

    if Enum.any?(diagnostics, &(&1.severity == :error)) do
      {:error, diagnostics}
    else
      :ok
    end
  end

  @spec validate_or_raise(Graph.t()) :: :ok
  def validate_or_raise(%Graph{} = graph) do
    case validate_or_error(graph) do
      :ok ->
        :ok

      {:error, diagnostics} ->
        raise ValidationError, diagnostics: diagnostics
    end
  end

  defp add_start_node_errors(diags, graph) do
    starts =
      graph.nodes
      |> Map.values()
      |> Enum.filter(fn node ->
        shape = Map.get(node.attrs, "shape")
        shape == "Mdiamond" or String.downcase(node.id) == "start"
      end)

    case length(starts) do
      1 -> diags
      0 -> [Diagnostic.error("start_node", "Pipeline must have exactly one start node") | diags]
      _ -> [Diagnostic.error("start_node", "Pipeline has multiple start nodes") | diags]
    end
  end

  defp add_terminal_node_errors(diags, graph) do
    terminals =
      graph.nodes
      |> Map.values()
      |> Enum.filter(fn node ->
        shape = Map.get(node.attrs, "shape")
        shape == "Msquare" or String.downcase(node.id) in ["exit", "end"]
      end)

    case length(terminals) do
      1 ->
        diags

      0 ->
        [
          Diagnostic.error("terminal_node", "Pipeline must have exactly one terminal node")
          | diags
        ]

      _ ->
        [Diagnostic.error("terminal_node", "Pipeline has multiple terminal nodes") | diags]
    end
  end

  defp add_edge_target_errors(diags, graph) do
    missing_diags =
      graph.edges
      |> Enum.filter(fn edge -> not Map.has_key?(graph.nodes, edge.to) end)
      |> Enum.map(fn edge ->
        Diagnostic.error(
          "edge_target_exists",
          "Edge target does not exist: #{edge.to}",
          edge: {edge.from, edge.to}
        )
      end)

    missing_diags ++ diags
  end

  defp add_start_incoming_errors(diags, graph) do
    starts = find_start_nodes(graph)

    start_diags =
      starts
      |> Enum.flat_map(fn start ->
        incoming = Graph.incoming_edges(graph, start.id)

        if incoming == [] do
          []
        else
          [
            Diagnostic.error("start_no_incoming", "Start node must not have incoming edges",
              node_id: start.id
            )
          ]
        end
      end)

    start_diags ++ diags
  end

  defp add_exit_outgoing_errors(diags, graph) do
    terminal_nodes = find_terminal_nodes(graph)

    term_diags =
      terminal_nodes
      |> Enum.flat_map(fn terminal ->
        outgoing = Graph.outgoing_edges(graph, terminal.id)

        if outgoing == [] do
          []
        else
          [
            Diagnostic.error("exit_no_outgoing", "Exit node must not have outgoing edges",
              node_id: terminal.id
            )
          ]
        end
      end)

    term_diags ++ diags
  end

  defp add_reachability_errors(diags, graph) do
    case find_start_nodes(graph) do
      [start] ->
        reachable = dfs(graph, MapSet.new(), [start.id])

        unreachable =
          graph.nodes
          |> Map.keys()
          |> Enum.reject(&MapSet.member?(reachable, &1))

        unreachable_diags =
          Enum.map(unreachable, fn node_id ->
            Diagnostic.error("reachability", "Node is unreachable from start: #{node_id}",
              node_id: node_id
            )
          end)

        unreachable_diags ++ diags

      _ ->
        diags
    end
  end

  defp add_condition_syntax_errors(diags, graph) do
    syntax_diags =
      graph.edges
      |> Enum.flat_map(fn edge ->
        condition = Map.get(edge.attrs, "condition", "")

        if condition not in [nil, ""] and not Condition.valid_syntax?(condition) do
          [
            Diagnostic.error(
              "condition_syntax",
              "Invalid edge condition syntax: #{condition}",
              edge: {edge.from, edge.to}
            )
          ]
        else
          []
        end
      end)

    syntax_diags ++ diags
  end

  defp add_retry_target_warnings(diags, graph) do
    graph_target_warnings =
      ["retry_target", "fallback_retry_target"]
      |> Enum.flat_map(fn key ->
        target = Map.get(graph.attrs, key)

        if target in [nil, ""] or Map.has_key?(graph.nodes, target) do
          []
        else
          [
            Diagnostic.warning(
              "retry_target_exists",
              "Graph #{key} points to unknown node: #{target}"
            )
          ]
        end
      end)

    node_target_warnings =
      graph.nodes
      |> Map.values()
      |> Enum.flat_map(fn node ->
        ["retry_target", "fallback_retry_target"]
        |> Enum.flat_map(fn key ->
          target = Map.get(node.attrs, key)

          if target in [nil, ""] or Map.has_key?(graph.nodes, target) do
            []
          else
            [
              Diagnostic.warning(
                "retry_target_exists",
                "Node #{node.id} #{key} points to unknown node: #{target}",
                node_id: node.id
              )
            ]
          end
        end)
      end)

    graph_target_warnings ++ node_target_warnings ++ diags
  end

  defp add_goal_gate_retry_warnings(diags, graph) do
    warnings =
      graph.nodes
      |> Map.values()
      |> Enum.flat_map(fn node ->
        if truthy?(Map.get(node.attrs, "goal_gate", false)) and
             Map.get(node.attrs, "retry_target") in [nil, ""] and
             Map.get(node.attrs, "fallback_retry_target") in [nil, ""] do
          [
            Diagnostic.warning(
              "goal_gate_has_retry",
              "Goal gate node should define retry_target or fallback_retry_target",
              node_id: node.id
            )
          ]
        else
          []
        end
      end)

    warnings ++ diags
  end

  defp add_codergen_prompt_warnings(diags, graph) do
    warnings =
      graph.nodes
      |> Map.values()
      |> Enum.flat_map(fn node ->
        shape = Map.get(node.attrs, "shape", "box")
        node_type = Map.get(node.attrs, "type")
        prompt = Map.get(node.attrs, "prompt", "")

        is_codergen =
          node_type == "codergen" or
            (node_type in [nil, ""] and shape == "box")

        if is_codergen and to_string(prompt) == "" do
          [
            Diagnostic.warning("codergen_prompt", "Codergen node is missing prompt",
              node_id: node.id
            )
          ]
        else
          []
        end
      end)

    warnings ++ diags
  end

  defp find_start_nodes(graph) do
    graph.nodes
    |> Map.values()
    |> Enum.filter(fn node ->
      Map.get(node.attrs, "shape") == "Mdiamond" or String.downcase(node.id) == "start"
    end)
  end

  defp find_terminal_nodes(graph) do
    graph.nodes
    |> Map.values()
    |> Enum.filter(fn node ->
      Map.get(node.attrs, "shape") == "Msquare" or String.downcase(node.id) in ["exit", "end"]
    end)
  end

  defp dfs(_graph, visited, []), do: visited

  defp dfs(graph, visited, [node_id | rest]) do
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

  defp implicit_targets(nil), do: []

  defp implicit_targets(node) do
    [Map.get(node.attrs, "retry_target"), Map.get(node.attrs, "fallback_retry_target")]
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(1), do: true
  defp truthy?(_), do: false
end
