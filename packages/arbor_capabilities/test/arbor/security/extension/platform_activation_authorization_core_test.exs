defmodule Arbor.Security.Extension.PlatformActivationAuthorizationCoreTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Contracts.Extension.Envelope
  alias Arbor.Contracts.Security.Identity
  alias Arbor.Security.Extension.PlatformActivationAuthorizationCore, as: Core

  setup do
    {public_key, _private_key} = :crypto.generate_key(:eddsa, :ed25519)
    key_id = lowercase_sha256(public_key)
    principal_id = Identity.derive_agent_id(public_key)

    snapshot = %{
      "schema" => "arbor.kernel_runtime.boot_profile_binding.v1",
      "version" => 1,
      "manifest_sha256" => String.duplicate("ab", 32),
      "profile_id" => "safe_recovery",
      "boot_epoch" => 1,
      "platform_public_key" => Base.encode16(public_key, case: :lower),
      "platform_key_id" => key_id,
      "valid_from" => "2026-08-17T00:00:00Z",
      "valid_until" => "2027-08-17T00:00:00Z"
    }

    transaction = %{
      Envelope.fixture(:activation_transaction)
      | "boot_profile_id" => snapshot["profile_id"],
        "boot_profile_sha256" => snapshot["manifest_sha256"]
    }

    {:ok, digest} = Envelope.digest_of(transaction)

    {:ok,
     public_key: public_key,
     key_id: key_id,
     principal_id: principal_id,
     snapshot: snapshot,
     transaction: transaction,
     digest: digest,
     context: context()}
  end

  test "builds an unsigned envelope from snapshot-derived identity", ctx do
    assert {:ok, built} = Core.build(input(ctx))
    assert built.principal_id == ctx.principal_id
    assert built.key_id == ctx.key_id
    assert built.platform_public_key == ctx.public_key
    assert built.payload["issuer_id"] == ctx.principal_id
    assert built.payload["key_id"] == ctx.key_id
    assert built.payload["boot_profile_sha256"] == ctx.snapshot["manifest_sha256"]
    assert built.payload["boot_epoch"] == 1
    assert built.payload["transaction_sha256"] == ctx.digest
    assert built.unsigned_envelope["issuer_id"] == ctx.principal_id
    assert built.unsigned_envelope["key_id"] == ctx.key_id
    assert is_binary(built.signing_message)
    refute Map.has_key?(built, :private_key)
  end

  test "rejects wrong purpose and principal", ctx do
    assert {:error, :purpose_mismatch} =
             Core.build(input(ctx, authority_purpose: :session))

    assert {:error, :purpose_mismatch} =
             Core.build(input(ctx, authority_purpose: "platform_activation"))

    other = "agent_" <> String.duplicate("00", 32)

    assert {:error, :principal_mismatch} =
             Core.build(input(ctx, authority_principal_id: other))
  end

  test "rejects mixed keys, forbidden fields, and key_id mismatch", ctx do
    mixed = Map.put(ctx.context, "nonce", ctx.context.nonce)

    assert {:error, :mixed_option_keys} = Core.build(input(ctx, context: mixed))

    forbidden = Map.put(ctx.context, :issuer_id, ctx.principal_id)

    assert {:error, :forbidden_attribute} = Core.build(input(ctx, context: forbidden))

    mismatched = %{ctx.snapshot | "platform_key_id" => String.duplicate("11", 32)}

    assert {:error, :platform_key_id_mismatch} =
             Core.build(input(ctx, snapshot: mismatched))
  end

  test "rejects timestamps outside the snapshot window", ctx do
    before_window = %{ctx.context | issued_at: "2026-08-16T00:00:00Z"}

    assert {:error, :invalid_validity_window} =
             Core.build(input(ctx, context: before_window))

    inverted = %{
      ctx.context
      | issued_at: "2026-08-18T00:00:00Z",
        expires_at: "2026-08-17T00:00:00Z"
    }

    assert {:error, :invalid_validity_window} =
             Core.build(input(ctx, context: inverted))
  end

  test "rejects a transaction bound to a different boot digest", ctx do
    other = %{ctx.transaction | "boot_profile_sha256" => String.duplicate("00", 32)}
    {:ok, digest} = Envelope.digest_of(other)

    assert {:error, :boot_mismatch} =
             Core.build(input(ctx, transaction: other, digest: digest))
  end

  defp input(ctx, overrides \\ []) do
    Map.merge(
      %{
        snapshot: ctx.snapshot,
        transaction: ctx.transaction,
        digest: ctx.digest,
        context: ctx.context,
        authority_principal_id: ctx.principal_id,
        authority_purpose: :platform_activation
      },
      Map.new(overrides)
    )
  end

  defp context do
    %{
      audience_host_id: "host.local",
      audience_install_id: "install.local",
      issued_at: "2026-08-17T00:00:00Z",
      expires_at: "2026-08-18T00:00:00Z",
      nonce: String.duplicate("cd", 16)
    }
  end

  defp lowercase_sha256(bytes) do
    Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
  end
end
