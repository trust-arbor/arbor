defmodule Arbor.Contracts.Extension.EnvelopeTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Extension.Envelope

  @moduletag :fast

  @fixture_dir Path.expand("../../../fixtures/extension_envelopes/v1", __DIR__)

  test "every payload kind has a closed fixture that validates" do
    for kind <- Envelope.kinds() do
      fixture = Envelope.fixture(kind)
      assert {:ok, ^fixture} = Envelope.validate(kind, fixture)
      assert {:ok, _digest} = Envelope.digest_of(fixture)
    end
  end

  test "signed fixtures bind the payload digest and reject mutation" do
    for kind <- Envelope.kinds() do
      signed = Envelope.signed_fixture(kind)
      assert {:ok, ^signed} = Envelope.validate_signed(signed)

      tampered = %{signed | "payload_sha256" => String.duplicate("00", 32)}
      assert {:error, :digest_mismatch} = Envelope.validate_signed(tampered)
    end
  end

  test "unknown fields, mixed keys, and unknown kinds fail closed" do
    fixture = Envelope.fixture(:provider_handle)

    assert {:error, :invalid_envelope_shape} =
             Envelope.validate(:provider_handle, Map.put(fixture, "module", "Elixir.Foo"))

    assert {:error, :mixed_keys} =
             Envelope.validate(:provider_handle, Map.put(fixture, :handle_id, "x"))

    assert {:error, :unknown_kind} = Envelope.validate(:not_a_kind, fixture)
  end

  test "duplicate identifiers and invalid UTF-8 fail closed" do
    transaction = Envelope.fixture(:activation_transaction)
    effect = hd(transaction["staged_effects"])

    assert {:error, :duplicate_identifier} =
             Envelope.validate(
               :activation_transaction,
               %{transaction | "staged_effects" => [effect, effect]}
             )

    assert {:error, :invalid_id} =
             Envelope.validate(
               :provider_handle,
               %{Envelope.fixture(:provider_handle) | "handle_id" => <<0xFF>>}
             )
  end

  test "invocation request payload digest is bound" do
    request = Envelope.fixture(:invocation_request)
    assert {:ok, ^request} = Envelope.validate(:invocation_request, request)

    assert {:error, :digest_mismatch} =
             Envelope.validate(
               :invocation_request,
               %{request | "payload" => %{"items" => []}}
             )
  end

  test "signing message binds domain, schema, and payload digest" do
    signed = Envelope.signed_fixture(:activation_authorization)
    assert {:ok, message} = Envelope.signing_message(signed)

    assert message ==
             Enum.join([signed["domain"], signed["schema"], signed["payload_sha256"]], "\0")

    assert {:error, :invalid_envelope} = Envelope.signing_message(%{})
  end

  test "public error codes are grouped and bounded" do
    assert Envelope.error_code?(:activation, "authorization_replayed")
    assert Envelope.error_code?(:invocation, "effect_disposition_unknown")
    refute Envelope.error_code?(:invocation, "some_internal_stacktrace")
    refute Envelope.error_code?(:unknown, "malformed")
  end

  test "committed fixtures match the in-code fixtures" do
    for kind <- Envelope.kinds() do
      expected = Envelope.fixture(kind)
      path = Path.join(@fixture_dir, "#{kind}.json")
      assert File.exists?(path), "missing fixture #{path}"
      assert Jason.decode!(File.read!(path)) == expected

      signed = Envelope.signed_fixture(kind)
      signed_path = Path.join(@fixture_dir, "signed_#{kind}.json")
      assert File.exists?(signed_path), "missing fixture #{signed_path}"
      assert Jason.decode!(File.read!(signed_path)) == signed
    end
  end
end
