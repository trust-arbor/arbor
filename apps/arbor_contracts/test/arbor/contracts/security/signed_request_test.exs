defmodule Arbor.Contracts.Security.SignedRequestTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Security.SignedRequest

  setup do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    agent_id = "agent_" <> Base.encode16(:crypto.hash(:sha256, public_key), case: :lower)

    {:ok, public_key: public_key, private_key: private_key, agent_id: agent_id}
  end

  describe "sign/3" do
    test "produces valid struct with all fields", ctx do
      {:ok, signed} = SignedRequest.sign("test payload", ctx.agent_id, ctx.private_key)

      assert signed.payload == "test payload"
      assert signed.agent_id == ctx.agent_id
      assert %DateTime{} = signed.timestamp
      assert byte_size(signed.nonce) == 16
      assert byte_size(signed.signature) > 0
    end

    test "produces unique nonces on each call", ctx do
      {:ok, s1} = SignedRequest.sign("payload", ctx.agent_id, ctx.private_key)
      {:ok, s2} = SignedRequest.sign("payload", ctx.agent_id, ctx.private_key)

      refute s1.nonce == s2.nonce
    end

    test "supports human principals coherently", ctx do
      human_id = "human_operator_123"
      assert {:ok, signed} = SignedRequest.sign("human payload", human_id, ctx.private_key)
      assert signed.agent_id == human_id

      message = SignedRequest.signing_payload(signed)

      assert :crypto.verify(:eddsa, :sha512, message, signed.signature, [
               ctx.public_key,
               :ed25519
             ])
    end

    test "malformed 32/64-byte private key material returns a typed error" do
      assert {:error, :invalid_private_key} =
               SignedRequest.sign("payload", "agent_test", <<0::size(64 * 8)>>)
    end
  end

  describe "signing_payload/1" do
    test "is deterministic for same request", ctx do
      {:ok, signed} = SignedRequest.sign("test", ctx.agent_id, ctx.private_key)

      p1 = SignedRequest.signing_payload(signed)
      p2 = SignedRequest.signing_payload(signed)

      assert p1 == p2
    end

    test "includes all fields in canonical order", ctx do
      {:ok, signed} = SignedRequest.sign("hello", ctx.agent_id, ctx.private_key)

      canonical = SignedRequest.signing_payload(signed)

      timestamp_bin = DateTime.to_iso8601(signed.timestamp)

      expected =
        <<byte_size("hello")::32, "hello"::binary>> <>
          <<byte_size(ctx.agent_id)::32, ctx.agent_id::binary>> <>
          <<byte_size(timestamp_bin)::32, timestamp_bin::binary>> <>
          signed.nonce

      assert canonical == expected
    end
  end

  describe "round-trip sign and verify" do
    test "signed payload verifies with correct public key", ctx do
      {:ok, signed} = SignedRequest.sign("important data", ctx.agent_id, ctx.private_key)

      message = SignedRequest.signing_payload(signed)

      assert :crypto.verify(:eddsa, :sha512, message, signed.signature, [ctx.public_key, :ed25519])
    end

    test "signed payload fails verification with wrong key", ctx do
      {:ok, signed} = SignedRequest.sign("secret", ctx.agent_id, ctx.private_key)

      {wrong_pk, _} = :crypto.generate_key(:eddsa, :ed25519)
      message = SignedRequest.signing_payload(signed)

      refute :crypto.verify(:eddsa, :sha512, message, signed.signature, [wrong_pk, :ed25519])
    end
  end

  describe "new/1" do
    test "accepts human principals", ctx do
      assert {:ok, request} =
               SignedRequest.new(
                 payload: "data",
                 agent_id: "human_operator_123",
                 timestamp: DateTime.utc_now(),
                 nonce: :crypto.strong_rand_bytes(16),
                 signature: :crypto.strong_rand_bytes(64)
               )

      assert request.agent_id == "human_operator_123"
      assert is_binary(ctx.agent_id)
    end

    test "rejects duplicate atom/string principal attributes", ctx do
      assert {:error, :duplicate_attribute} =
               SignedRequest.new(%{
                 "agent_id" => "human_other",
                 payload: "data",
                 agent_id: ctx.agent_id,
                 timestamp: DateTime.utc_now(),
                 nonce: :crypto.strong_rand_bytes(16),
                 signature: :crypto.strong_rand_bytes(64)
               })

      assert {:error, :duplicate_attribute} =
               SignedRequest.new(%{
                 "agent_id" => ctx.agent_id,
                 payload: "data",
                 agent_id: ctx.agent_id,
                 timestamp: DateTime.utc_now(),
                 nonce: :crypto.strong_rand_bytes(16),
                 signature: :crypto.strong_rand_bytes(64)
               })
    end

    test "rejects empty payload", ctx do
      assert {:error, :empty_payload} =
               SignedRequest.new(
                 payload: "",
                 agent_id: ctx.agent_id,
                 timestamp: DateTime.utc_now(),
                 nonce: :crypto.strong_rand_bytes(16),
                 signature: :crypto.strong_rand_bytes(64)
               )
    end

    test "rejects invalid agent_id" do
      assert {:error, {:invalid_agent_id, _}} =
               SignedRequest.new(
                 payload: "data",
                 agent_id: "bad_id",
                 timestamp: DateTime.utc_now(),
                 nonce: :crypto.strong_rand_bytes(16),
                 signature: :crypto.strong_rand_bytes(64)
               )
    end

    test "rejects wrong nonce size", ctx do
      assert {:error, :invalid_nonce_size} =
               SignedRequest.new(
                 payload: "data",
                 agent_id: ctx.agent_id,
                 timestamp: DateTime.utc_now(),
                 nonce: <<1, 2, 3>>,
                 signature: :crypto.strong_rand_bytes(64)
               )
    end

    test "L3 security regression: rejects an all-zero nonce", ctx do
      # L3 (2026-02-16 review): an all-zero nonce indicates a broken/failed
      # entropy source and offers no replay protection. The fix rejects it
      # with :zero_nonce. A correctly-sized, non-zero nonce is still accepted.
      # Reverting the zero-nonce guard makes the rejection assertion fail.
      zero_nonce = <<0::size(16 * 8)>>

      assert {:error, :zero_nonce} =
               SignedRequest.new(
                 payload: "data",
                 agent_id: ctx.agent_id,
                 timestamp: DateTime.utc_now(),
                 nonce: zero_nonce,
                 signature: :crypto.strong_rand_bytes(64)
               )

      # A normal (non-zero) 16-byte nonce is accepted.
      assert {:ok, _} =
               SignedRequest.new(
                 payload: "data",
                 agent_id: ctx.agent_id,
                 timestamp: DateTime.utc_now(),
                 nonce: :crypto.strong_rand_bytes(16),
                 signature: :crypto.strong_rand_bytes(64)
               )
    end

    test "security regression: rejects malformed DateTime and Ed25519 signature", ctx do
      malformed_datetime = %{DateTime.utc_now() | month: 13}

      assert {:error, :invalid_timestamp} =
               SignedRequest.new(
                 payload: "data",
                 agent_id: ctx.agent_id,
                 timestamp: malformed_datetime,
                 nonce: :crypto.strong_rand_bytes(16),
                 signature: :crypto.strong_rand_bytes(64)
               )

      assert {:error, :invalid_signature_size} =
               SignedRequest.new(
                 payload: "data",
                 agent_id: ctx.agent_id,
                 timestamp: DateTime.utc_now(),
                 nonce: :crypto.strong_rand_bytes(16),
                 signature: <<1, 2, 3>>
               )
    end

    test "canonicalize rejects hostile partial struct-tagged maps", ctx do
      partial = %{
        __struct__: SignedRequest,
        payload: "data",
        agent_id: ctx.agent_id,
        timestamp: %{__struct__: DateTime},
        nonce: :crypto.strong_rand_bytes(16)
      }

      assert {:error, _reason} = SignedRequest.canonicalize(partial)
    end
  end
end
