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
end
