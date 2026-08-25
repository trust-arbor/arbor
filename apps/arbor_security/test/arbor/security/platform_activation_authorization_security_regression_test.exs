defmodule Arbor.Security.PlatformActivationAuthorizationSecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Common.Extension.Activation
  alias Arbor.Contracts.Extension.Envelope
  alias Arbor.Contracts.Security.Identity
  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Contracts.Security.SigningAuthority
  alias Arbor.Security
  alias Arbor.Security.SigningAuthorityBroker

  @platform_seed :crypto.hash(:sha256, "arbor.platform.boot_profile.v1.test-platform-seed")

  setup do
    assert {:ok, snapshot} = Arbor.KernelRuntime.boot_profile()
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519, @platform_seed)
    principal_id = Identity.derive_agent_id(public_key)
    assert principal_id == "agent_" <> snapshot["platform_key_id"]

    {:ok, identity} =
      Identity.new(
        public_key: public_key,
        private_key: private_key,
        name: "platform-activation-test"
      )

    :ok = Security.register_identity(Identity.public_only(identity))
    :ok = Security.store_signing_key(identity.agent_id, identity.private_key)

    on_exit(fn ->
      _ = Security.delete_signing_key(identity.agent_id)
      _ = Security.deregister_identity(identity.agent_id)
    end)

    {:ok,
     snapshot: snapshot,
     agent_id: identity.agent_id,
     private_key: identity.private_key,
     public_key: public_key,
     transaction: bound_transaction(snapshot),
     context: bound_context()}
  end

  test "issues a canonical envelope from the live Platform authority", ctx do
    assert {:ok, authority} = open_authority(ctx, :platform_activation)
    assert {:ok, digest} = Envelope.digest_of(ctx.transaction)

    assert {:ok, envelope} =
             Security.issue_platform_activation_authorization(
               authority,
               ctx.transaction,
               ctx.context
             )

    assert envelope["schema"] == Envelope.signed_schema()
    assert envelope["domain"] == Envelope.schema(:activation_authorization)
    assert envelope["issuer_id"] == ctx.agent_id
    assert envelope["key_id"] == ctx.snapshot["platform_key_id"]
    assert envelope["payload"]["issuer_id"] == ctx.agent_id
    assert envelope["payload"]["key_id"] == ctx.snapshot["platform_key_id"]
    assert envelope["payload"]["boot_profile_sha256"] == ctx.snapshot["manifest_sha256"]
    assert envelope["payload"]["boot_epoch"] == ctx.snapshot["boot_epoch"]
    assert envelope["payload"]["transaction_sha256"] == digest

    assert {:ok, ^envelope} =
             Security.validate_signed_extension_envelope(envelope, public_key: ctx.public_key)

    refute inspect(envelope) =~ Base.encode16(ctx.private_key, case: :lower)
    refute inspect(authority) =~ Base.encode16(ctx.private_key, case: :lower)

    snapshot = SigningAuthorityBroker.debug_state()
    refute Map.has_key?(snapshot, :signing_message)
    refute Enum.any?(snapshot.entries, & &1.has_private_key?)

    {:ok, staged} =
      Activation.stage(Activation.new(), ctx.transaction, now: "2026-08-16T00:00:00Z")

    assert {:ok, authorized, [{:consume_nonce, _}]} =
             Arbor.KernelRuntime.authorize_platform_activation(staged, envelope,
               now: ctx.context.issued_at
             )

    assert {:error, "not_ready"} = Activation.commit(authorized)
  end

  test "wrong purpose, principal, and absent authority fail closed", ctx do
    {:ok, session} = open_authority(ctx, :session)

    assert {:error, :purpose_mismatch} =
             Security.issue_platform_activation_authorization(
               session,
               ctx.transaction,
               ctx.context
             )

    other = register_other_identity()
    {:ok, other_authority} = open_authority(other, :platform_activation)

    assert {:error, :principal_mismatch} =
             Security.issue_platform_activation_authorization(
               other_authority,
               ctx.transaction,
               ctx.context
             )

    assert {:error, :invalid_authority} =
             Security.issue_platform_activation_authorization(
               :missing,
               ctx.transaction,
               ctx.context
             )

    {:ok, forged} =
      SigningAuthority.new(
        token: :crypto.strong_rand_bytes(32),
        principal_id: ctx.agent_id,
        purpose: :platform_activation
      )

    assert {:error, :authority_not_found} =
             Security.issue_platform_activation_authorization(
               forged,
               ctx.transaction,
               ctx.context
             )
  end

  test "closed authority, owner death, and identity status deny signing", ctx do
    {:ok, authority} = open_authority(ctx, :platform_activation)
    assert :ok = Security.close_signing_authority(authority)

    assert {:error, :authority_not_found} =
             Security.issue_platform_activation_authorization(
               authority,
               ctx.transaction,
               ctx.context
             )

    parent = self()

    owner =
      spawn(fn ->
        {:ok, proof} =
          Security.build_signing_authority_acquisition_proof(
            ctx.agent_id,
            ctx.private_key,
            purpose: :platform_activation,
            owner: self()
          )

        {:ok, live} = Security.open_signing_authority(proof)
        send(parent, {:authority, live})
        Process.sleep(:infinity)
      end)

    assert_receive {:authority, live}, 1_000
    ref = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^owner, _}, 1_000

    wait_until(fn ->
      match?(
        {:error, reason} when reason in [:authority_not_found, :owner_dead],
        Security.issue_platform_activation_authorization(live, ctx.transaction, ctx.context)
      )
    end)

    {:ok, active} = open_authority(ctx, :platform_activation)
    assert :ok = Security.suspend_identity(ctx.agent_id, reason: "test suspend")

    assert {:error, :identity_suspended} =
             Security.issue_platform_activation_authorization(
               active,
               ctx.transaction,
               ctx.context
             )

    assert :ok = Security.resume_identity(ctx.agent_id)
    assert :ok = Security.revoke_identity(ctx.agent_id, reason: "test revoke")

    assert {:error, :identity_revoked} =
             Security.issue_platform_activation_authorization(
               active,
               ctx.transaction,
               ctx.context
             )
  end

  test "missing or wrong stored key denies signing", ctx do
    {:ok, authority} = open_authority(ctx, :platform_activation)
    assert :ok = Security.delete_signing_key(ctx.agent_id)

    assert {:error, reason} =
             Security.issue_platform_activation_authorization(
               authority,
               ctx.transaction,
               ctx.context
             )

    assert reason in [:no_signing_key, :signing_key_unavailable]

    :ok = Security.store_signing_key(ctx.agent_id, ctx.private_key)
    {:ok, restored} = open_authority(ctx, :platform_activation)
    {:ok, other} = Identity.generate(name: "wrong-platform-key")
    assert :ok = Security.store_signing_key(ctx.agent_id, other.private_key)

    assert {:error, :signing_key_mismatch} =
             Security.issue_platform_activation_authorization(
               restored,
               ctx.transaction,
               ctx.context
             )
  end

  test "malformed context, boot mismatch, and expiry bounds fail closed", ctx do
    {:ok, authority} = open_authority(ctx, :platform_activation)

    assert {:error, :mixed_option_keys} =
             Security.issue_platform_activation_authorization(authority, ctx.transaction, %{
               "audience_host_id" => "host.local",
               audience_install_id: "install.local",
               issued_at: ctx.context.issued_at,
               expires_at: ctx.context.expires_at,
               nonce: ctx.context.nonce
             })

    duplicated =
      ctx.context
      |> Map.to_list()
      |> Kernel.++([{:nonce, String.duplicate("11", 16)}])

    assert {:error, :duplicate_attribute} =
             Security.issue_platform_activation_authorization(
               authority,
               ctx.transaction,
               duplicated
             )

    assert {:error, :forbidden_attribute} =
             Security.issue_platform_activation_authorization(
               authority,
               ctx.transaction,
               Map.put(ctx.context, :issuer_id, ctx.agent_id)
             )

    assert {:error, :forbidden_attribute} =
             Security.issue_platform_activation_authorization(
               authority,
               ctx.transaction,
               Map.put(ctx.context, :boot_profile_sha256, ctx.snapshot["manifest_sha256"])
             )

    mismatched = %{
      ctx.transaction
      | "boot_profile_sha256" => String.duplicate("00", 32)
    }

    assert {:error, :boot_mismatch} =
             Security.issue_platform_activation_authorization(
               authority,
               mismatched,
               ctx.context
             )

    inverted = %{
      ctx.context
      | issued_at: "2026-08-18T00:00:00Z",
        expires_at: "2026-08-17T01:00:00Z"
    }

    assert {:error, :invalid_validity_window} =
             Security.issue_platform_activation_authorization(
               authority,
               ctx.transaction,
               inverted
             )

    too_early = %{ctx.context | issued_at: "2026-08-16T00:00:00Z"}

    assert {:error, :invalid_validity_window} =
             Security.issue_platform_activation_authorization(
               authority,
               ctx.transaction,
               too_early
             )

    assert {:error, :invalid_nonce} =
             Security.issue_platform_activation_authorization(
               authority,
               ctx.transaction,
               %{ctx.context | nonce: "not-a-nonce"}
             )

    assert {:error, :invalid_id} =
             Security.issue_platform_activation_authorization(
               authority,
               ctx.transaction,
               %{ctx.context | audience_host_id: "Host.Local"}
             )
  end

  test "does not expose raw signing or agent-id acquisition", ctx do
    {:ok, authority} = open_authority(ctx, :platform_activation)

    assert {:ok, %SignedRequest{}} =
             Security.sign_with_authority(authority, "arbor://extension/activation")

    refute function_exported?(Security, :sign_detached, 2)

    assert {:error, :possession_proof_required} =
             Security.open_signing_authority(ctx.agent_id)
  end

  test "internal detached sign rejects a live non-platform purpose before key use", ctx do
    {:ok, session} = open_authority(ctx, :session)

    assert {:error, :purpose_mismatch} =
             SigningAuthorityBroker.sign_detached(
               session,
               "arbor.extension.activation_authorization.v1"
             )

    snapshot = SigningAuthorityBroker.debug_state()
    refute Enum.any?(snapshot.entries, & &1.has_private_key?)
    refute Map.has_key?(snapshot, :signing_message)
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
    {:ok, identity} = Identity.generate(name: "alternate-platform-key")
    :ok = Security.register_identity(Identity.public_only(identity))
    :ok = Security.store_signing_key(identity.agent_id, identity.private_key)

    on_exit(fn ->
      _ = Security.delete_signing_key(identity.agent_id)
      _ = Security.deregister_identity(identity.agent_id)
    end)

    %{agent_id: identity.agent_id, private_key: identity.private_key}
  end

  defp bound_transaction(snapshot) do
    %{
      Envelope.fixture(:activation_transaction)
      | "boot_profile_id" => snapshot["profile_id"],
        "boot_profile_sha256" => snapshot["manifest_sha256"],
        "deadline" => snapshot["valid_until"]
    }
  end

  defp bound_context do
    %{
      audience_host_id: "host.local",
      audience_install_id: "install.local",
      issued_at: "2026-08-17T00:00:00Z",
      expires_at: "2026-08-18T00:00:00Z",
      nonce: String.duplicate("aa", 16)
    }
  end

  defp wait_until(fun, attempts \\ 50)
  defp wait_until(fun, 0), do: assert(fun.())

  defp wait_until(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end
end
