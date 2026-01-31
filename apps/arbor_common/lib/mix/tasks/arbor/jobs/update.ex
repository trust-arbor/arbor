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

    job_id = extract_job_id(positional)
    status = opts[:status]
    note = opts[:note]
    validate_update_opts(status, note)
    ensure_server_running()

    params = build_update_params(job_id, status, note)

    Config.full_node_name()
    |> :rpc.call(Arbor.Actions.Jobs.UpdateJob, :run, [params, %{}])
    |> handle_update_result(job_id, status, note)
  end

  defp extract_job_id([id | _]), do: id

  defp extract_job_id([]) do
    Mix.shell().error(
      "Usage: mix arbor.jobs.update JOB_ID [--status STATUS] [--note \"Note text\"]"
    )

    exit({:shutdown, 1})
  end

  defp validate_update_opts(nil, nil) do
    Mix.shell().error("At least one of --status or --note must be provided.")

    Mix.shell().error(
      "Usage: mix arbor.jobs.update JOB_ID [--status STATUS] [--note \"Note text\"]"
    )

    exit({:shutdown, 1})
  end

  defp validate_update_opts(_status, _note), do: :ok

  defp ensure_server_running do
    Config.ensure_distribution()

    unless Config.server_running?() do
      Mix.shell().error("Arbor is not running. Start it with: mix arbor.start")
      exit({:shutdown, 1})
    end
  end

  defp build_update_params(job_id, status, note) do
    %{job_id: job_id}
    |> maybe_put(:status, status)
    |> maybe_put(:note, note)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp handle_update_result({:ok, _result}, job_id, status, note) do
    print_success(job_id, status, note)
  end

  defp handle_update_result({:badrpc, reason}, _job_id, _status, _note) do
    Mix.shell().error("RPC failed: #{inspect(reason)}")
    exit({:shutdown, 1})
  end

  defp handle_update_result({:error, :not_found}, job_id, _status, _note) do
    Mix.shell().error("Job not found: #{job_id}")
    exit({:shutdown, 1})
  end

  defp handle_update_result({:error, reason}, _job_id, _status, _note) do
    Mix.shell().error("Failed to update job: #{inspect(reason)}")
    exit({:shutdown, 1})
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
