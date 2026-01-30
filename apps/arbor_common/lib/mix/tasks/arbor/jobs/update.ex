defmodule Mix.Tasks.Arbor.Jobs.Update do
  @shortdoc "Update a job on the running Arbor server"
  @moduledoc """
  Updates a job on the running Arbor server.

      $ mix arbor.jobs.update job_abc123 --status active
      $ mix arbor.jobs.update job_abc123 --note "Deployment completed"
      $ mix arbor.jobs.update job_abc123 --status completed --note "All tests passed"

  The first positional argument is the job ID (required).
  At least one of `--status` or `--note` must be provided.

  ## Options

    * `--status` - New status for the job
    * `--note` - Note text to add to the job
  """
  use Mix.Task

  alias Mix.Tasks.Arbor.Helpers, as: Config

  @impl Mix.Task
  def run([]) do
    Mix.shell().error(
      "Usage: mix arbor.jobs.update JOB_ID [--status STATUS] [--note \"Note text\"]"
    )

    exit({:shutdown, 1})
  end

  def run(args) do
    {opts, positional, _} =
      OptionParser.parse(args,
        strict: [status: :string, note: :string],
        aliases: [s: :status, n: :note]
      )

    job_id =
      case positional do
        [id | _] ->
          id

        [] ->
          Mix.shell().error(
            "Usage: mix arbor.jobs.update JOB_ID [--status STATUS] [--note \"Note text\"]"
          )

          exit({:shutdown, 1})
      end

    status = opts[:status]
    note = opts[:note]

    unless status || note do
      Mix.shell().error("At least one of --status or --note must be provided.")

      Mix.shell().error(
        "Usage: mix arbor.jobs.update JOB_ID [--status STATUS] [--note \"Note text\"]"
      )

      exit({:shutdown, 1})
    end

    Config.ensure_distribution()

    unless Config.server_running?() do
      Mix.shell().error("Arbor is not running. Start it with: mix arbor.start")
      exit({:shutdown, 1})
    end

    node = Config.full_node_name()

    params = %{job_id: job_id}
    params = if status, do: Map.put(params, :status, status), else: params
    params = if note, do: Map.put(params, :note, note), else: params

    case :rpc.call(node, Arbor.Actions.Jobs.UpdateJob, :run, [params, %{}]) do
      {:badrpc, reason} ->
        Mix.shell().error("RPC failed: #{inspect(reason)}")
        exit({:shutdown, 1})

      {:ok, _result} ->
        print_success(job_id, status, note)

      {:error, :not_found} ->
        Mix.shell().error("Job not found: #{job_id}")
        exit({:shutdown, 1})

      {:error, reason} ->
        Mix.shell().error("Failed to update job: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp print_success(job_id, status, note) do
    truncated_id = truncate_id(job_id)

    cond do
      status && note ->
        Mix.shell().info("Updated #{truncated_id}: status -> #{status}, added note")

      status ->
        Mix.shell().info("Updated #{truncated_id}: status -> #{status}")

      note ->
        Mix.shell().info("Updated #{truncated_id}: added note")
    end
  end

  defp truncate_id(id) when byte_size(id) > 12, do: String.slice(id, 0, 12)
  defp truncate_id(id), do: id
end
