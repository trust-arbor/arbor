defmodule Mix.Tasks.Arbor.Pipeline.Run do
  @shortdoc "Execute a pipeline from a .dot file"
  @moduledoc """
  Parses, validates, and executes a pipeline with live progress display.

  ## Usage

      mix arbor.pipeline.run pipeline.dot
      mix arbor.pipeline.run pipeline.dot --logs-root /tmp/run1
      mix arbor.pipeline.run pipeline.dot --workdir ./my_project
  """

  use Mix.Task

  import Arbor.Orchestrator.Mix.Helpers

  @impl true
  def run(args) do
    {opts, files, _} =
      OptionParser.parse(args,
        strict: [logs_root: :string, workdir: :string]
      )

    Mix.Task.run("app.start")

    file = List.first(files)

    unless file do
      error("Usage: mix arbor.pipeline.run <file.dot> [--logs-root dir] [--workdir dir]")
      System.halt(1)
    end

    unless File.exists?(file) do
      error("File not found: #{file}")
      System.halt(1)
    end

    run_opts =
      opts
      |> Keyword.take([:logs_root, :workdir])
      |> Keyword.put(:on_event, &print_event/1)

    info("\nRunning pipeline: #{file}")
    info(String.duplicate("-", 40))

    case Arbor.Orchestrator.run_file(file, run_opts) do
      {:ok, result} ->
        info("")
        success("Pipeline completed successfully!")
        info("  Nodes completed: #{length(result.completed_nodes)}")
        info("  Final status: #{result.final_outcome && result.final_outcome.status}")

      {:error, reason} ->
        error("\nPipeline failed: #{inspect(reason)}")
        System.halt(1)
    end
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
end
