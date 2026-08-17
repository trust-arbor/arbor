defmodule Arbor.Common.Extension.ActivationTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Common.Extension.Activation
  alias Arbor.Contracts.Extension.Envelope

  test "shell stages a fixture transaction and refuses unsigned authorization" do
    transaction = Envelope.fixture(:activation_transaction)

    assert {:ok, staged} =
             Activation.stage(Activation.new(), transaction, now: "2026-08-16T00:00:00Z")

    auth = Envelope.fixture(:activation_authorization)

    assert {:error, "authorization_absent"} =
             Activation.authorize(staged, auth,
               now: "2026-08-16T00:00:00Z",
               boot_profile_digest: transaction["boot_profile_sha256"],
               boot_epoch: 1
             )
  end

  test "shell verifies a signed authorization and keeps production commit disabled" do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    transaction = Envelope.fixture(:activation_transaction)
    {:ok, digest} = Envelope.digest_of(transaction)
    {:ok, staged} = Activation.stage(Activation.new(), transaction, now: "2026-08-16T00:00:00Z")

    auth = %{
      Envelope.fixture(:activation_authorization)
      | "transaction_sha256" => digest,
        "boot_profile_sha256" => transaction["boot_profile_sha256"]
    }

    signed = sign(auth, private_key)

    assert {:ok, authorized, [{:consume_nonce, _}]} =
             Activation.authorize(staged, signed,
               public_key: public_key,
               now: "2026-08-16T00:00:00Z",
               boot_profile_digest: transaction["boot_profile_sha256"],
               boot_epoch: 1
             )

    assert {:error, "not_ready"} = Activation.commit(authorized)
    assert {:ok, committed} = Activation.commit(authorized, allow_commit: true)
    assert {:ok, _} = Envelope.validate(:activation_receipt, committed.receipt)
  end

  test "forged signature is not authorization" do
    {_public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    {other_public, _other_private} = :crypto.generate_key(:eddsa, :ed25519)
    transaction = Envelope.fixture(:activation_transaction)
    {:ok, digest} = Envelope.digest_of(transaction)
    {:ok, staged} = Activation.stage(Activation.new(), transaction, now: "2026-08-16T00:00:00Z")

    auth = %{Envelope.fixture(:activation_authorization) | "transaction_sha256" => digest}
    signed = sign(auth, private_key)

    assert {:error, "authorization_invalid"} =
             Activation.authorize(staged, signed,
               public_key: other_public,
               now: "2026-08-16T00:00:00Z",
               boot_profile_digest: transaction["boot_profile_sha256"],
               boot_epoch: 1
             )
  end

  defp sign(payload, private_key) do
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
    signature = :crypto.sign(:eddsa, :none, message, [private_key, :ed25519])
    %{envelope | "signature" => Base.encode16(signature, case: :lower)}
  end
end
