defmodule Mix.Tasks.Arbor.Pipeline.Resume do
  @shortdoc "Resume a pipeline from its last checkpoint"
  @moduledoc """
  Loads a checkpoint and the original pipeline, then resumes execution
  from the last completed node. Uses content-hash skip logic to avoid
  re-running nodes whose inputs haven't changed.

  ## Usage

      mix arbor.pipeline.resume pipeline.dot
      mix arbor.pipeline.resume pipeline.dot --checkpoint /path/to/checkpoint.json
      mix arbor.pipeline.resume pipeline.dot --logs-root /tmp/run1

  ## Options

    - `--checkpoint` — path to checkpoint.json (default: `<logs_root>/checkpoint.json`)
    - `--logs-root` — directory for pipeline logs (default: `/tmp/arbor_orchestrator/<graph_id>`)
    - `--workdir` — working directory for shell handlers
    - `--set key=value` — override context values (repeatable)
  """

  use Mix.Task

  import Arbor.Orchestrator.Mix.Helpers

  @impl true
  def run(args) do
    {opts, files, _} =
      OptionParser.parse(args,
        strict: [
          checkpoint: :string,
          logs_root: :string,
          workdir: :string,
          set: :keep
        ]
      )

    Mix.Task.run("compile")
    ensure_orchestrator_started()

    file = List.first(files)

    unless file do
      error("Usage: mix arbor.pipeline.resume <file.dot> [--checkpoint path] [--logs-root dir]")

      System.halt(1)
    end

    unless File.exists?(file) do
      error("File not found: #{file}")
      System.halt(1)
    end

    # Parse the pipeline
    case parse_dot_file(file) do
      {:ok, graph} ->
        resume_pipeline(graph, file, opts)

      {:error, _} ->
        System.halt(1)
    end
  end

  defp resume_pipeline(graph, file, opts) do
    logs_root = resolve_logs_root(graph, opts)
    checkpoint_path = Keyword.get(opts, :checkpoint, Path.join(logs_root, "checkpoint.json"))

    unless File.exists?(checkpoint_path) do
      error("Checkpoint not found: #{checkpoint_path}")
      error("Run the pipeline first with: mix arbor.pipeline.run #{file}")
      System.halt(1)
    end

    # Show checkpoint info
    case Arbor.Orchestrator.Engine.Checkpoint.load(checkpoint_path) do
      {:ok, checkpoint} ->
        info("\nResuming pipeline: #{file}")
        info("  Checkpoint: #{checkpoint_path}")
        info("  Last node: #{checkpoint.current_node}")
        info("  Completed: #{length(checkpoint.completed_nodes)} nodes")
        info("  Timestamp: #{checkpoint.timestamp}")

        skippable =
          Map.keys(checkpoint.content_hashes)
          |> Enum.count()

        if skippable > 0 do
          info("  Content hashes: #{skippable} (may skip unchanged nodes)")
        end

        info(String.duplicate("-", 40))

        # Build run opts with resume
        overrides = parse_set_opts(opts)

        run_opts =
          opts
          |> Keyword.take([:workdir])
          |> Keyword.put(:logs_root, logs_root)
          |> Keyword.put(:resume_from, checkpoint_path)
          |> Keyword.put(:on_event, &print_event/1)
          |> Keyword.put(:on_stream, &print_stream_event/1)

        run_opts =
          if overrides != %{} do
            Keyword.put(run_opts, :initial_values, overrides)
          else
            run_opts
          end

        case Arbor.Orchestrator.run_file(file, run_opts) do
          {:ok, result} ->
            info("")
            success("Pipeline resumed and completed!")
            info("  Nodes completed: #{length(result.completed_nodes)}")
            info("  Final status: #{result.final_outcome && result.final_outcome.status}")

          {:error, reason} ->
            error("\nPipeline failed: #{inspect(reason)}")
            System.halt(1)
        end

      {:error, reason} ->
        error("Failed to load checkpoint: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp resolve_logs_root(graph, opts) do
    case Keyword.get(opts, :logs_root) do
      nil ->
        graph_id = graph.id || "unknown"
        Path.join("/tmp/arbor_orchestrator", graph_id)

      path ->
        path
    end
  end

  defp parse_set_opts(opts) do
    opts
    |> Keyword.get_values(:set)
    |> Enum.reduce(%{}, fn pair, acc ->
      case String.split(pair, "=", parts: 2) do
        [key, value] -> Map.put(acc, key, maybe_parse_value(value))
        _ -> acc
      end
    end)
  end

  defp maybe_parse_value(value) do
    case Jason.decode(value) do
      {:ok, parsed} -> parsed
      {:error, _} -> value
    end
  end

  defp print_event(%{type: :pipeline_resumed, current_node: node}) do
    info("  ↩ Resuming from: #{node}")
  end

  defp print_event(%{type: :stage_skipped, node_id: id, reason: :content_hash_match}) do
    Mix.shell().info([:cyan, "  ⊘ #{id} (skipped — unchanged)"])
  end

  defp print_event(%{type: :stage_started, node_id: id}) do
    info("  ▶ #{id}")
  end

  defp print_event(%{type: :stage_completed, node_id: id, status: status}) do
    case status do
      :success -> Mix.shell().info([:green, "  ✓ #{id}"])
      :skipped -> Mix.shell().info([:yellow, "  ⊘ #{id} (skipped)"])
      other -> info("  • #{id} (#{other})")
    end
  end

  defp print_event(%{type: :stage_failed, node_id: id, error: error}) do
    Mix.shell().error([:red, "  ✗ #{id}: #{error}"])
  end

  defp print_event(%{type: :stage_retrying, node_id: id, attempt: attempt}) do
    warn("  ↻ #{id} (retry #{attempt})")
  end

  defp print_event(_), do: :ok

  defp print_stream_event(%{type: :tool_use, name: name}), do: IO.write(" [#{name}]")
  defp print_stream_event(%{type: :thinking}), do: IO.write(".")
  defp print_stream_event(_), do: :ok
end
