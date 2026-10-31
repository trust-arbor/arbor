defmodule Mix.Tasks.Arbor.Trust.GrantOwner do
  @moduledoc """
  Inspect or provision the supervised Trust JIT capability-grant owner.

      mix arbor.trust.grant_owner status
      mix arbor.trust.grant_owner provision --key-file /path/to/operator.arbor.key

  Provisioning grants the owner only its fixed mutation capability. The grant is
  authorized by the operator key file's exact signed one-use request; private
  key bytes never leave the Security key-file boundary.
  """

  use Mix.Task

  @shortdoc "Inspect or provision the Trust JIT grant owner"
  @switches [key_file: :string]

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    Mix.Task.run("app.start")

    case positional do
      ["status"] -> print_status(Arbor.Trust.capability_grant_owner_status())
      ["provision"] -> provision(Keyword.get(opts, :key_file))
      _ -> Mix.raise("usage: mix arbor.trust.grant_owner status | provision --key-file PATH")
    end
  end

  defp provision(path) when is_binary(path) and path != "" do
    status = Arbor.Trust.capability_grant_owner_status()

    principal_id =
      case status do
        %{principal_id: principal_id} when is_binary(principal_id) -> principal_id
        _ -> Mix.raise("grant owner identity is unavailable: #{inspect(status.reason)}")
      end

    grant_opts = [
      principal: principal_id,
      resource: Arbor.Trust.CapabilityGrantOwner.required_capability_uri(),
      delegation_depth: 0,
      metadata: %{source: :trust_grant_owner_operator_provisioning}
    ]

    result =
      File.open(path, [:read, :binary], fn io_device ->
        with {:ok, capability, proof} <-
               Arbor.Security.prepare_key_file_capability_grant(io_device, grant_opts) do
          Arbor.Security.submit_signed_capability_grant(capability, proof)
        end
      end)

    case result do
      {:ok, {:ok, _capability}} ->
        print_status(restart_capability_grant_owner!())

      {:ok, {:error, reason}} ->
        Mix.raise("grant owner provisioning denied: #{inspect(reason)}")

      {:error, reason} ->
        Mix.raise("cannot open operator key file: #{inspect(reason)}")
    end
  end

  defp provision(_path), do: Mix.raise("provision requires --key-file PATH")

  defp restart_capability_grant_owner! do
    with {:ok, supervisor} <-
           Arbor.Common.supervised_registered_child_pid(
             :arbor_trust,
             [Arbor.Trust.Supervisor],
             Arbor.Trust.Supervisor
           ),
         :ok <- Supervisor.terminate_child(supervisor, Arbor.Trust.CapabilityGrantOwner),
         {:ok, _pid} <- Supervisor.restart_child(supervisor, Arbor.Trust.CapabilityGrantOwner) do
      Arbor.Trust.capability_grant_owner_status()
    else
      error -> Mix.raise("cannot restart supervised grant owner: #{inspect(error)}")
    end
  end

  defp print_status(status) do
    Mix.shell().info("state: #{status.state}")
    Mix.shell().info("principal_id: #{status.principal_id || "unavailable"}")
    Mix.shell().info("required_capability: #{status.required_capability}")

    if status.reason do
      Mix.shell().info("reason: #{inspect(status.reason)}")
    end
  end
end
