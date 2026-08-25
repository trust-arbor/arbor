defmodule Arbor.Common.Extension.PlatformActivationAuthorizationTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Common.Extension.Activation
  alias Arbor.Contracts.Extension.Envelope
  alias Arbor.Contracts.Security.Identity
  alias Arbor.KernelRuntime

  @platform_seed :crypto.hash(:sha256, "arbor.platform.boot_profile.v1.test-platform-seed")

  setup do
    assert {:ok, snapshot} = KernelRuntime.boot_profile()
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519, @platform_seed)
    principal_id = Identity.derive_agent_id(public_key)
    assert principal_id == "agent_" <> snapshot["platform_key_id"]
    transaction = bound_transaction(snapshot)
    {:ok, digest} = Envelope.digest_of(transaction)
    payload = authorization_payload(snapshot, principal_id, digest)

    envelope =
      sign_payload(payload, private_key, principal_id, snapshot["platform_key_id"])

    {:ok, staged} = stage(transaction)

    {:ok,
     snapshot: snapshot,
     public_key: public_key,
     private_key: private_key,
     principal_id: principal_id,
     transaction: transaction,
     digest: digest,
     payload: payload,
     envelope: envelope,
     staged: staged}
  end

  test "a genuine Platform envelope authorizes only its exact staged transaction", ctx do
    assert {:ok, authorized, [{:consume_nonce, nonce}]} =
             KernelRuntime.authorize_platform_activation(ctx.staged, ctx.envelope,
               now: ctx.payload["issued_at"]
             )

    assert nonce == ctx.payload["nonce"]
    assert authorized.status == :authorized
    assert {:error, "not_ready"} = Activation.commit(authorized)
    refute function_exported?(KernelRuntime, :sign_detached, 2)
  end

  test "artifact and generation mutations of the staged transaction fail closed", ctx do
    artifact = %{ctx.transaction | "artifact_sha256" => String.duplicate("00", 32)}
    {:ok, artifact_staged} = stage(artifact)

    assert {:error, "transaction_mismatch"} =
             KernelRuntime.authorize_platform_activation(artifact_staged, ctx.envelope,
               now: ctx.payload["issued_at"]
             )

    generation = %{ctx.transaction | "generation" => 2}
    {:ok, generation_staged} = stage(generation)

    assert {:error, "transaction_mismatch"} =
             KernelRuntime.authorize_platform_activation(generation_staged, ctx.envelope,
               now: ctx.payload["issued_at"]
             )
  end

  test "transaction digest, profile digest, epoch, and boot_profile_id mutations fail closed",
       ctx do
    other = %{ctx.transaction | "artifact_sha256" => String.duplicate("11", 32)}
    {:ok, other_staged} = stage(other)

    assert {:error, "transaction_mismatch"} =
             KernelRuntime.authorize_platform_activation(other_staged, ctx.envelope,
               now: ctx.payload["issued_at"]
             )

    profile_id = %{ctx.transaction | "boot_profile_id" => "other_profile"}
    {:ok, profile_id_staged} = stage(profile_id)

    assert {:error, "boot_mismatch"} =
             KernelRuntime.authorize_platform_activation(profile_id_staged, ctx.envelope,
               now: ctx.payload["issued_at"]
             )

    profile_mutated =
      sign_payload(
        %{ctx.payload | "boot_profile_sha256" => String.duplicate("00", 32)},
        ctx.private_key,
        ctx.principal_id,
        ctx.snapshot["platform_key_id"]
      )

    assert {:error, "boot_mismatch"} =
             KernelRuntime.authorize_platform_activation(ctx.staged, profile_mutated,
               now: ctx.payload["issued_at"]
             )

    epoch_mutated =
      sign_payload(
        %{ctx.payload | "boot_epoch" => 2},
        ctx.private_key,
        ctx.principal_id,
        ctx.snapshot["platform_key_id"]
      )

    assert {:error, "generation_mismatch"} =
             KernelRuntime.authorize_platform_activation(ctx.staged, epoch_mutated,
               now: ctx.payload["issued_at"]
             )
  end

  test "nonce replay, expiry, signature, issuer, and key mutations fail closed", ctx do
    assert {:ok, _authorized, [{:consume_nonce, nonce}]} =
             KernelRuntime.authorize_platform_activation(ctx.staged, ctx.envelope,
               now: ctx.payload["issued_at"]
             )

    assert {:error, "authorization_replayed"} =
             KernelRuntime.authorize_platform_activation(ctx.staged, ctx.envelope,
               now: ctx.payload["issued_at"],
               consumed_nonces: MapSet.new([nonce])
             )

    assert {:error, "authorization_expired"} =
             KernelRuntime.authorize_platform_activation(ctx.staged, ctx.envelope,
               now: "2026-08-19T00:00:00Z"
             )

    forged = %{ctx.envelope | "signature" => flip_hex(ctx.envelope["signature"])}

    assert {:error, "authorization_invalid"} =
             KernelRuntime.authorize_platform_activation(ctx.staged, forged,
               now: ctx.payload["issued_at"]
             )

    wrapper_issuer = %{
      ctx.envelope
      | "issuer_id" => "agent_" <> String.duplicate("00", 32)
    }

    assert {:error, "principal_denied"} =
             KernelRuntime.authorize_platform_activation(ctx.staged, wrapper_issuer,
               now: ctx.payload["issued_at"]
             )

    wrapper_key = %{ctx.envelope | "key_id" => String.duplicate("11", 32)}

    assert {:error, "authorization_invalid"} =
             KernelRuntime.authorize_platform_activation(ctx.staged, wrapper_key,
               now: ctx.payload["issued_at"]
             )

    payload_issuer =
      sign_payload(
        %{ctx.payload | "issuer_id" => "agent_" <> String.duplicate("00", 32)},
        ctx.private_key,
        ctx.principal_id,
        ctx.snapshot["platform_key_id"]
      )

    assert {:error, "principal_denied"} =
             KernelRuntime.authorize_platform_activation(ctx.staged, payload_issuer,
               now: ctx.payload["issued_at"]
             )

    payload_key =
      sign_payload(
        %{ctx.payload | "key_id" => String.duplicate("11", 32)},
        ctx.private_key,
        ctx.principal_id,
        ctx.snapshot["platform_key_id"]
      )

    assert {:error, "authorization_invalid"} =
             KernelRuntime.authorize_platform_activation(ctx.staged, payload_key,
               now: ctx.payload["issued_at"]
             )
  end

  test "unsigned authorizations and caller boot replacements are rejected", ctx do
    assert {:error, "authorization_absent"} =
             KernelRuntime.authorize_platform_activation(ctx.staged, ctx.payload,
               now: ctx.payload["issued_at"]
             )

    assert {:error, "malformed"} =
             KernelRuntime.authorize_platform_activation(ctx.staged, ctx.envelope,
               now: ctx.payload["issued_at"],
               public_key: ctx.public_key
             )

    assert {:error, "malformed"} =
             KernelRuntime.authorize_platform_activation(ctx.staged, ctx.envelope,
               boot_profile_digest: ctx.snapshot["manifest_sha256"]
             )
  end

  defp bound_transaction(snapshot) do
    %{
      Envelope.fixture(:activation_transaction)
      | "boot_profile_id" => snapshot["profile_id"],
        "boot_profile_sha256" => snapshot["manifest_sha256"],
        "deadline" => snapshot["valid_until"]
    }
  end

  defp authorization_payload(snapshot, principal_id, digest) do
    %{
      "schema" => Envelope.schema(:activation_authorization),
      "version" => 1,
      "transaction_sha256" => digest,
      "issuer_id" => principal_id,
      "key_id" => snapshot["platform_key_id"],
      "audience_host_id" => "host.local",
      "audience_install_id" => "install.local",
      "boot_epoch" => snapshot["boot_epoch"],
      "boot_profile_sha256" => snapshot["manifest_sha256"],
      "issued_at" => "2026-08-17T00:00:00Z",
      "expires_at" => "2026-08-18T00:00:00Z",
      "nonce" => String.duplicate("aa", 16)
    }
  end

  defp stage(transaction) do
    Activation.stage(Activation.new(), transaction, now: "2026-08-16T00:00:00Z")
  end

  defp sign_payload(payload, private_key, wrapper_issuer, wrapper_key) do
    {:ok, digest} = Envelope.digest_of(payload)

    envelope = %{
      "schema" => Envelope.signed_schema(),
      "version" => 1,
      "domain" => Envelope.schema(:activation_authorization),
      "payload_encoding" => "canonical_json_v1",
      "payload_sha256" => digest,
      "issuer_id" => wrapper_issuer,
      "key_id" => wrapper_key,
      "signature" => String.duplicate("00", 64),
      "payload" => payload
    }

    {:ok, message} = Envelope.signing_message(envelope)
    signature = :crypto.sign(:eddsa, :none, message, [private_key, :ed25519])
    %{envelope | "signature" => Base.encode16(signature, case: :lower)}
  end

  defp flip_hex(hex) do
    last = String.last(hex)
    flipped = if last == "0", do: "1", else: "0"
    String.slice(hex, 0, byte_size(hex) - 1) <> flipped
  end
end
