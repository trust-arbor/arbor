defmodule Arbor.Agent.ProfileKeyAuthoritySecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag spec: "SSEC-002,SSEC-013"

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Agent.ProfileAuthorityOwner
  alias Arbor.Contracts.Security.Identity
  alias Arbor.Security

  setup do
    {:ok, actor} = Identity.generate(name: "profile-key-actor")
    {:ok, target} = Identity.generate(name: "profile-key-target")

    :ok = Security.register_identity_fixture(Identity.public_only(actor))
    :ok = Security.register_identity_fixture(Identity.public_only(target))
    :ok = Security.store_signing_key_fixture(actor.agent_id, actor.private_key)

    {:ok, proof} =
      Security.build_signing_authority_acquisition_proof(
        actor.agent_id,
        actor.private_key,
        purpose: :agent_lifecycle,
        owner: self()
      )

    {:ok, actor_authority} = Security.open_signing_authority(proof)

    on_exit(fn ->
      _ = Security.delete_signing_key_fixture(actor.agent_id)
      _ = Security.delete_signing_key_fixture(target.agent_id)
      _ = Security.deregister_identity_fixture(actor.agent_id)
      _ = Security.deregister_identity_fixture(target.agent_id)
    end)

    {:ok, actor_authority: actor_authority, target: target}
  end

  @tag spec: "SSEC-002,SSEC-013"
  test "security regression: profile key operations require the exact authority owner", %{
    actor_authority: actor_authority,
    target: target
  } do
    assert {:error, :key_mutation_authority_required} =
             ProfileAuthorityOwner.store_signing_identity(target)

    assert {:error, :key_mutation_authority_required} =
             ProfileAuthorityOwner.build_stored_identity_registration_proof(target)

    assert {:error, :key_mutation_authority_required} =
             ProfileAuthorityOwner.delete_signing_key(target.agent_id)

    assert {:error, :key_mutation_authority_required} =
             from_other_process(fn ->
               ProfileAuthorityOwner.store_signing_identity(target, actor_authority)
             end)

    assert {:error, :no_signing_key} = Security.signing_key_status(target.agent_id)

    assert :ok = ProfileAuthorityOwner.store_signing_identity(target, actor_authority)
    assert {:ok, :available} = Security.signing_key_status(target.agent_id)

    assert {:error, :key_mutation_authority_required} =
             from_other_process(fn ->
               ProfileAuthorityOwner.build_stored_identity_registration_proof(
                 target,
                 actor_authority
               )
             end)

    assert {:ok, registration_proof} =
             ProfileAuthorityOwner.build_stored_identity_registration_proof(
               target,
               actor_authority
             )

    assert is_binary(registration_proof)
    assert byte_size(registration_proof) == 64

    :ok = Security.deregister_identity_fixture(target.agent_id)

    assert {:error, :key_mutation_authority_required} =
             from_other_process(fn ->
               ProfileAuthorityOwner.delete_signing_key(target.agent_id, actor_authority)
             end)

    assert {:ok, :available} = Security.signing_key_status(target.agent_id)
    assert :ok = ProfileAuthorityOwner.delete_signing_key(target.agent_id, actor_authority)
    assert {:error, :no_signing_key} = Security.signing_key_status(target.agent_id)
  end

  defp from_other_process(operation) when is_function(operation, 0) do
    parent = self()

    spawn(fn ->
      send(parent, {:other_process_result, self(), operation.()})
    end)
    |> then(fn pid ->
      receive do
        {:other_process_result, ^pid, result} -> result
      after
        1_000 -> flunk("copied-authority operation did not return")
      end
    end)
  end
end
