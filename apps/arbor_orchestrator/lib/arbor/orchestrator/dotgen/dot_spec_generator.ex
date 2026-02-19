defmodule Arbor.Orchestrator.Dotgen.DotSpecGenerator do
  @moduledoc """
  Generates Natural Language Specification (NLSpec) documents from DOT pipeline files.

  Parses .dot files using the Arbor parser and produces structured markdown
  that describes what the pipeline does, its node inventory, data flow, and
  execution semantics.

  This is the inverse of planner.dot — instead of generating a pipeline from
  a spec, it generates a spec from a pipeline.

  The output format:
    1. Overview (from graph goal attribute)
    2. Pipeline Structure (node count, edge count, handler types used)
    3. Node Inventory (each node with its role, handler type, key attributes)
    4. Execution Flow (the path through the graph, with conditions)
    5. Data Flow (context keys read/written, inferred from prompts and attributes)
    6. Conditions and Routing (edge conditions, conditional branches)
  """

  alias Arbor.Orchestrator.Dot.Parser
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.{Edge, Node}
  alias Arbor.Orchestrator.Handlers.Registry, as: HandlerRegistry

  # Known node attributes that get special treatment in the node inventory.
  # Everything else in attrs is shown as custom attributes.
  @known_attrs ~w(shape type label prompt goal goal_gate max_retries retry_target
    fallback_retry_target fidelity thread_id class timeout llm_model llm_provider
    reasoning_effort auto_status allow_partial fan_out simulate)

  # ── Public API ──

  @doc "Generate NLSpec from a .dot file path."
  @spec generate_from_file(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def generate_from_file(dot_path) do
    case File.read(dot_path) do
      {:ok, source} -> generate_from_source(source)
      {:error, reason} -> {:error, "Failed to read file #{dot_path}: #{reason}"}
    end
  end

  @doc "Generate NLSpec from a .dot source string."
  @spec generate_from_source(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def generate_from_source(dot_source) do
    case Parser.parse(dot_source) do
      {:ok, graph} -> {:ok, generate_from_graph(graph)}
      {:error, reason} -> {:error, "Failed to parse DOT source: #{reason}"}
    end
  end

  @doc "Generate NLSpec from a parsed Graph struct."
  @spec generate_from_graph(Graph.t()) :: String.t()
  def generate_from_graph(%Graph{} = graph) do
    [
      "# Pipeline: #{graph.id}",
      "",
      format_overview(graph),
      format_structure(graph),
      format_node_inventory(graph),
      format_execution_flow(graph),
      format_data_flow(graph),
      format_conditions(graph)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  @doc "Generate NLSpec for multiple .dot files, combined into one document."
  @spec generate_from_files([String.t()], keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def generate_from_files(dot_paths, opts \\ []) do
    title = Keyword.get(opts, :title, "Pipeline Specifications")

    results =
      Enum.map(dot_paths, fn path ->
        case generate_from_file(path) do
          {:ok, spec} -> {:ok, path, spec}
          {:error, reason} -> {:error, path, reason}
        end
      end)

    errors =
      Enum.filter(results, fn
        {:error, _, _} -> true
        _ -> false
      end)

    if errors != [] do
      messages =
        Enum.map(errors, fn {:error, path, reason} -> "  - #{path}: #{reason}" end)

      {:error, "Failed to generate specs:\n#{Enum.join(messages, "\n")}"}
    else
      specs = Enum.map(results, fn {:ok, _path, spec} -> spec end)
      paths = Enum.map(results, fn {:ok, path, _spec} -> path end)

      toc =
        paths
        |> Enum.with_index(1)
        |> Enum.map_join("\n", fn {path, idx} ->
          name = Path.basename(path, ".dot")
          "#{idx}. [#{name}](#pipeline-#{name})"
        end)

      combined =
        [
          "# #{title}",
          "",
          "## Table of Contents",
          "",
          toc,
          "",
          "---",
          "",
          Enum.join(specs, "\n\n---\n\n")
        ]
        |> Enum.join("\n")

      {:ok, combined}
    end
  end

  # ── Private Helpers ──

  defp format_overview(%Graph{} = graph) do
    goal = Graph.goal(graph) || ""
    node_count = map_size(graph.nodes)
    edge_count = length(graph.edges)

    goal_text = if goal != "", do: goal, else: "No goal specified."

    [
      "## Overview",
      "",
      goal_text,
      "",
      "- **Graph ID**: `#{graph.id}`",
      "- **Nodes**: #{node_count}",
      "- **Edges**: #{edge_count}",
      ""
    ]
    |> Enum.join("\n")
  end

  defp format_structure(%Graph{} = graph) do
    node_count = map_size(graph.nodes)
    edge_count = length(graph.edges)

    handler_types =
      graph.nodes
      |> Map.values()
      |> Enum.map(&HandlerRegistry.node_type/1)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.join(", ")

    has_conditions =
      Enum.any?(graph.edges, fn edge -> Edge.attr(edge, "condition", "") != "" end)

    has_parallel =
      graph.nodes
      |> Map.values()
      |> Enum.any?(fn node -> Node.attr(node, "shape") == "component" end)

    [
      "## Pipeline Structure",
      "",
      "| Property | Value |",
      "|----------|-------|",
      "| Graph ID | `#{graph.id}` |",
      "| Nodes | #{node_count} |",
      "| Edges | #{edge_count} |",
      "| Handler Types | #{handler_types} |",
      "| Has Conditions | #{if has_conditions, do: "yes", else: "no"} |",
      "| Has Parallel Branches | #{if has_parallel, do: "yes", else: "no"} |",
      ""
    ]
    |> Enum.join("\n")
  end

  defp format_node_inventory(%Graph{} = graph) do
    sorted_ids = topological_sort(graph)

    node_sections =
      sorted_ids
      |> Enum.map(fn id ->
        case Map.get(graph.nodes, id) do
          nil -> nil
          node -> format_single_node(node)
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    [
      "## Node Inventory",
      "",
      node_sections,
      ""
    ]
    |> Enum.join("\n")
  end

  defp format_single_node(%Node{} = node) do
    handler_type = HandlerRegistry.node_type(node)
    prompt = Node.attr(node, "prompt", "")
    label = Node.attr(node, "label", "")
    prompt_summary = summarize_prompt(prompt)

    description =
      cond do
        prompt_summary != nil -> prompt_summary
        label != "" and label != node.id -> label
        true -> nil
      end

    # Collect notable attributes
    shape = Node.attr(node, "shape", "box")
    max_retries = Node.attr(node, "max_retries", "0")
    goal_gate = Node.attr(node, "goal_gate", "")
    retry_target = Node.attr(node, "retry_target", "")
    fallback_retry_target = Node.attr(node, "fallback_retry_target", "")
    fidelity = Node.attr(node, "fidelity", "")
    thread_id = Node.attr(node, "thread_id", "")
    class = Node.attr(node, "class", "")
    timeout = Node.attr(node, "timeout")
    llm_model = Node.attr(node, "llm_model", "")
    llm_provider = Node.attr(node, "llm_provider", "")
    reasoning_effort = Node.attr(node, "reasoning_effort", "high")
    auto_status = Node.attr(node, "auto_status", "")
    allow_partial = Node.attr(node, "allow_partial", "")
    fan_out = Node.attr(node, "fan_out", "")
    simulate = Node.attr(node, "simulate", "")

    attrs =
      [
        if(shape != "box", do: {"shape", shape}),
        if(max_retries != "0" and max_retries != 0, do: {"max_retries", "#{max_retries}"}),
        if(goal_gate not in ["", nil, "false"], do: {"goal_gate", "true"}),
        if(retry_target != "", do: {"retry_target", retry_target}),
        if(fallback_retry_target != "", do: {"fallback_retry_target", fallback_retry_target}),
        if(fidelity != "", do: {"fidelity", fidelity}),
        if(thread_id != "", do: {"thread_id", thread_id}),
        if(class != "", do: {"class", class}),
        if(timeout not in [nil, ""], do: {"timeout", "#{timeout}ms"}),
        if(llm_model != "", do: {"llm_model", llm_model}),
        if(llm_provider != "", do: {"llm_provider", llm_provider}),
        if(reasoning_effort != "high", do: {"reasoning_effort", reasoning_effort}),
        if(auto_status not in ["", nil, "false"], do: {"auto_status", "true"}),
        if(allow_partial not in ["", nil, "false"], do: {"allow_partial", "true"}),
        if(fan_out not in ["", nil, "false"], do: {"fan_out", "true"}),
        if(simulate not in ["", nil, "false"], do: {"simulate", simulate})
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.concat(custom_attrs(node))

    attrs_table =
      if attrs != [] do
        header = "| Attribute | Value |\n|-----------|-------|\n"

        rows =
          attrs
          |> Enum.map_join("\n", fn {k, v} -> "| #{k} | #{v} |" end)

        "\n" <> header <> rows <> "\n"
      else
        ""
      end

    desc_line = if description, do: "\n#{description}\n", else: ""

    "### `#{node.id}` (#{handler_type})\n#{desc_line}#{attrs_table}"
  end

  defp custom_attrs(%Node{attrs: attrs}) do
    attrs
    |> Enum.reject(fn {k, _v} -> k in @known_attrs end)
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Enum.map(fn {k, v} -> {k, "#{v}"} end)
  end

  defp format_execution_flow(%Graph{} = graph) do
    sorted_ids = topological_sort(graph)
    start_node = Graph.find_start_node(graph)

    steps =
      sorted_ids
      |> Enum.with_index(1)
      |> Enum.map(fn {id, idx} ->
        node = Map.get(graph.nodes, id)

        if node == nil do
          nil
        else
          handler_type = HandlerRegistry.node_type(node)
          outgoing = Graph.outgoing_edges(graph, id)

          conditional_edges =
            Enum.filter(outgoing, fn e -> Edge.attr(e, "condition", "") != "" end)

          parallel = Node.attr(node, "shape") == "component"

          cond do
            start_node != nil and node.id == start_node.id ->
              "#{idx}. Pipeline begins at `#{id}` node."

            Graph.terminal?(graph, node) ->
              "#{idx}. Pipeline completes at `#{id}` node."

            parallel ->
              targets =
                outgoing
                |> Enum.map_join("\n", fn e -> "   - `#{e.to}`" end)

              "#{idx}. At `#{id}`, execution splits into parallel branches:\n#{targets}"

            conditional_edges != [] ->
              branches =
                conditional_edges
                |> Enum.map_join("\n", fn e ->
                  label = Edge.attr(e, "label", "")
                  label_part = if label != "", do: " (#{label})", else: ""
                  condition = Edge.attr(e, "condition", "")
                  "   - On `#{condition}`#{label_part}: proceeds to `#{e.to}`"
                end)

              "#{idx}. At `#{id}` (#{handler_type}), the pipeline branches:\n#{branches}"

            true ->
              desc = describe_node_action(node, handler_type)
              "#{idx}. Proceeds to `#{id}` (#{handler_type})#{desc}."
          end
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    [
      "## Execution Flow",
      "",
      steps,
      ""
    ]
    |> Enum.join("\n")
  end

  defp describe_node_action(%Node{} = node, _handler_type) do
    prompt = Node.attr(node, "prompt", "")
    label = Node.attr(node, "label", "")
    summary = summarize_prompt(prompt)

    cond do
      summary != nil -> " — #{summary}"
      label != "" and label != node.id -> " — #{label}"
      true -> ""
    end
  end

  defp format_data_flow(%Graph{} = graph) do
    # Collect context key references from node attributes and prompts
    context_map =
      graph.nodes
      |> Map.values()
      |> Enum.reduce(%{}, fn node, acc ->
        handler_type = HandlerRegistry.node_type(node)
        written_keys = extract_written_keys(node, handler_type)
        read_keys = extract_read_keys(node, handler_type)

        acc =
          Enum.reduce(written_keys, acc, fn key, a ->
            entry = Map.get(a, key, %{written_by: [], read_by: []})
            Map.put(a, key, %{entry | written_by: [node.id | entry.written_by]})
          end)

        Enum.reduce(read_keys, acc, fn key, a ->
          entry = Map.get(a, key, %{written_by: [], read_by: []})
          Map.put(a, key, %{entry | read_by: [node.id | entry.read_by]})
        end)
      end)

    if map_size(context_map) == 0 do
      [
        "## Data Flow",
        "",
        "Context flow is determined at runtime.",
        ""
      ]
      |> Enum.join("\n")
    else
      rows =
        context_map
        |> Enum.sort_by(fn {key, _} -> key end)
        |> Enum.map_join("\n", fn {key, %{written_by: writers, read_by: readers}} ->
          w = if writers == [], do: "—", else: writers |> Enum.reverse() |> Enum.join(", ")
          r = if readers == [], do: "—", else: readers |> Enum.reverse() |> Enum.join(", ")
          "| `#{key}` | #{w} | #{r} |"
        end)

      [
        "## Data Flow",
        "",
        "| Context Key | Written By | Read By |",
        "|-------------|------------|---------|",
        rows,
        ""
      ]
      |> Enum.join("\n")
    end
  end

  defp extract_written_keys(%Node{} = node, handler_type) do
    attr_keys =
      node.attrs
      |> Enum.filter(fn {k, _v} -> k in ~w(output_key result_key) end)
      |> Enum.map(fn {_k, v} -> v end)

    implicit_keys =
      case handler_type do
        "codergen" -> ["last_response", "last_stage"]
        _ -> []
      end

    (attr_keys ++ implicit_keys) |> Enum.uniq()
  end

  defp extract_read_keys(%Node{} = node, _handler_type) do
    attr_keys =
      node.attrs
      |> Enum.filter(fn {k, _v} -> k in ~w(content_key source_key query_key input_key) end)
      |> Enum.map(fn {_k, v} -> v end)

    prompt = Node.attr(node, "prompt", "") || ""
    prompt_keys = extract_context_refs_from_prompt(prompt)

    (attr_keys ++ prompt_keys) |> Enum.uniq()
  end

  defp extract_context_refs_from_prompt(""), do: []

  defp extract_context_refs_from_prompt(prompt) do
    # Match patterns like context["key"], context[:key], $key
    bracket_refs =
      Regex.scan(~r/context\[["':]+(\w+)["':\]]+/, prompt)
      |> Enum.map(fn [_, key] -> key end)

    dollar_refs =
      Regex.scan(~r/\$(\w+)/, prompt)
      |> Enum.map(fn [_, key] -> key end)

    (bracket_refs ++ dollar_refs) |> Enum.uniq()
  end

  defp format_conditions(%Graph{} = graph) do
    conditional_edges =
      Enum.filter(graph.edges, fn edge -> Edge.attr(edge, "condition", "") != "" end)

    if conditional_edges == [] do
      [
        "## Conditions and Routing",
        "",
        "This pipeline uses linear execution with no conditions.",
        ""
      ]
      |> Enum.join("\n")
    else
      entries =
        conditional_edges
        |> Enum.map_join("\n", fn edge ->
          label = Edge.attr(edge, "label", "")
          condition = Edge.attr(edge, "condition", "")
          label_part = if label != "", do: " (label: #{label})", else: ""
          "- `#{edge.from}` → `#{edge.to}`: condition `#{condition}`#{label_part}"
        end)

      [
        "## Conditions and Routing",
        "",
        entries,
        ""
      ]
      |> Enum.join("\n")
    end
  end

  defp topological_sort(%Graph{} = graph) do
    # BFS from start node(s), handles cycles naturally for pipeline graphs
    adj =
      Enum.reduce(graph.edges, %{}, fn edge, acc ->
        Map.update(acc, edge.from, [edge.to], fn targets -> [edge.to | targets] end)
      end)

    # Find start nodes (no incoming edges, or shape=Mdiamond)
    start_node = Graph.find_start_node(graph)

    roots =
      if start_node do
        [start_node.id]
      else
        all_ids = MapSet.new(Map.keys(graph.nodes))
        targets = graph.edges |> Enum.map(& &1.to) |> MapSet.new()
        MapSet.difference(all_ids, targets) |> Enum.sort()
      end

    bfs_order(roots, adj, MapSet.new(), [])
    |> then(fn visited ->
      # Append any unreachable nodes
      remaining =
        Map.keys(graph.nodes)
        |> Enum.reject(&(&1 in MapSet.new(visited)))
        |> Enum.sort()

      visited ++ remaining
    end)
  end

  defp bfs_order([], _adj, _visited, result), do: result

  defp bfs_order([current | rest], adj, visited, result) do
    if MapSet.member?(visited, current) do
      bfs_order(rest, adj, visited, result)
    else
      new_visited = MapSet.put(visited, current)
      neighbors = Map.get(adj, current, []) |> Enum.sort()
      new_queue = rest ++ neighbors
      bfs_order(new_queue, adj, new_visited, result ++ [current])
    end
  end

  defp summarize_prompt(nil), do: nil
  defp summarize_prompt(""), do: nil

  defp summarize_prompt(prompt) do
    cleaned =
      prompt
      |> String.replace(~r/\n+/, " ")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    if String.length(cleaned) > 200 do
      String.slice(cleaned, 0, 200) <> "..."
    else
      cleaned
    end
  end
end
