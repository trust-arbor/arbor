defmodule Mix.Tasks.Arbor.Jobs.Get do
  @shortdoc "Get details of a specific job"
  @moduledoc """
  Retrieves and displays details for a specific job on the running Arbor server.

      $ mix arbor.jobs.get job_abc123
      $ mix arbor.jobs.get job_abc123 --history

  The first positional argument is the job ID (required).

  ## Options

    * `--history` - Include event history timeline
  """
  use Mix.Task

  alias Mix.Tasks.Arbor.Helpers, as: Config

  @impl Mix.Task
  def run([]) do
    Mix.shell().error("Usage: mix arbor.jobs.get JOB_ID [--history]")
    exit({:shutdown, 1})
  end

  def run(args) do
    {opts, positional, _} =
      OptionParser.parse(args,
        strict: [history: :boolean]
      )

    job_id =
      case positional do
        [id | _] ->
          id

        [] ->
          Mix.shell().error("Usage: mix arbor.jobs.get JOB_ID [--history]")
          exit({:shutdown, 1})
      end

    include_history = opts[:history] || false

    Config.ensure_distribution()

    unless Config.server_running?() do
      Mix.shell().error("Arbor is not running. Start it with: mix arbor.start")
      exit({:shutdown, 1})
    end

    node = Config.full_node_name()

    params = %{job_id: job_id, include_history: include_history}

    case :rpc.call(node, Arbor.Actions.Jobs.GetJob, :run, [params, %{}]) do
      {:badrpc, reason} ->
        Mix.shell().error("RPC failed: #{inspect(reason)}")
        exit({:shutdown, 1})

      {:ok, %{job: job} = result} when is_map(job) ->
        print_job(job, result[:history], include_history)

      {:error, :not_found} ->
        Mix.shell().error("Job not found: #{job_id}")
        exit({:shutdown, 1})

      {:error, reason} ->
        Mix.shell().error("Failed to get job: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp print_job(job, history, include_history) do
    job_id = to_string(job["job_id"] || job[:job_id] || "unknown")
    title = to_string(job["title"] || job[:title] || "untitled")
    status = to_string(job["status"] || job[:status] || "unknown")
    priority = to_string(job["priority"] || job[:priority] || "normal")
    tags = format_tags(job["tags"] || job[:tags])
    created_at = to_string(job["created_at"] || job[:created_at] || "unknown")
    updated_at = to_string(job["updated_at"] || job[:updated_at] || "unknown")
    description = to_string(job["description"] || job[:description] || "")

    notes = job["notes"] || job[:notes] || []

    Mix.shell().info("""

    Job Details
    ═══════════════════════════════════════
      Job ID:      #{job_id}
      Title:       #{title}
      Status:      #{status}
      Priority:    #{priority}
      Tags:        #{tags}
      Created:     #{created_at}
      Updated:     #{updated_at}
      Description: #{if description == "", do: "(none)", else: description}
    ═══════════════════════════════════════
    """)

    if notes != [] do
      Mix.shell().info("  Notes")
      Mix.shell().info("  ───────────────────────────────────")

      Enum.each(notes, fn note ->
        at = to_string(note["at"] || note[:at] || "")
        text = to_string(note["text"] || note[:text] || "")
        Mix.shell().info("  #{at}  #{text}")
      end)

      Mix.shell().info("")
    end

    if include_history do
      print_history(history || [])
    end
  end

  defp print_history([]) do
    Mix.shell().info("  No history events.\n")
  end

  defp print_history(events) when is_list(events) do
    Mix.shell().info("  History")
    Mix.shell().info("  ───────────────────────────────────")

    Enum.each(events, fn event ->
      timestamp = to_string(event["timestamp"] || event[:timestamp] || "")
      type = to_string(event["type"] || event[:type] || "")

      line = "  #{timestamp}  #{type}"
      Mix.shell().info(line)
    end)

    Mix.shell().info("")
  end

  defp format_tags(nil), do: "none"
  defp format_tags([]), do: "none"
  defp format_tags(tags) when is_list(tags), do: Enum.join(tags, ", ")
  defp format_tags(tags), do: to_string(tags)
end
