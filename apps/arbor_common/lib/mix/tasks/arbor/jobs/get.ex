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
    fields = extract_job_fields(job)

    Mix.shell().info("""

    Job Details
    ═══════════════════════════════════════
      Job ID:      #{fields.job_id}
      Title:       #{fields.title}
      Status:      #{fields.status}
      Priority:    #{fields.priority}
      Tags:        #{fields.tags}
      Created:     #{fields.created_at}
      Updated:     #{fields.updated_at}
      Description: #{if fields.description == "", do: "(none)", else: fields.description}
    ═══════════════════════════════════════
    """)

    print_notes(fields.notes)

    if include_history do
      print_history(history || [])
    end
  end

  defp extract_job_fields(job) do
    %{
      job_id: job_field(job, :job_id, "unknown"),
      title: job_field(job, :title, "untitled"),
      status: job_field(job, :status, "unknown"),
      priority: job_field(job, :priority, "normal"),
      tags: format_tags(job["tags"] || job[:tags]),
      created_at: job_field(job, :created_at, "unknown"),
      updated_at: job_field(job, :updated_at, "unknown"),
      description: job_field(job, :description, ""),
      notes: job["notes"] || job[:notes] || []
    }
  end

  defp job_field(job, key, default) do
    to_string(job[to_string(key)] || job[key] || default)
  end

  defp print_notes([]), do: :ok

  defp print_notes(notes) do
    Mix.shell().info("  Notes")
    Mix.shell().info("  ───────────────────────────────────")

    Enum.each(notes, fn note ->
      at = to_string(note["at"] || note[:at] || "")
      text = to_string(note["text"] || note[:text] || "")
      Mix.shell().info("  #{at}  #{text}")
    end)

    Mix.shell().info("")
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
