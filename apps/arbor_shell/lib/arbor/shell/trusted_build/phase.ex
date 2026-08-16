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

        send(caller, {:"$arbor_trusted_build_phase", reply_ref, result})
      end)

    case Lease.attach_phase(session.lease, phase_pid) do
      :ok ->
        await_phase(phase_pid, reply_ref, session.cancel_id)

      {:error, reason} ->
        Process.exit(phase_pid, :kill)
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
         :ok <- last_boundary(session),
         :ok <- observe(owner_mon, session.owner_pid, authority_mon, session.authority_pid) do
      Executor.run_trusted_build(session)
    else
      false -> {:error, :trusted_build_toolchain_generation_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp last_boundary(session) do
    identities = session.identities
    roots = session.roots
    binding = session.binding

    with :ok <- Identity.verify_file(identities.wrapper),
         :ok <- Identity.verify_directory(identities.source),
         :ok <- Identity.verify_file(binding.erl),
         :ok <- Identity.verify_file(binding.elixir),
         :ok <- Identity.verify_file(binding.elixir_mix),
         :ok <- Identity.verify_directory(binding.erlang_root),
         :ok <- Identity.verify_directory(binding.elixir_root),
         :ok <- verify_archives(identities.archives, identities.archives_digest),
         :ok <- Identity.verify_owned_identity(identities.source_owned),
         :ok <- verify_wrapper_ancestry(identities.source.path, identities.wrapper.path),
         :ok <- verify_writables(roots) do
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

  defp verify_wrapper_ancestry(source, wrapper) do
    expected = Path.join([source, "bin", "mix"])

    if wrapper == expected and Identity.child_of?(source, wrapper) do
      :ok
    else
      {:error, :trusted_build_wrapper_identity_mismatch}
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
