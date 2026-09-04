defmodule Arbor.Security.ForgeProjectionSigningTest do
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Contracts.Coding.ForgeProjection
  alias Arbor.Contracts.Security.Identity
  alias Arbor.Contracts.Security.SigningAuthority
  alias Arbor.Security
  alias Arbor.Security.SigningAuthorityBroker
  alias Arbor.Security.TestBootstrap

  setup do
    on_exit(&TestBootstrap.restore_supervised_tree!/0)

    {:ok, identity} = Identity.generate(name: "forge-projection-signing-test")
    :ok = Security.register_identity(Identity.public_only(identity))
    :ok = Security.store_signing_key(identity.agent_id, identity.private_key)

    on_exit(fn ->
      _ = Security.delete_signing_key(identity.agent_id)
      _ = Security.deregister_identity(identity.agent_id)
    end)

    {:ok,
     agent_id: identity.agent_id,
     private_key: identity.private_key,
     public_key: identity.public_key}
  end

  test "signs canonical forge projection bytes with a coding_task_executor authority", ctx do
    assert {:ok, authority} = open_authority(ctx, :coding_task_executor)
    assert {:ok, message} = canonical_message(ctx)

    assert {:ok, signature} =
             Security.sign_detached_with_authority(
               authority,
               ForgeProjection.domain_tag(),
               message
             )

    assert byte_size(signature) == 64
    assert :ok = Security.verify_detached(message, signature, ctx.public_key)

    refute inspect(signature) =~ Base.encode16(ctx.private_key, case: :lower)
    refute inspect(authority) =~ Base.encode16(ctx.private_key, case: :lower)

    snapshot = SigningAuthorityBroker.debug_state()
    refute Map.has_key?(snapshot, :signing_message)
    refute Enum.any?(snapshot.entries, & &1.has_private_key?)
  end

  test "wrong domain tag and unprefixed messages fail closed", ctx do
    assert {:ok, authority} = open_authority(ctx, :coding_task_executor)
    assert {:ok, message} = canonical_message(ctx)

    assert {:error, :purpose_mismatch} =
             Security.sign_detached_with_authority(
               authority,
               "arbor-forge-projection-v0",
               message
             )

    assert {:error, :domain_tag_mismatch} =
             Security.sign_detached_with_authority(
               authority,
               ForgeProjection.domain_tag(),
               "not-length-prefixed"
             )

    assert {:error, :invalid_payload} =
             Security.sign_detached_with_authority(authority, ForgeProjection.domain_tag(), "")

    snapshot = SigningAuthorityBroker.debug_state()
    refute Enum.any?(snapshot.entries, & &1.has_private_key?)
    refute Map.has_key?(snapshot, :signing_message)
  end

  test "platform_activation cannot use the domain-tagged detached path", ctx do
    assert {:ok, authority} = open_authority(ctx, :platform_activation)
    assert {:ok, message} = canonical_message(ctx)

    assert {:error, :purpose_mismatch} =
             Security.sign_detached_with_authority(
               authority,
               ForgeProjection.domain_tag(),
               message
             )

    assert {:error, :purpose_mismatch} =
             SigningAuthorityBroker.sign_detached_with_domain(
               authority,
               ForgeProjection.domain_tag(),
               message
             )
  end

  test "cross-protocol detached signing rejects mismatched purpose and domain", ctx do
    {:ok, executor} = open_authority(ctx, :coding_task_executor)
    {:ok, session} = open_authority(ctx, :session)
    {:ok, platform} = open_authority(ctx, :platform_activation)
    assert {:ok, message} = canonical_message(ctx)

    assert {:error, :purpose_mismatch} =
             SigningAuthorityBroker.sign_detached(
               session,
               "arbor.extension.activation_authorization.v1"
             )

    assert {:error, :purpose_mismatch} =
             SigningAuthorityBroker.sign_detached_with_domain(
               platform,
               ForgeProjection.domain_tag(),
               message
             )

    assert {:error, :purpose_mismatch} =
             SigningAuthorityBroker.sign_detached_with_domain(
               session,
               ForgeProjection.domain_tag(),
               message
             )

    assert {:error, :purpose_mismatch} =
             SigningAuthorityBroker.sign_detached_with_domain(
               executor,
               "arbor.extension.activation_authorization.v1",
               message
             )
  end

  test "wrong purpose, principal, and absent authority fail closed", ctx do
    {:ok, session} = open_authority(ctx, :session)
    assert {:ok, message} = canonical_message(ctx)

    assert {:error, :purpose_mismatch} =
             Security.sign_detached_with_authority(
               session,
               ForgeProjection.domain_tag(),
               message
             )

    other = register_other_identity()
    {:ok, other_authority} = open_authority(other, :coding_task_executor)

    assert {:error, :principal_mismatch} =
             Security.sign_detached_with_authority(
               %{other_authority | principal_id: ctx.agent_id},
               ForgeProjection.domain_tag(),
               message
             )

    assert {:error, :invalid_authority} =
             Security.sign_detached_with_authority(
               :missing,
               ForgeProjection.domain_tag(),
               message
             )

    {:ok, forged} =
      SigningAuthority.new(
        token: :crypto.strong_rand_bytes(32),
        principal_id: ctx.agent_id,
        purpose: :coding_task_executor
      )

    assert {:error, :authority_not_found} =
             Security.sign_detached_with_authority(
               forged,
               ForgeProjection.domain_tag(),
               message
             )
  end

  defp open_authority(ctx, purpose) do
    with {:ok, proof} <-
           Security.build_signing_authority_acquisition_proof(
             ctx.agent_id,
             ctx.private_key,
             purpose: purpose,
             owner: self()
           ) do
      Security.open_signing_authority(proof)
    end
  end

  defp register_other_identity do
    {:ok, identity} = Identity.generate(name: "alternate-forge-signing-key")
    :ok = Security.register_identity(Identity.public_only(identity))
    :ok = Security.store_signing_key(identity.agent_id, identity.private_key)

    on_exit(fn ->
      _ = Security.delete_signing_key(identity.agent_id)
      _ = Security.deregister_identity(identity.agent_id)
    end)

    %{agent_id: identity.agent_id, private_key: identity.private_key}
  end

  defp canonical_message(ctx) do
    attrs = %{
      "task" => "task_forge_projection_signing",
      "cycle" => 1,
      "verdict" => "auto_proceed",
      "disposition" => "succeeded",
      "vote_counts" => %{
        "approve" => 1,
        "reject" => 0,
        "abstain" => 0,
        "failed" => 0,
        "reported" => 0
      },
      "tier_reasons" => [],
      "finding_counts" => %{"blocking" => 0, "major" => 0, "minor" => 0, "nit" => 0},
      "reviewed_commit" => String.duplicate("a", 40),
      "candidate" => String.duplicate("b", 40),
      "ledger_digest" => "sha256:" <> String.duplicate("c", 64),
      "evidence_ref" => "evidence/run_1",
      "factory_id" => "factory",
      "forge_host" => "forge.local",
      "project" => "acme/arbor",
      "poster_agent_id" => ctx.agent_id,
      "key_id" => ctx.agent_id
    }

    with {:ok, projection} <- ForgeProjection.build(attrs) do
      ForgeProjection.canonical_v1(projection)
    end
  end
end
