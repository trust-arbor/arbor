defmodule Mix.Tasks.Arbor.Scheduler.Provision do
  @shortdoc "Grant the dormant scheduler identity its operator-provisioned capabilities"

  @moduledoc """
  Inspect or provision the scheduler principal on the running Arbor server.

      mix arbor.scheduler.provision --status
      mix arbor.scheduler.provision --key-file ~/.arbor/operator.key

  The scheduler never grants itself authority. Until an operator grants its
  principal every required capability, it stays **dormant**: Arbor boots
  normally, but Oban runs in standby, so jobs can be enqueued and nothing
  executes or fires from cron. On a fresh install, run this after genesis
  (`mix arbor.user.init`) with the operator key file that genesis made an
  administrator.

  Each missing capability is granted by an exact, one-use request signed in
  this process from the key file. Only the signed proof crosses to the
  server, which never opens a caller-nominated path. The task then asks the
  scheduler to re-check and leave standby.
  """

  use Mix.Task

  alias Mix.Tasks.Arbor.Helpers, as: Config

  @switches [key_file: :string, status: :boolean]
  @usage "usage: mix arbor.scheduler.provision --status | --key-file PATH"

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] or positional != [], do: Mix.raise(@usage)

    Config.ensure_distribution()

    unless Config.server_running?() do
      Mix.shell().error("Arbor server is not running. Start it with: mix arbor.start")
      exit({:shutdown, 1})
    end

    cond do
      opts[:status] -> print_status(rpc(Arbor.Scheduler, :identity_status, []))
      is_binary(opts[:key_file]) -> provision(Path.expand(opts[:key_file]))
      true -> Mix.raise(@usage)
    end
  end

  defp provision(key_path) do
    status = rpc(Arbor.Scheduler, :identity_status, [])

    principal_id =
      case status do
        %{principal_id: principal_id} when is_binary(principal_id) -> principal_id
        _ -> Mix.raise("scheduler identity is unavailable: #{inspect(status)}")
      end

    Enum.each(status.missing_capabilities, &grant!(principal_id, &1, key_path))

    case rpc(Arbor.Scheduler, :activate, []) do
      {:ok, status} -> print_status(status)
      {:error, reason} -> Mix.raise("scheduler did not activate: #{inspect(reason)}")
    end
  end

  defp grant!(principal_id, resource, key_path) do
    grant_opts = [
      principal: principal_id,
      resource: resource,
      delegation_depth: 0,
      metadata: %{source: :scheduler_operator_provisioning}
    ]

    with {:ok, capability, proof} <- prepare_grant(key_path, grant_opts),
         {:ok, _capability} <-
           rpc(Arbor.Security, :submit_signed_capability_grant, [capability, proof]) do
      Mix.shell().info("  granted #{resource}")
    else
      {:error, {:read_failed, reason}} ->
        Mix.raise("cannot read operator key file #{key_path}: #{inspect(reason)}")

      {:error, reason} ->
        Mix.raise("grant of #{resource} to #{principal_id} denied: #{inspect(reason)}")
    end
  end

  # The facade reads an already-open device and never opens a path itself.
  defp prepare_grant(key_path, grant_opts) do
    case :file.open(String.to_charlist(key_path), [:read, :raw, :binary]) do
      {:ok, io_device} ->
        try do
          Arbor.Security.prepare_key_file_capability_grant(io_device, grant_opts)
        after
          :file.close(io_device)
        end

      {:error, reason} ->
        {:error, {:read_failed, reason}}
    end
  end

  defp print_status(status) do
    Mix.shell().info("""
    Scheduler identity: #{status.state}
      Principal:  #{status.principal_id || "(none)"}
      Missing:    #{format_missing(status.missing_capabilities)}
      Oban:       #{status.oban}
    """)
  end

  defp format_missing([]), do: "none"
  defp format_missing(missing), do: Enum.join(missing, ", ")

  defp rpc(mod, fun, args), do: Config.rpc!(Config.full_node_name(), mod, fun, args)
end
