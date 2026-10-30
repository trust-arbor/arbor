defmodule Arbor.Security.PlatformActivationAuthorizationHostIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Common.Extension.Activation
  alias Arbor.Contracts.Extension.Envelope
  alias Arbor.Contracts.Security.Identity
  alias Arbor.Security

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

    :ok = Security.register_identity_fixture(Identity.public_only(identity))
    :ok = Security.store_signing_key_fixture(identity.agent_id, identity.private_key)

    on_exit(fn ->
      _ = Security.delete_signing_key_fixture(identity.agent_id)
      _ = Security.deregister_identity_fixture(identity.agent_id)
    end)

    {:ok,
     snapshot: snapshot,
     agent_id: identity.agent_id,
     private_key: identity.private_key,
     public_key: public_key,
     transaction: bound_transaction(snapshot),
     context: bound_context()}
  end

  test "issued Platform authorization reaches the real staged consumer while commit stays closed",
       ctx do
    assert {:ok, authority} = open_authority(ctx, :platform_activation)

    assert {:ok, envelope} =
             Security.issue_platform_activation_authorization(
               authority,
               ctx.transaction,
               ctx.context
             )

    {:ok, staged} =
      Activation.stage(Activation.new(), ctx.transaction, now: "2026-08-16T00:00:00Z")

    assert {:ok, authorized, [{:consume_nonce, _}]} =
             Arbor.KernelRuntime.authorize_platform_activation(staged, envelope,
               now: envelope["payload"]["issued_at"]
             )

    assert {:error, "not_ready"} = Activation.commit(authorized)
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
      nonce: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    }
  end
end
