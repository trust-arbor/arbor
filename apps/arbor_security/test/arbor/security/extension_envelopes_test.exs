defmodule Arbor.Security.ExtensionEnvelopesTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Contracts.Extension.Envelope
  alias Arbor.Security
  alias Arbor.Security.Crypto

  test "security consumes activation and invocation authorization envelopes" do
    for kind <- [:activation_authorization, :invocation_authorization] do
      fixture = Envelope.fixture(kind)
      assert {:ok, ^fixture} = Security.validate_extension_envelope(kind, fixture)
    end

    assert {:error, :unsupported_kind} =
             Security.validate_extension_envelope(
               :provider_handle,
               Envelope.fixture(:provider_handle)
             )
  end

  test "security verifies a signed authorization and rejects a forged signature" do
    {public_key, private_key} = Crypto.generate_keypair()
    signed = signed_authorization(private_key)

    assert {:ok, ^signed} =
             Security.validate_signed_extension_envelope(signed, public_key: public_key)

    forged = %{signed | "signature" => String.duplicate("00", 64)}

    assert {:error, :signature_mismatch} =
             Security.validate_signed_extension_envelope(forged, public_key: public_key)
  end

  test "security rejects a replayed authorization nonce" do
    {public_key, private_key} = Crypto.generate_keypair()
    signed = signed_authorization(private_key)
    nonce = signed["payload"]["nonce"]

    assert {:error, :authorization_replayed} =
             Security.validate_signed_extension_envelope(signed,
               public_key: public_key,
               consumed_nonces: MapSet.new([nonce])
             )
  end

  test "security rejects an expired authorization against a supplied clock" do
    {public_key, private_key} = Crypto.generate_keypair()
    signed = signed_authorization(private_key)

    assert {:error, :authorization_expired} =
             Security.validate_signed_extension_envelope(signed,
               public_key: public_key,
               now: "2026-08-18T00:00:00Z"
             )
  end

  defp signed_authorization(private_key) do
    payload = Envelope.fixture(:activation_authorization)
    {:ok, digest} = Envelope.digest_of(payload)

    envelope = %{
      "schema" => Envelope.signed_schema(),
      "version" => 1,
      "domain" => Envelope.schema(:activation_authorization),
      "payload_encoding" => "canonical_json_v1",
      "payload_sha256" => digest,
      "issuer_id" => payload["issuer_id"],
      "key_id" => payload["key_id"],
      "signature" => String.duplicate("00", 64),
      "payload" => payload
    }

    {:ok, message} = Envelope.signing_message(envelope)
    signature = Crypto.sign(message, private_key)
    %{envelope | "signature" => Base.encode16(signature, case: :lower)}
  end
end
