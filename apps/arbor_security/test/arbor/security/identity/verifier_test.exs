defmodule Arbor.Security.Identity.VerifierTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Security.Identity
  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Security.Identity.Registry
  alias Arbor.Security.Identity.Verifier

  setup do
    {:ok, identity} = Identity.generate()
    :ok = Registry.register(identity)

    {:ok, identity: identity}
  end

  describe "verify/1" do
    test "valid signed request succeeds", %{identity: identity} do
      {:ok, signed} = SignedRequest.sign("test payload", identity.agent_id, identity.private_key)

      assert {:ok, agent_id} = Verifier.verify(signed)
      assert agent_id == identity.agent_id
    end

    test "unknown agent returns error" do
      {:ok, unregistered} = Identity.generate()
      {:ok, signed} = SignedRequest.sign("test", unregistered.agent_id, unregistered.private_key)

      assert {:error, :unknown_agent} = Verifier.verify(signed)
    end

    test "invalid signature returns error", %{identity: identity} do
      {:ok, signed} = SignedRequest.sign("test", identity.agent_id, identity.private_key)

      # Tamper with the signature
      tampered = %{signed | signature: :crypto.strong_rand_bytes(byte_size(signed.signature))}

      assert {:error, :invalid_signature} = Verifier.verify(tampered)
    end

    test "expired timestamp returns error", %{identity: identity} do
      # Create a request with an old timestamp
      old_timestamp = DateTime.add(DateTime.utc_now(), -120, :second)
      nonce = :crypto.strong_rand_bytes(16)

      # Build the request manually to control the timestamp
      request_for_signing = %SignedRequest{
        payload: "old request",
        agent_id: identity.agent_id,
        timestamp: old_timestamp,
        nonce: nonce,
        signature: <<>>
      }

      message = SignedRequest.signing_payload(request_for_signing)
      signature = :crypto.sign(:eddsa, :sha512, message, [identity.private_key, :ed25519])
      signed = %{request_for_signing | signature: signature}

      assert {:error, :expired_timestamp} = Verifier.verify(signed)
    end

    test "replayed nonce returns error", %{identity: identity} do
      {:ok, signed} = SignedRequest.sign("test", identity.agent_id, identity.private_key)

      # First verification should succeed
      assert {:ok, _} = Verifier.verify(signed)

      # Same nonce should be rejected
      assert {:error, :replayed_nonce} = Verifier.verify(signed)
    end
  end
end
