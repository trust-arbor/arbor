defmodule Arbor.Trust.TestHelpers do
  @moduledoc """
  Shared test utilities for arbor_trust.
  """

  @doc """
  Safely stop a process by name or pid, tolerating the race condition
  where the process dies between the liveness check and the stop call.

  Handles both named processes (atoms) and direct pids. Returns `:ok`
  regardless of whether the process was alive.
  """
  @spec safe_stop(atom() | pid()) :: :ok
  def safe_stop(name) when is_atom(name) do
    if pid = Process.whereis(name) do
      safe_stop(pid)
    else
      :ok
    end
  end

  def safe_stop(pid) when is_pid(pid) do
    GenServer.stop(pid)
    :ok
  catch
    :exit, _ -> :ok
  end

  @doc "Open an authorized, caller-owned Security authority for mutation integration tests."
  def actor_authority!(purpose \\ :trust_test_mutation) do
    {:ok, identity} = Arbor.Contracts.Security.Identity.generate()
    :ok = Arbor.Security.register_identity_fixture(identity)

    {:ok, mutation_capability} =
      Arbor.Security.grant_fixture(
        principal: identity.agent_id,
        resource: "arbor://security/**"
      )

    {:ok, proof} =
      Arbor.Security.build_signing_authority_acquisition_proof(
        identity.agent_id,
        identity.private_key,
        purpose: purpose,
        owner: self()
      )

    {:ok, authority} =
      Arbor.Security.open_ephemeral_signing_authority(proof, identity.private_key)

    ExUnit.Callbacks.on_exit(fn ->
      _ = Arbor.Security.revoke_fixture(mutation_capability.id)
      _ = Arbor.Security.deregister_identity_fixture(identity.agent_id)
    end)

    {identity, authority}
  end

  @doc false
  # JIT minting accepts only a target-signed request spent by the supervised
  # grant owner. Tests provision that owner with its fixed capability, then
  # remove a supervisor this call had to start so later bootstrap tests still
  # observe an absent tree.
  def ensure_provisioned_grant_owner! do
    supervisor_absent? = Process.whereis(Arbor.Trust.Supervisor) == nil
    :ok = Arbor.Trust.restore_runtime_fixture()
    status = provision_grant_owner!()

    unless match?(%{state: :ready}, status) do
      raise "trust grant owner is not ready: #{inspect(status)}"
    end

    if supervisor_absent? do
      ExUnit.Callbacks.on_exit(fn ->
        application_supervisor = Process.whereis(Arbor.Trust.ApplicationSupervisor)

        if is_pid(application_supervisor) and is_pid(Process.whereis(Arbor.Trust.Supervisor)) do
          _ =
            Supervisor.terminate_child(application_supervisor, Arbor.Trust.Supervisor)

          _ = Supervisor.delete_child(application_supervisor, Arbor.Trust.Supervisor)
        end
      end)
    end

    :ok
  end

  @doc false
  # The grant owner stamps the request session onto the minted capability.
  # Authorization has to present that same session or the kernel returns
  # :scope_mismatch.
  def authorize_opts_with_grant!(opts, identity, resource_uri) do
    session_id =
      case Keyword.get(opts, :session_id) do
        id when is_binary(id) and byte_size(id) in 1..512 -> id
        _ -> "trust-test-" <> Integer.to_string(System.unique_integer([:positive]))
      end

    resource_opts = Keyword.take(opts, [:file_path, :workspace])

    {:ok, payload} =
      Arbor.Trust.build_capability_grant_request(
        identity.agent_id,
        resource_uri,
        session_id,
        resource_opts
      )

    {:ok, signed} =
      Arbor.Contracts.Security.SignedRequest.sign(
        payload,
        identity.agent_id,
        identity.private_key
      )

    opts
    |> Keyword.put(:session_id, session_id)
    |> Keyword.put(:capability_grant_request, signed)
  end

  defp provision_grant_owner! do
    status = Arbor.Trust.CapabilityGrantOwner.status()

    cond do
      status.state == :ready ->
        status

      is_binary(status.principal_id) ->
        uri = Arbor.Trust.CapabilityGrantOwner.required_capability_uri()

        has_cap? =
          case Arbor.Security.list_capabilities(status.principal_id) do
            {:ok, caps} -> Enum.any?(caps, &(&1.resource_uri == uri))
            _other -> false
          end

        unless has_cap? do
          {:ok, _cap} =
            Arbor.Security.grant_fixture(principal: status.principal_id, resource: uri)
        end

        Arbor.Trust.restart_capability_grant_owner_fixture()

      true ->
        status
    end
  end
end
