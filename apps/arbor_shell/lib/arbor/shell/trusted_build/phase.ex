defmodule Arbor.Shell.TrustedBuild.Phase do
  @moduledoc false

  alias Arbor.Shell.Executor
  alias Arbor.Shell.OwnedTreeRegistry
  alias Arbor.Shell.TrustedBuild.Identity
  alias Arbor.Shell.TrustedBuild.Lease
  alias Arbor.Shell.TrustedBuild.Plan
  alias Arbor.Shell.TrustedBuildToolchainAuthority

  @spec run(map()) :: {:ok, map()} | {:error, term()}
  def run(session) when is_map(session) do
    caller = self()
    reply_ref = make_ref()

    phase_pid =
      spawn(fn ->
        result =
          try do
            run_monitored(session)
          catch
            kind, reason -> {:error, {:trusted_build_phase_exception, {kind, reason}}}
          end

        _ = Lease.commit_phase_result(session.lease_pid, result)
        send(caller, {:"$arbor_trusted_build_phase", reply_ref, result})
      end)

    case Lease.attach_phase(session.lease, phase_pid) do
      :ok ->
        await_phase(phase_pid, reply_ref, session.cancel_id)

      {:error, reason} ->
        Process.exit(phase_pid, :kill)
        _ = Lease.abort_unattached_phase(session.lease)
        {:error, reason}
    end
  end

  def run(_session), do: {:error, :invalid_trusted_build_session}

  defp await_phase(phase_pid, reply_ref, cancel_id) do
    mon = Process.monitor(phase_pid)

    receive do
      {:"$arbor_trusted_build_phase", ^reply_ref, result} ->
        Process.demonitor(mon, [:flush])
        result

      {:DOWN, ^mon, :process, ^phase_pid, reason} ->
        receive do
          {:"$arbor_trusted_build_phase", ^reply_ref, result} -> result
        after
          0 -> {:error, {:trusted_build_phase_failed, reason}}
        end

      {:cancel_shell_execution, ^cancel_id} ->
        send(phase_pid, {:cancel_shell_execution, cancel_id})
        await_phase(phase_pid, reply_ref, cancel_id)
    end
  end

  defp run_monitored(session) do
    owner_mon = Process.monitor(session.owner_pid)
    authority_mon = Process.monitor(session.authority_pid)

    cond do
      down?(owner_mon, session.owner_pid) ->
        {:error, :trusted_build_owner_lost}

      down?(authority_mon, session.authority_pid) ->
        {:error, :trusted_build_toolchain_unavailable}

      true ->
        launch(session, owner_mon, authority_mon)
    end
  end

  defp launch(session, owner_mon, authority_mon) do
    with :ok <- observe(owner_mon, session.owner_pid, authority_mon, session.authority_pid),
         {:ok, _binding, _pid, gen} <-
           TrustedBuildToolchainAuthority.checkout_generation(
             session.authority_pid,
             session.authority_gen
           ),
         true <- gen == session.authority_gen,
         {:ok, _reg_pid, reg_gen} <- OwnedTreeRegistry.checkout(),
         true <- reg_gen == session.registry_gen,
         {:ok, descriptor} <- Lease.checkout_launch(session.lease_pid, session.launch_ticket),
         :ok <- maybe_crash(descriptor),
         :ok <- last_boundary(descriptor),
         :ok <- observe(owner_mon, session.owner_pid, authority_mon, session.authority_pid) do
      Executor.run_trusted_build(session.lease_pid, descriptor.launch_permit)
    else
      false -> {:error, :trusted_build_toolchain_generation_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_crash(%{fault: :crash_phase}), do: raise("trusted_build_phase_crash")
  defp maybe_crash(_descriptor), do: :ok

  defp last_boundary(descriptor) do
    with :ok <- Identity.verify_file(descriptor.wrapper),
         :ok <- Identity.verify_directory(descriptor.source),
         :ok <- Identity.verify_file(descriptor.erl),
         :ok <- Identity.verify_file(descriptor.elixir),
         :ok <- Identity.verify_file(descriptor.elixir_mix),
         :ok <- Identity.verify_directory(descriptor.erlang_root),
         :ok <- Identity.verify_directory(descriptor.elixir_root),
         :ok <- verify_archives(descriptor.archives, descriptor.archives_digest),
         :ok <- Identity.verify_owned_identity(descriptor.source_owned),
         :ok <- Identity.verify_ancestry(descriptor.source, descriptor.wrapper, ["bin", "mix"]),
         :ok <-
           Identity.verify_ancestry(descriptor.erlang_root, descriptor.erl, ["bin", "erl"]),
         :ok <-
           Identity.verify_ancestry(descriptor.elixir_root, descriptor.elixir, ["bin", "elixir"]),
         :ok <-
           Identity.verify_ancestry(descriptor.elixir_root, descriptor.elixir_mix, ["bin", "mix"]),
         :ok <-
           Identity.verify_ancestry(descriptor.source_owned, descriptor.source, ["source"]),
         :ok <- verify_writables(descriptor.roots) do
      :ok
    end
  end

  defp verify_archives(dir, digest) do
    with :ok <- Identity.verify_directory(dir),
         {:ok, ^digest} <- Identity.tree_digest(dir.path) do
      :ok
    else
      {:ok, _other} -> {:error, :trusted_build_wrapper_identity_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_writables(roots) do
    Enum.reduce_while(Plan.writable_names(), :ok, fn name, :ok ->
      key = String.to_existing_atom(name)

      case Identity.verify_writable(Map.fetch!(roots, key)) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp observe(owner_mon, owner, authority_mon, authority) do
    cond do
      down?(owner_mon, owner) -> {:error, :trusted_build_owner_lost}
      down?(authority_mon, authority) -> {:error, :trusted_build_toolchain_unavailable}
      true -> :ok
    end
  end

  defp down?(mon, pid) do
    receive do
      {:DOWN, ^mon, :process, ^pid, _reason} -> true
    after
      0 -> false
    end
  end
end
