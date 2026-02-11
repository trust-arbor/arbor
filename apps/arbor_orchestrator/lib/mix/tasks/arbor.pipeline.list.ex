defmodule Mix.Tasks.Arbor.Pipeline.List do
  @shortdoc "List available pipeline specs with metadata"
  @moduledoc """
  Discovers and summarizes available .dot pipeline files.

  ## Usage

      mix arbor.pipeline.list
      mix arbor.pipeline.list --dir specs/pipelines
      mix arbor.pipeline.list --json
  """

  use Mix.Task

  import Arbor.Orchestrator.Mix.Helpers

  @default_dir "specs/pipelines"

  @impl true
  def run(args) do
    {opts, _files, _} = OptionParser.parse(args, strict: [dir: :string, json: :boolean])

    ensure_orchestrator_started()

    dir = Keyword.get(opts, :dir, @default_dir)
    json_output = Keyword.get(opts, :json, false)

    unless File.dir?(dir) do
      error("Directory not found: #{dir}")
      System.halt(1)
    end

    files =
      dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".dot"))
      |> Enum.sort()

    if files == [] do
      info("No .dot files found in #{dir}")
      :ok
    else
      pipelines = Enum.map(files, fn file -> analyze_file(Path.join(dir, file), file) end)

      if json_output do
        output_json(pipelines)
      else
        output_table(pipelines, dir)
      end
    end
  end

  defp analyze_file(path, filename) do
    case File.read(path) do
      {:ok, source} ->
        case Arbor.Orchestrator.parse(source) do
          {:ok, graph} ->
            node_count = map_size(graph.nodes)
            edge_count = length(graph.edges)
            goal = Map.get(graph.attrs, "goal", "")

            # Count node types
            type_counts =
              graph.nodes
              |> Map.values()
              |> Enum.map(fn node ->
                Arbor.Orchestrator.Handlers.Registry.node_type(node)
              end)
              |> Enum.frequencies()

            %{
              filename: filename,
              id: graph.id,
              goal: goal,
              nodes: node_count,
              edges: edge_count,
              type_counts: type_counts,
              valid: true,
              error: nil
            }

          {:error, reason} ->
            %{
              filename: filename,
              id: nil,
              goal: "",
              nodes: 0,
              edges: 0,
              type_counts: %{},
              valid: false,
              error: inspect(reason)
            }
        end

      {:error, reason} ->
        %{
          filename: filename,
          id: nil,
          goal: "",
          nodes: 0,
          edges: 0,
          type_counts: %{},
          valid: false,
          error: inspect(reason)
        }
    end
  end

  defp output_table(pipelines, dir) do
    info("Pipelines in #{dir}/\n")

    total_nodes = Enum.sum(Enum.map(pipelines, & &1.nodes))
    total_edges = Enum.sum(Enum.map(pipelines, & &1.edges))

    Enum.each(pipelines, fn p ->
      if p.valid do
        success("  #{p.filename}")
        info("    id: #{p.id}")

        if p.goal != "" do
          info("    goal: #{truncate(p.goal, 70)}")
        end

        type_summary =
          p.type_counts
          |> Enum.sort_by(fn {_type, count} -> -count end)
          |> Enum.map(fn {type, count} -> "#{count} #{type}" end)
          |> Enum.join(", ")

        info("    nodes: #{p.nodes} (#{type_summary})")
        info("    edges: #{p.edges}")
      else
        error("  ✗ #{p.filename} — #{p.error}")
      end

      info("")
    end)

    info("  Total: #{length(pipelines)} pipelines, #{total_nodes} nodes, #{total_edges} edges")
  end

  defp output_json(pipelines) do
    data =
      Enum.map(pipelines, fn p ->
        %{
          filename: p.filename,
          id: p.id,
          goal: p.goal,
          nodes: p.nodes,
          edges: p.edges,
          type_counts: p.type_counts,
          valid: p.valid,
          error: p.error
        }
      end)

    IO.puts(Jason.encode!(data, pretty: true))
  end

  defp truncate(str, max) do
    if String.length(str) > max do
      String.slice(str, 0, max) <> "..."
    else
      str
    end
  end
end
