defmodule Arbor.Agent.Test.ActorAuthority do
  @moduledoc false

  @doc """
  Open a caller-owned authority that may enroll identities and grant capabilities.

  `Lifecycle.create/2` fails closed without `:actor_authority`. The one-arity
  production APIs stay unauthorized; tests pass this authority explicitly.
  """
  def open!(purpose \\ :agent_test_mutation) do
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

    authority
  end
end
