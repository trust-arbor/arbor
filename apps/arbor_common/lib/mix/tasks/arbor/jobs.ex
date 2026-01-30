defmodule Mix.Tasks.Arbor.Jobs do
  @shortdoc "List jobs on the running Arbor server"
  @moduledoc """
  Lists jobs managed by the Arbor server.

      $ mix arbor.jobs
      $ mix arbor.jobs --status active
      $ mix arbor.jobs --tag deploy --limit 10

  Displays a formatted table of jobs showing ID, status, priority, and title.

  ## Options

    * `--status` - Filter by status (default: "all")
    * `--tag` - Filter by tag
    * `--limit` - Maximum number of jobs to return (default: 20)
  """
  use Mix.Task

  alias Mix.Tasks.Arbor.Helpers, as: Config

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [status: :string, tag: :string, limit: :integer]
      )

    status = opts[:status] || "all"
    tag = opts[:tag]
    limit = opts[:limit] || 20

    Config.ensure_distribution()

    unless Config.server_running?() do
      Mix.shell().error("Arbor is not running. Start it with: mix arbor.start")
      exit({:shutdown, 1})
    end

    node = Config.full_node_name()

    params = %{status: status, limit: limit}
    params = if tag, do: Map.put(params, :tag, tag), else: params

    case :rpc.call(node, Arbor.Actions.Jobs.ListJobs, :run, [params, %{}]) do
      {:badrpc, reason} ->
        Mix.shell().error("RPC failed: #{inspect(reason)}")
        exit({:shutdown, 1})

      {:ok, %{jobs: jobs}} when is_list(jobs) ->
        if jobs == [] do
          Mix.shell().info("No jobs found.")
        else
          print_table(jobs)
        end

      {:error, reason} ->
        Mix.shell().error("Failed to list jobs: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp print_table(jobs) do
    rows =
      Enum.map(jobs, fn job ->
        job_id = truncate_id(to_string(job["job_id"] || job[:job_id] || ""))
        status = to_string(job["status"] || job[:status] || "unknown")
        priority = to_string(job["priority"] || job[:priority] || "normal")
        title = to_string(job["title"] || job[:title] || "untitled")
        {job_id, status, priority, title}
      end)

    id_width = rows |> Enum.map(fn {id, _, _, _} -> String.length(id) end) |> Enum.max() |> max(6)

    status_width =
      rows |> Enum.map(fn {_, s, _, _} -> String.length(s) end) |> Enum.max() |> max(6)

    priority_width =
      rows |> Enum.map(fn {_, _, p, _} -> String.length(p) end) |> Enum.max() |> max(8)

    header =
      String.pad_trailing("Job ID", id_width) <>
        "  " <>
        String.pad_trailing("Status", status_width) <>
        "  " <>
        String.pad_trailing("Priority", priority_width) <>
        "  " <>
        "Title"

    separator = String.duplicate("─", String.length(header) + 2)

    Mix.shell().info("\n#{header}")
    Mix.shell().info(separator)

    Enum.each(rows, fn {id, status, priority, title} ->
      line =
        String.pad_trailing(id, id_width) <>
          "  " <>
          String.pad_trailing(status, status_width) <>
          "  " <>
          String.pad_trailing(priority, priority_width) <>
          "  " <>
          title

      Mix.shell().info(line)
    end)

    Mix.shell().info("")
  end

  defp truncate_id(id) when byte_size(id) > 12, do: String.slice(id, 0, 12)
  defp truncate_id(id), do: id
end
