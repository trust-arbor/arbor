defmodule Mix.Tasks.Arbor.Pipeline.Viz do
  @shortdoc "Visualize a DOT pipeline as ASCII or Mermaid diagram"
  @moduledoc """
  Renders a .dot pipeline file as a terminal-friendly visualization.

  ## Usage

      mix arbor.pipeline.viz specs/pipelines/sdlc.dot
      mix arbor.pipeline.viz specs/pipelines/sdlc.dot --format mermaid
      mix arbor.pipeline.viz specs/pipelines/sdlc.dot --typed

  ## Options

  - `--format` / `-f` — Output format: `ascii` (default) or `mermaid`
  - `--typed` / `-t` — Show typed IR info (handler types, classifications, capabilities)
  """

  use Mix.Task

  import Arbor.Orchestrator.Mix.Helpers

  alias Arbor.Orchestrator.Handlers.Registry

  @impl true
  def run(args) do
    {opts, files, _} =
      OptionParser.parse(args,
        strict: [format: :string, typed: :boolean],
        aliases: [f: :format, t: :typed]
      )

    ensure_orchestrator_started()

    case files do
      [] ->
        error("Usage: mix arbor.pipeline.viz <file.dot> [--format ascii|mermaid] [--typed]")
        System.halt(1)

      _ ->
        format = Keyword.get(opts, :format, "ascii")
        typed = Keyword.get(opts, :typed, false)

        Enum.each(files, fn file ->
          viz_file(file, format, typed)
        end)
    end
  end

  defp viz_file(file, format, typed) do
    unless File.exists?(file) do
      error("File not found: #{file}")
      System.halt(1)
    end

    case File.read(file) do
      {:ok, source} ->
        case Arbor.Orchestrator.parse(source) do
          {:ok, graph} ->
            case format do
              "mermaid" -> render_mermaid(graph, file, typed)
              _ -> render_ascii(graph, file, typed)
            end

          {:error, reason} ->
            error("Parse error in #{file}: #{inspect(reason)}")
        end

      {:error, reason} ->
        error("Could not read #{file}: #{inspect(reason)}")
    end
  end

  # --- ASCII Renderer ---

  defp render_ascii(graph, file, typed) do
    goal = Map.get(graph.attrs, "goal", "")
    info("")
    success("Pipeline: #{graph.id}")
    if goal != "", do: info("Goal: #{goal}")
    info("File: #{file}")
    info("")

    # Build adjacency for topological-ish ordering
    adj = build_adjacency(graph)
    ordered = topo_sort(graph, adj)

    # Find start and exit nodes
    typed_info = if typed, do: build_typed_info(graph), else: nil

    Enum.each(ordered, fn node_id ->
      node = Map.get(graph.nodes, node_id)
      type = Registry.node_type(node)
      render_ascii_node(node, type, graph, adj, typed_info)
    end)

    info("")

    if typed_info do
      caps = typed_info.capabilities |> MapSet.to_list() |> Enum.sort()

      if caps != [] do
        info("Capabilities: #{Enum.join(caps, ", ")}")
      end

      info("Max classification: #{typed_info.max_classification}")
    end
  end

  defp render_ascii_node(node, type, _graph, adj, typed_info) do
    icon = type_icon(type)
    label = node_label(node, type)

    # Get typed info if available
    typed_suffix =
      if typed_info do
        tn = Map.get(typed_info.nodes, node.id)

        if tn do
          " [#{tn.data_classification}, #{tn.idempotency}]"
        else
          ""
        end
      else
        ""
      end

    info("  #{icon} #{label}#{typed_suffix}")

    # Show outgoing edges
    outgoing = Map.get(adj, node.id, [])

    Enum.each(outgoing, fn {target, edge_attrs} ->
      condition = Map.get(edge_attrs, "condition", "")
      edge_label = Map.get(edge_attrs, "label", "")

      arrow =
        cond do
          condition =~ "fail" -> "  \u2502  \u2514\u2500\u2500 [fail] \u2500\u2500>"
          condition != "" -> "  \u2502  \u2514\u2500\u2500 [#{condition}] \u2500\u2500>"
          edge_label != "" -> "  \u2502  \u2514\u2500\u2500 (#{edge_label}) \u2500\u2500>"
          true -> "  \u2502"
        end

      if condition != "" or edge_label != "" do
        info("#{arrow} #{target}")
      end
    end)

    # Simple down arrow for linear flow
    if outgoing != [] do
      has_simple_next = Enum.any?(outgoing, fn {_t, attrs} -> map_size(attrs) == 0 end)
      if has_simple_next, do: info("  \u2502")
    end
  end

  defp type_icon("start"), do: "\u25c7"
  defp type_icon("exit"), do: "\u25a0"
  defp type_icon("conditional"), do: "\u25c6"
  defp type_icon("tool"), do: "\u2699"
  defp type_icon("wait.human"), do: "\u270b"
  defp type_icon("parallel"), do: "\u2261"
  defp type_icon("parallel.fan_in"), do: "\u22c1"
  defp type_icon("file.write"), do: "\u270e"
  defp type_icon("pipeline.run"), do: "\u25b6"
  defp type_icon("pipeline.validate"), do: "\u2713"
  defp type_icon("codergen"), do: "\u2609"
  defp type_icon(_), do: "\u25cb"

  defp node_label(node, type) do
    prompt = Map.get(node.attrs, "prompt", "")
    tool_cmd = Map.get(node.attrs, "tool_command", "")

    cond do
      type == "start" -> "#{node.id} (start)"
      type == "exit" -> "#{node.id} (exit)"
      type == "tool" and tool_cmd != "" -> "#{node.id} (tool: #{truncate(tool_cmd, 40)})"
      type == "wait.human" -> "#{node.id} (human gate)"
      prompt != "" -> "#{node.id} (#{truncate(prompt, 50)})"
      true -> "#{node.id} (#{type})"
    end
  end

  # --- Mermaid Renderer ---

  defp render_mermaid(graph, file, typed) do
    IO.puts("```mermaid")
    IO.puts("---")
    IO.puts("title: #{graph.id}")
    IO.puts("---")
    IO.puts("graph TD")

    typed_info = if typed, do: build_typed_info(graph), else: nil

    # Render nodes
    Enum.each(graph.nodes, fn {id, node} ->
      type = Registry.node_type(node)
      shape = mermaid_shape(type)
      label = mermaid_label(node, type, typed_info)
      IO.puts("    #{id}#{shape.open}\"#{label}\"#{shape.close}")
    end)

    IO.puts("")

    # Render edges
    Enum.each(graph.edges, fn edge ->
      condition = Map.get(edge.attrs, "condition", "")
      label = Map.get(edge.attrs, "label", "")

      arrow =
        cond do
          condition != "" -> " -->|#{condition}| "
          label != "" -> " -->|#{label}| "
          true -> " --> "
        end

      IO.puts("    #{edge.from}#{arrow}#{edge.to}")
    end)

    IO.puts("```")
    IO.puts("")
    info("File: #{file}")
  end

  defp mermaid_shape("start"), do: %{open: "([", close: "])"}
  defp mermaid_shape("exit"), do: %{open: "[[", close: "]]"}
  defp mermaid_shape("conditional"), do: %{open: "{", close: "}"}
  defp mermaid_shape("tool"), do: %{open: "[/", close: "/]"}
  defp mermaid_shape("wait.human"), do: %{open: "{{", close: "}}"}
  defp mermaid_shape("parallel"), do: %{open: "[\\", close: "\\]"}
  defp mermaid_shape("parallel.fan_in"), do: %{open: "[\\", close: "\\]"}
  defp mermaid_shape(_), do: %{open: "[", close: "]"}

  defp mermaid_label(node, type, typed_info) do
    base = node_label(node, type)

    if typed_info do
      tn = Map.get(typed_info.nodes || %{}, node.id)

      if tn do
        "#{base}\\n#{tn.data_classification}"
      else
        base
      end
    else
      base
    end
  end

  # --- Shared Helpers ---

  defp build_adjacency(graph) do
    Enum.reduce(graph.edges, %{}, fn edge, acc ->
      Map.update(acc, edge.from, [{edge.to, edge.attrs}], fn existing ->
        [{edge.to, edge.attrs} | existing]
      end)
    end)
  end

  defp topo_sort(graph, adj) do
    # Find start nodes (no incoming edges)
    targets = graph.edges |> Enum.map(& &1.to) |> MapSet.new()
    all_ids = Map.keys(graph.nodes)
    start_nodes = Enum.filter(all_ids, &(not MapSet.member?(targets, &1)))

    # BFS from start nodes
    bfs(start_nodes, adj, MapSet.new(), [])
    |> Enum.reverse()
  end

  defp bfs([], _adj, _visited, result), do: result

  defp bfs([node | rest], adj, visited, result) do
    if MapSet.member?(visited, node) do
      bfs(rest, adj, visited, result)
    else
      new_visited = MapSet.put(visited, node)
      neighbors = adj |> Map.get(node, []) |> Enum.map(fn {to, _} -> to end)
      bfs(rest ++ neighbors, adj, new_visited, [node | result])
    end
  end

  defp build_typed_info(graph) do
    case Arbor.Orchestrator.compile(graph) do
      {:ok, typed} ->
        %{
          nodes: typed.nodes,
          capabilities: typed.capabilities_required,
          max_classification: typed.max_data_classification
        }

      {:error, _} ->
        nil
    end
  end

  defp truncate(str, max) do
    if String.length(str) > max do
      String.slice(str, 0, max) <> "..."
    else
      str
    end
  end
end
