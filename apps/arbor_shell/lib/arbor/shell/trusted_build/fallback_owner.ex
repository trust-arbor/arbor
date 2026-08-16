defmodule Arbor.Shell.TrustedBuild.FallbackOwner do
  @moduledoc false

  alias Arbor.Shell.TrustedBuild.Lease

  @go_timeout_ms 5_000

  @spec run(pid()) :: :ok
  def run(lease_pid) when is_pid(lease_pid) do
    {permit, result} =
      receive do
        {:trusted_build_fallback_go, permit} when is_reference(permit) ->
          {permit, claim_and_run(lease_pid, permit)}
      after
        @go_timeout_ms ->
          {nil, {:error, :trusted_build_launch_unauthorized}}
      end

    send(lease_pid, {:trusted_build_fallback_done, self(), permit, result})
    :ok
  end

  def run(_lease_pid), do: :ok

  defp claim_and_run(lease_pid, permit) do
    case Lease.checkout_fallback(lease_pid, permit) do
      {:ok, descriptor} ->
        run_descriptor(descriptor)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_descriptor(%{fault: :force_kill_helper_failure}) do
    {:error, {:kill_helper_failed, :forced}}
  end

  defp run_descriptor(%{launcher: launcher, group_id: group_id, grace_ms: grace_ms})
       when is_binary(launcher) and is_integer(group_id) and group_id > 0 and
              is_integer(grace_ms) and grace_ms > 0 do
    if File.regular?(launcher) do
      await_kill_port(launcher, group_id, grace_ms)
    else
      {:error, :launcher_unavailable}
    end
  end

  defp run_descriptor(_descriptor), do: {:error, :trusted_build_launch_unauthorized}

  defp await_kill_port(launcher, group_id, grace_ms) do
    port =
      Port.open({:spawn_executable, to_charlist(launcher)}, [
        :binary,
        :exit_status,
        args: [
          ~c"kill",
          Integer.to_charlist(group_id),
          Integer.to_charlist(grace_ms)
        ]
      ])

    receive do
      {^port, {:exit_status, 0}} ->
        :ok

      {^port, {:exit_status, status}} ->
        {:error, {:kill_helper_failed, status}}
    after
      grace_ms + 500 ->
        close_port(port)
        {:error, :kill_helper_timeout}
    end
  catch
    :error, reason -> {:error, {:kill_helper_failed, reason}}
  end

  defp close_port(port) do
    Port.close(port)
  catch
    :error, _ -> :ok
  end
end
