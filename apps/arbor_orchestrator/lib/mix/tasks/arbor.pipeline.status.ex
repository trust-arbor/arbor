defmodule Mix.Tasks.Arbor.Pipeline.Status do
  @moduledoc """
  Show status of running and recently completed pipelines.

  ## Usage

      mix arbor.pipeline.status          # Read from JobRegistry
      mix arbor.pipeline.status --scan   # Scan checkpoint files instead
      mix arbor.pipeline.status --json   # Output as JSON

  ## Options

    * `--scan` - Scan /tmp checkpoint files instead of reading from registry
    * `--json` - Output as JSON
  """

  use Mix.Task

  import Arbor.Orchestrator.Mix.Helpers

  @shortdoc "Show pipeline execution status"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: [scan: :boolean, json: :boolean])

    if opts[:scan] do
      scan_checkpoints(opts)
    else
      ensure_orchestrator_started()
      read_registry(opts)
    end
  end

  # ===========================================================================
  # Registry Mode
  # ===========================================================================

  defp read_registry(opts) do
    active = Arbor.Orchestrator.JobRegistry.list_active()
    recent = Arbor.Orchestrator.JobRegistry.list_recent()

    if opts[:json] do
      output_json(%{active: active, recent: recent})
    else
      output_tables(active, recent)
    end
  end

  defp output_tables(active, recent) do
    if active == [] do
      info("\n=== Active Pipelines ===\n")
      info("No pipelines currently running.\n")
    else
      info("\n=== Active Pipelines ===\n")

      headers = ["Pipeline", "Progress", "Current Node", "Elapsed"]

      rows =
        Enum.map(active, fn entry ->
          elapsed =
            if entry.started_at do
              seconds = DateTime.diff(DateTime.utc_now(), entry.started_at, :second)
              format_duration(seconds * 1000)
            else
              "-"
            end

          progress = "#{entry.completed_count || 0}/#{entry.total_nodes || "?"}"
          pipeline = entry.graph_id || entry.pipeline_id || "unknown"
          current = entry.current_node || "-"

          [pipeline, progress, current, elapsed]
        end)

      table(headers, rows)
      info("")
    end

    if recent == [] do
      info("\n=== Recent Pipelines ===\n")
      info("No recently completed pipelines.\n")
    else
      info("\n=== Recent Pipelines ===\n")

      headers = ["Pipeline", "Status", "Duration", "Finished"]

      rows =
        Enum.map(recent, fn entry ->
          status_str = format_status(entry.status)
          duration = if entry.duration_ms, do: format_duration(entry.duration_ms), else: "-"

          finished =
            if entry.finished_at do
              Calendar.strftime(entry.finished_at, "%Y-%m-%d %H:%M:%S")
            else
              "-"
            end

          pipeline = entry.graph_id || entry.pipeline_id || "unknown"

          # Return the row with colored status
          [pipeline, status_str, duration, finished]
        end)

      table(headers, rows)
      info("")
    end
  end

  defp format_status(:completed), do: "✓ completed"
  defp format_status(:failed), do: "✗ failed"
  defp format_status(:running), do: "▶ running"
  defp format_status(other), do: to_string(other)

  defp format_duration(ms) when is_integer(ms) do
    cond do
      ms < 1000 -> "#{ms}ms"
      ms < 60_000 -> "#{div(ms, 1000)}s"
      ms < 3_600_000 -> "#{div(ms, 60_000)}m #{rem(div(ms, 1000), 60)}s"
      true -> "#{div(ms, 3_600_000)}h #{rem(div(ms, 60_000), 60)}m"
    end
  end

  defp format_duration(_), do: "-"

  # ===========================================================================
  # Scan Mode
  # ===========================================================================

  defp scan_checkpoints(opts) do
    base_dir = Path.join(System.tmp_dir!(), "arbor_orchestrator")

    unless File.dir?(base_dir) do
      info("No checkpoint directory found at #{base_dir}")
      System.halt(0)
    end

    pipelines = find_pipeline_checkpoints(base_dir)

    if pipelines == [] do
      info("\nNo pipeline checkpoints found in #{base_dir}\n")
    else
      if opts[:json] do
        output_json(%{pipelines: pipelines})
      else
        output_checkpoint_table(pipelines)
      end
    end
  end

  defp find_pipeline_checkpoints(base_dir) do
    base_dir
    |> File.ls!()
    |> Enum.filter(fn name ->
      subdir = Path.join(base_dir, name)
      File.dir?(subdir) && File.exists?(Path.join(subdir, "manifest.json"))
    end)
    |> Enum.map(fn name ->
      subdir = Path.join(base_dir, name)
      read_checkpoint_data(name, subdir)
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp read_checkpoint_data(pipeline_id, dir) do
    manifest_path = Path.join(dir, "manifest.json")
    checkpoint_path = Path.join(dir, "checkpoint.json")

    with {:ok, manifest_json} <- File.read(manifest_path),
         {:ok, manifest} <- Jason.decode(manifest_json),
         checkpoint <- read_checkpoint(checkpoint_path) do
      %{
        pipeline_id: pipeline_id,
        graph_id: manifest["graph_id"],
        goal: manifest["goal"],
        started_at: parse_datetime(manifest["started_at"]),
        completed_nodes: get_in(checkpoint, ["completed_nodes"]) || [],
        current_node: get_in(checkpoint, ["current_node"])
      }
    else
      _ -> nil
    end
  end

  defp read_checkpoint(path) do
    case File.read(path) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, data} -> data
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp output_checkpoint_table(pipelines) do
    info("\n=== Pipeline Checkpoints (from #{System.tmp_dir!()}/arbor_orchestrator) ===\n")

    headers = ["Pipeline ID", "Graph ID", "Completed Nodes", "Current Node", "Started"]

    rows =
      Enum.map(pipelines, fn pipeline ->
        completed_count = length(pipeline.completed_nodes)

        started =
          if pipeline.started_at do
            Calendar.strftime(pipeline.started_at, "%Y-%m-%d %H:%M:%S")
          else
            "-"
          end

        [
          pipeline.pipeline_id,
          pipeline.graph_id || "-",
          "#{completed_count}",
          pipeline.current_node || "-",
          started
        ]
      end)

    table(headers, rows)
    info("")
  end

  # ===========================================================================
  # JSON Output
  # ===========================================================================

  defp output_json(data) do
    case Jason.encode(data, pretty: true) do
      {:ok, json} ->
        info(json)

      {:error, reason} ->
        error("Failed to encode JSON: #{inspect(reason)}")
        System.halt(1)
    end
  end
end
