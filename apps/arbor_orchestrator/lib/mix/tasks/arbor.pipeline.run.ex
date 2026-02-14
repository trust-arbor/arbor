defmodule Mix.Tasks.Arbor.Pipeline.Run do
  @shortdoc "Execute a pipeline from a .dot file"
  @moduledoc """
  Parses, validates, and executes a pipeline with live progress display.

  ## Usage

      mix arbor.pipeline.run pipeline.dot
      mix arbor.pipeline.run pipeline.dot --set eval.model=kimi-k2.5:cloud --set eval.provider=ollama
      mix arbor.pipeline.run pipeline.dot --logs-root /tmp/run1
      mix arbor.pipeline.run pipeline.dot --workdir ./my_project

  ## Options

    - `--set key=value` — set initial context values (repeatable)
    - `--logs-root` — directory for pipeline logs
    - `--workdir` — working directory for shell handlers
  """

  use Mix.Task

  import Arbor.Orchestrator.Mix.Helpers

  @impl true
  def run(args) do
    {opts, files, _} =
      OptionParser.parse(args,
        strict: [logs_root: :string, workdir: :string, set: :keep]
      )

    # Start only the orchestrator and its deps — not the full umbrella.
    # This avoids port conflicts when the dev server is already running
    # (e.g., gateway's :ranch listener on port 4002).
    Mix.Task.run("compile")
    ensure_orchestrator_started()

    file = List.first(files)

    unless file do
      error(
        "Usage: mix arbor.pipeline.run <file.dot> [--set key=value ...] [--logs-root dir] [--workdir dir]"
      )

      System.halt(1)
    end

    unless File.exists?(file) do
      error("File not found: #{file}")
      System.halt(1)
    end

    initial_values = parse_set_opts(opts)

    run_opts =
      opts
      |> Keyword.take([:logs_root, :workdir])
      |> Keyword.put(:on_event, &print_event/1)
      |> Keyword.put(:on_stream, &print_stream_event/1)

    run_opts =
      if initial_values != %{} do
        Keyword.put(run_opts, :initial_values, initial_values)
      else
        run_opts
      end

    info("\nRunning pipeline: #{file}")

    if initial_values != %{} do
      info("  Initial values:")

      Enum.each(Enum.sort(initial_values), fn {k, v} ->
        info("    #{k} = #{v}")
      end)
    end

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

  defp parse_set_opts(opts) do
    opts
    |> Keyword.get_values(:set)
    |> Enum.reduce(%{}, fn pair, acc ->
      case String.split(pair, "=", parts: 2) do
        [key, value] ->
          Map.put(acc, key, maybe_parse_value(value))

        _ ->
          warn("Ignoring malformed --set: #{pair} (expected key=value)")
          acc
      end
    end)
  end

  # Try to parse JSON values so --set foo=42 gives an integer, --set bar=true gives a boolean,
  # and --set list=[1,2,3] gives a list. Plain strings stay as strings.
  defp maybe_parse_value(value) do
    case Jason.decode(value) do
      {:ok, parsed} -> parsed
      {:error, _} -> value
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

  defp print_stream_event(%{type: :tool_use, name: name}) do
    IO.write(" [#{name}]")
  end

  defp print_stream_event(%{type: :thinking}) do
    IO.write(".")
  end

  defp print_stream_event(_), do: :ok
end
