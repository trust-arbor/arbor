defmodule Arbor.Actions.IdentitySigningAuthoritySecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag spec: "SSEC-002,SSEC-013"

  alias Arbor.Actions.Identity.SignPublicKey
  alias Arbor.Contracts.Security.Identity
  alias Arbor.Security

  @moduletag :fast

  setup do
    {:ok, signer} = Identity.generate(name: "Identity endorsement signer")
    {:ok, target} = Identity.generate(name: "Identity endorsement target")
    {:ok, other} = Identity.generate(name: "Identity endorsement wrong signer")

    Enum.each([signer, target, other], fn identity ->
      :ok = Security.register_identity_fixture(Identity.public_only(identity))
    end)

    Enum.each([signer, other], fn identity ->
      :ok =
        Security.store_signing_keypair_fixture(
          identity.agent_id,
          identity.private_key,
          identity.encryption_private_key
        )
    end)

    {:ok, signer_authority} = open_authority(signer)
    {:ok, other_authority} = open_authority(other)

    on_exit(fn ->
      Enum.each([signer, other], fn identity ->
        _ = Security.delete_signing_key_fixture(identity.agent_id)
      end)

      Enum.each([signer, target, other], fn identity ->
        _ = Security.deregister_identity_fixture(identity.agent_id)
      end)
    end)

    %{
      signer: signer,
      target: target,
      other: other,
      signer_authority: signer_authority,
      other_authority: other_authority
    }
  end

  @tag spec: "SSEC-002,SSEC-013"
  test "security regression: a raw private key cannot impersonate signer_id", ctx do
    assert {:error, message} =
             SignPublicKey.run(params(ctx), %{signer_private_key: ctx.other.private_key})

    assert message =~ "caller-owned signing authority"
  end

  test "security regression: an authority for another principal cannot endorse as signer_id",
       ctx do
    assert {:error, message} =
             SignPublicKey.run(params(ctx), %{signing_authority: ctx.other_authority})

    assert message =~ "does not match signer_id"
  end

  test "matching caller-owned authority creates a verifiable domain-bound endorsement", ctx do
    assert {:ok, result} =
             SignPublicKey.run(params(ctx), %{signing_authority: ctx.signer_authority})

    assert {:ok, signature} = Base.decode16(result.signature, case: :mixed)

    assert :ok =
             Security.verify_identity_endorsement(
               ctx.signer.agent_id,
               ctx.target.agent_id,
               ctx.target.public_key,
               signature
             )
  end

  defp params(ctx) do
    %{
      signer_id: ctx.signer.agent_id,
      target_id: ctx.target.agent_id,
      note: "reviewed identity endorsement"
    }
  end

  defp open_authority(identity) do
    with {:ok, proof} <-
           Security.build_signing_authority_acquisition_proof(
             identity.agent_id,
             identity.private_key,
             purpose: :session,
             owner: self()
           ) do
      Security.open_signing_authority(proof)
    end
  end
end
