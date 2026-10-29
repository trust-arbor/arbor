defmodule Arbor.Contracts.Extension.BootProfileManifestTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Extension.Envelope

  @moduletag :fast

  @fixture_dir Path.expand("../../../fixtures/extension_envelopes/v1", __DIR__)
  @installer_seed :crypto.hash(:sha256, "arbor.platform.boot_profile.v1.test-installer-seed")
  @platform_seed :crypto.hash(:sha256, "arbor.platform.boot_profile.v1.test-platform-seed")
  @installer_public_key "347f4f2c0221027fb01086e2d5b8ee0264ae43ddb99aea3dacf04ce0331f89b8"
  @installer_key_id "37eb0623867f14c690e51a9e24c55fd98ae4b353a00cd3a37ec953330ddda395"
  @platform_public_key "46adc9536b563c36a777199fd7a6c8dc82c4c0e9e7952f123a23d27bf0e74170"
  @platform_key_id "e50fe65c9e59cfefce8bea959c8aac98e31d25922b172f9e60acd43cf5b804bb"
  @manifest_sha256 "374dabaf63c89a46a92b87bbf0f2e871330ecfe01eb9a230560137b1a7a18268"
  @signature_hex "a61753ee7ca4ffc281f54432fff57dc574c754ae53f6623f67d2cff8a96eed79148c2752a028fc9296b85099dcc4f6ac97d501d8c949951de05627138791330e"

  setup_all do
    installer = keypair(@installer_seed)
    platform = keypair(@platform_seed)
    manifest_bytes = File.read!(Path.join(@fixture_dir, "boot_profile_manifest.json"))
    signature_bytes = File.read!(Path.join(@fixture_dir, "boot_profile_signature.json"))
    manifest = Envelope.boot_profile_fixture()
    signature = Envelope.boot_profile_signature_fixture()

    {:ok,
     installer: installer,
     platform: platform,
     manifest: manifest,
     signature: signature,
     manifest_bytes: manifest_bytes,
     signature_bytes: signature_bytes,
     verifier: verifier(manifest, installer)}
  end

  test "canonical success verifies committed fixture bytes without using the Platform key", %{
    installer: installer,
    platform: platform,
    manifest: manifest,
    manifest_bytes: manifest_bytes,
    signature_bytes: signature_bytes,
    verifier: verifier
  } do
    assert installer.public_key_hex == @installer_public_key
    assert installer.key_id == @installer_key_id
    assert platform.public_key_hex == @platform_public_key
    assert platform.key_id == @platform_key_id
    assert Jason.decode!(manifest_bytes) == manifest

    assert {:ok, result} =
             Envelope.verify_boot_profile(manifest_bytes, signature_bytes, verifier)

    assert result["manifest"] == manifest
    assert result["manifest_sha256"] == @manifest_sha256
    assert result["signer_id"] == "installer.arbor"
    assert result["signer_key_id"] == @installer_key_id
    assert result["manifest"]["platform_public_key"] == @platform_public_key
    refute platform.public_key_hex == installer.public_key_hex
    refute Enum.any?(verifier["trusted_signers"], &(&1["public_key"] == platform.public_key_hex))
  end

  test "direct committed-fixture digest and signature proof", %{
    installer: installer,
    manifest: manifest,
    signature: signature,
    manifest_bytes: manifest_bytes,
    signature_bytes: signature_bytes
  } do
    assert {:ok, ^manifest_bytes} = Envelope.boot_profile_canonical_json(manifest)
    digest = lowercase_sha256(manifest_bytes)
    assert digest == @manifest_sha256
    assert digest == signature["manifest_sha256"]
    assert {:ok, ^digest} = Envelope.boot_profile_digest_of(manifest)
    assert Jason.decode!(signature_bytes) == signature
    assert {:ok, ^signature_bytes} = Envelope.boot_profile_signature_canonical_json(signature)

    assert {:ok, message} = Envelope.boot_profile_signing_message(signature)

    assert message ==
             Enum.join(
               [
                 signature["domain"],
                 signature["schema"],
                 signature["signer_id"],
                 signature["key_id"],
                 signature["manifest_sha256"]
               ],
               <<0>>
             )

    resigned =
      :crypto.sign(:eddsa, :none, message, [installer.private_key, :ed25519])

    resigned_hex = Base.encode16(resigned, case: :lower)
    assert resigned_hex == signature["signature"]
    assert resigned_hex == @signature_hex

    assert :crypto.verify(
             :eddsa,
             :none,
             message,
             resigned,
             [installer.public_key, :ed25519]
           )
  end

  test "encode and digest APIs validate the closed schema before TaintEnvelope" do
    fixture = Envelope.boot_profile_fixture()

    unknown = Map.put(fixture, "extra", "no")
    mixed = Map.put(fixture, :release_id, "x")
    unsorted = %{fixture | "payload_digests" => Enum.reverse(fixture["payload_digests"])}
    invalid_time = %{fixture | "valid_from" => "2026-02-30T00:00:00Z"}

    assert {:error, :invalid_envelope_shape} = Envelope.boot_profile_canonical_json(unknown)
    assert {:error, :mixed_keys} = Envelope.boot_profile_canonical_json(mixed)
    assert {:error, :invalid_field} = Envelope.boot_profile_canonical_json(unsorted)
    assert {:error, :invalid_timestamp} = Envelope.boot_profile_canonical_json(invalid_time)

    assert {:error, :invalid_envelope_shape} = Envelope.boot_profile_digest_of(unknown)
    assert {:error, :mixed_keys} = Envelope.boot_profile_digest_of(mixed)
    assert {:error, :invalid_field} = Envelope.boot_profile_digest_of(unsorted)
    assert {:error, :invalid_timestamp} = Envelope.boot_profile_digest_of(invalid_time)

    assert {:ok, _bytes} = Envelope.canonical_json(unknown)
    assert {:ok, _digest} = Envelope.digest_of(unknown)
  end

  test "Envelope kinds and existing E0C fixtures are unchanged" do
    assert Envelope.kinds() == [
             :artifact_manifest,
             :provider_handle,
             :activation_transaction,
             :activation_authorization,
             :activation_receipt,
             :invocation_authorization,
             :invocation_request,
             :invocation_result
           ]

    for kind <- Envelope.kinds() do
      assert File.exists?(Path.join(@fixture_dir, "#{kind}.json"))
      assert File.exists?(Path.join(@fixture_dir, "signed_#{kind}.json"))
    end
  end

  test "taxonomy distinguishes envelope shape from verifier-input shape", %{
    manifest: manifest,
    signature: signature,
    verifier: verifier
  } do
    assert {:error, :invalid_envelope_shape} =
             Envelope.validate_boot_profile_manifest(Map.put(manifest, "extra", "no"))

    assert {:error, :invalid_envelope_shape} =
             Envelope.validate_boot_profile_manifest(Map.delete(manifest, "release_id"))

    assert {:error, :invalid_envelope_shape} =
             Envelope.validate_boot_profile_signature(Map.put(signature, "extra", "no"))

    assert {:error, :invalid_envelope_shape} =
             Envelope.validate_boot_profile_signature(Map.delete(signature, "signer_id"))

    item = hd(manifest["payload_digests"])

    assert {:error, :invalid_envelope_shape} =
             Envelope.validate_boot_profile_manifest(%{
               manifest
               | "payload_digests" => [Map.put(item, "extra", "no")]
             })

    assert {:error, :mixed_keys} =
             Envelope.validate_boot_profile_manifest(Map.put(manifest, :release_id, "x"))

    assert {:error, :mixed_keys} =
             Envelope.validate_boot_profile_signature(Map.put(signature, :key_id, "x"))

    assert {:error, :mixed_keys} =
             Envelope.validate_boot_profile_manifest(%{
               manifest
               | "payload_digests" => [Map.put(item, :id, "x")]
             })

    assert {:error, :invalid_verifier_input} =
             Envelope.validate_boot_profile_verifier_input(Map.put(verifier, "extra", "no"))

    assert {:error, :invalid_verifier_input} =
             Envelope.validate_boot_profile_verifier_input(Map.delete(verifier, "now"))

    assert {:error, :invalid_verifier_input} =
             Envelope.validate_boot_profile_verifier_input(
               Map.put(verifier, :now, verifier["now"])
             )

    assert {:error, :invalid_verifier_input} =
             Envelope.validate_boot_profile_verifier_input(now: verifier["now"])

    assert {:error, :invalid_verifier_input} =
             Envelope.validate_boot_profile_verifier_input(DateTime.from_unix!(0))

    signer = hd(verifier["trusted_signers"])

    assert {:error, :invalid_verifier_input} =
             Envelope.validate_boot_profile_verifier_input(%{
               verifier
               | "trusted_signers" => [Map.put(signer, "extra", "no")]
             })

    assert {:error, :invalid_verifier_input} =
             Envelope.validate_boot_profile_verifier_input(%{
               verifier
               | "trusted_signers" => [Map.delete(signer, "public_key")]
             })

    assert {:error, :invalid_verifier_input} =
             Envelope.validate_boot_profile_verifier_input(%{
               verifier
               | "trusted_signers" => [Map.put(signer, :signer_id, "x")]
             })

    expected_item = hd(verifier["expected_payload_digests"])

    assert {:error, :invalid_verifier_input} =
             Envelope.validate_boot_profile_verifier_input(%{
               verifier
               | "expected_payload_digests" => [Map.put(expected_item, "extra", "no")]
             })

    assert {:error, :invalid_verifier_input} =
             Envelope.validate_boot_profile_verifier_input(%{
               verifier
               | "expected_payload_digests" => [Map.put(expected_item, :id, "x")]
             })
  end

  test "malformed encodings fail closed" do
    assert {:error, :malformed_encoding} = Envelope.decode_boot_profile_manifest_bytes("{")
    assert {:error, :malformed_encoding} = Envelope.decode_boot_profile_manifest_bytes(<<0xFF>>)
    assert {:error, :malformed_encoding} = Envelope.decode_boot_profile_manifest_bytes("[]")
    assert {:error, :malformed_encoding} = Envelope.decode_boot_profile_manifest_bytes("null")
    assert {:error, :malformed_encoding} = Envelope.decode_boot_profile_signature_bytes("[]")
  end

  test "raw document size boundary fails closed", %{
    manifest: manifest,
    manifest_bytes: manifest_bytes,
    signature: signature,
    signature_bytes: signature_bytes
  } do
    assert byte_size(manifest_bytes) < 16_384
    assert byte_size(signature_bytes) < 16_384
    assert {:ok, ^manifest} = Envelope.decode_boot_profile_manifest_bytes(manifest_bytes)
    assert {:ok, ^signature} = Envelope.decode_boot_profile_signature_bytes(signature_bytes)

    at_limit = String.duplicate(" ", 16_384)
    oversized = at_limit <> " "

    assert {:error, :malformed_encoding} =
             Envelope.decode_boot_profile_manifest_bytes(at_limit)

    assert {:error, :payload_byte_limit} =
             Envelope.decode_boot_profile_manifest_bytes(oversized)

    assert {:error, :payload_byte_limit} =
             Envelope.decode_boot_profile_signature_bytes(oversized)
  end

  test "non-canonical bytes fail closed", %{manifest_bytes: manifest_bytes} do
    assert {:error, :non_canonical_bytes} =
             Envelope.decode_boot_profile_manifest_bytes(manifest_bytes <> "\n")

    assert {:error, :non_canonical_bytes} =
             Envelope.decode_boot_profile_manifest_bytes(
               String.replace(manifest_bytes, ":", ": ", global: false)
             )

    pretty = Jason.encode!(Jason.decode!(manifest_bytes), pretty: true)

    assert {:error, :non_canonical_bytes} =
             Envelope.decode_boot_profile_manifest_bytes(pretty)

    unsorted_keys =
      manifest_bytes
      |> String.replace("{\"boot_epoch\":1,", "{\"version\":1,\"boot_epoch\":1,", global: false)
      |> String.replace(",\"version\":1}", "}", global: false)

    assert unsorted_keys != manifest_bytes

    assert {:error, :non_canonical_bytes} =
             Envelope.decode_boot_profile_manifest_bytes(unsorted_keys)
  end

  test "duplicate JSON keys at the raw-byte boundary fail closed", %{
    manifest_bytes: manifest_bytes
  } do
    duplicated =
      String.replace(manifest_bytes, "\"schema\":", "\"schema\":\"ignored\",\"schema\":",
        global: false
      )

    assert {:error, :duplicate_json_key} =
             Envelope.decode_boot_profile_manifest_bytes(duplicated)

    nested =
      String.replace(
        manifest_bytes,
        "\"id\":\"payload.kernel\"",
        "\"id\":\"payload.kernel\",\"id\":\"payload.kernel\""
      )

    assert {:error, :duplicate_json_key} =
             Envelope.decode_boot_profile_manifest_bytes(nested)
  end

  test "invalid key and signature lengths fail closed", %{
    manifest: manifest,
    signature: signature
  } do
    assert {:error, :invalid_public_key} =
             Envelope.validate_boot_profile_manifest(%{
               manifest
               | "platform_public_key" => String.duplicate("11", 31)
             })

    assert {:error, :invalid_public_key} =
             Envelope.validate_boot_profile_manifest(%{
               manifest
               | "platform_public_key" => String.upcase(manifest["platform_public_key"])
             })

    assert {:error, :invalid_hash} =
             Envelope.validate_boot_profile_manifest(%{
               manifest
               | "platform_key_id" => String.duplicate("ab", 31)
             })

    assert {:error, :invalid_signature} =
             Envelope.validate_boot_profile_signature(%{
               signature
               | "signature" => String.duplicate("ef", 63)
             })

    assert {:error, :invalid_hash} =
             Envelope.validate_boot_profile_signature(%{
               signature
               | "manifest_sha256" => String.upcase(signature["manifest_sha256"])
             })
  end

  test "unsorted unique payload digests and duplicate ids fail closed", %{manifest: manifest} do
    [first, second] = manifest["payload_digests"]

    assert {:error, :invalid_field} =
             Envelope.validate_boot_profile_manifest(%{
               manifest
               | "payload_digests" => [second, first]
             })

    assert {:error, :duplicate_identifier} =
             Envelope.validate_boot_profile_manifest(%{
               manifest
               | "payload_digests" => [first, first]
             })
  end

  test "timestamps require exact {0, 0} microsecond precision", %{manifest: manifest} do
    assert {:ok, ^manifest} = Envelope.validate_boot_profile_manifest(manifest)

    assert {:error, :invalid_timestamp} =
             Envelope.validate_boot_profile_manifest(%{
               manifest
               | "valid_from" => "2026-08-17T00:00:00.0Z"
             })

    assert {:error, :invalid_timestamp} =
             Envelope.validate_boot_profile_manifest(%{
               manifest
               | "valid_from" => "2026-08-17T00:00:00.000Z"
             })

    assert {:error, :invalid_timestamp} =
             Envelope.validate_boot_profile_manifest(%{
               manifest
               | "valid_from" => "2026-08-17T00:00:00.000000Z"
             })

    assert {:error, :invalid_timestamp} =
             Envelope.validate_boot_profile_manifest(%{
               manifest
               | "valid_from" => "2026-02-30T00:00:00Z"
             })

    assert {:error, :invalid_timestamp} =
             Envelope.validate_boot_profile_manifest(%{
               manifest
               | "valid_from" => "2026-08-17T00:00:00+00:00"
             })
  end

  test "verifier now also rejects fractional-zero timestamps", %{verifier: verifier} do
    assert {:ok, ^verifier} = Envelope.validate_boot_profile_verifier_input(verifier)

    assert {:error, :invalid_timestamp} =
             Envelope.validate_boot_profile_verifier_input(%{
               verifier
               | "now" => "2026-08-17T00:00:00.0Z"
             })

    assert {:error, :invalid_timestamp} =
             Envelope.validate_boot_profile_verifier_input(%{
               verifier
               | "now" => "2026-08-17T00:00:00.000Z"
             })

    assert {:error, :invalid_timestamp} =
             Envelope.validate_boot_profile_verifier_input(%{
               verifier
               | "now" => "2026-08-17T00:00:00.000000Z"
             })
  end

  test "digest mismatch fails closed", %{
    manifest: manifest,
    verifier: verifier,
    manifest_bytes: manifest_bytes,
    signature: signature,
    signature_bytes: signature_bytes
  } do
    tampered = %{signature | "manifest_sha256" => String.duplicate("00", 32)}
    {:ok, tampered_bytes} = Envelope.boot_profile_signature_canonical_json(tampered)

    assert {:error, :digest_mismatch} =
             Envelope.verify_boot_profile(manifest_bytes, tampered_bytes, verifier)

    mutated = %{manifest | "release_id" => "arbor.platform.release.2"}
    {:ok, mutated_bytes} = Envelope.boot_profile_canonical_json(mutated)

    assert {:error, :digest_mismatch} =
             Envelope.verify_boot_profile(mutated_bytes, signature_bytes, verifier)
  end

  test "forged signatures and Platform self-authentication fail closed", %{
    manifest: manifest,
    manifest_bytes: manifest_bytes,
    signature: signature,
    signature_bytes: signature_bytes,
    installer: installer,
    platform: platform,
    verifier: verifier
  } do
    forged = %{signature | "signature" => flip_hex(signature["signature"])}
    {:ok, forged_bytes} = Envelope.boot_profile_signature_canonical_json(forged)

    assert {:error, :signature_mismatch} =
             Envelope.verify_boot_profile(manifest_bytes, forged_bytes, verifier)

    {_bytes, platform_signed_as_installer, _doc} =
      sign_docs_with(manifest, installer, platform.private_key)

    assert {:error, :signature_mismatch} =
             Envelope.verify_boot_profile(manifest_bytes, platform_signed_as_installer, verifier)

    platform_doc = %{
      signature
      | "key_id" => platform.key_id,
        "signature" =>
          sign_hex(signing_message(%{signature | "key_id" => platform.key_id}), platform)
    }

    {:ok, platform_bytes} = Envelope.boot_profile_signature_canonical_json(platform_doc)

    assert {:error, :untrusted_signer} =
             Envelope.verify_boot_profile(manifest_bytes, platform_bytes, verifier)

    assert {:error, :untrusted_signer} =
             Envelope.verify_boot_profile(manifest_bytes, signature_bytes, %{
               verifier
               | "trusted_signers" => []
             })
  end

  test "trusted signer key id must bind its injected public key", %{
    manifest_bytes: manifest_bytes,
    platform: platform,
    signature_bytes: signature_bytes,
    verifier: verifier
  } do
    [trusted_signer] = verifier["trusted_signers"]

    mismatched_verifier = %{
      verifier
      | "trusted_signers" => [
          %{trusted_signer | "public_key" => platform.public_key_hex}
        ]
    }

    assert {:error, :signer_key_id_mismatch} =
             Envelope.verify_boot_profile(
               manifest_bytes,
               signature_bytes,
               mismatched_verifier
             )
  end

  test "not-yet-valid, expired, and stale epoch fail closed", %{
    manifest_bytes: manifest_bytes,
    signature_bytes: signature_bytes,
    verifier: verifier
  } do
    assert {:error, :not_yet_valid} =
             Envelope.verify_boot_profile(manifest_bytes, signature_bytes, %{
               verifier
               | "now" => "2026-08-16T23:59:59Z"
             })

    assert {:error, :expired} =
             Envelope.verify_boot_profile(manifest_bytes, signature_bytes, %{
               verifier
               | "now" => "2027-08-17T00:00:01Z"
             })

    assert {:error, :stale_epoch} =
             Envelope.verify_boot_profile(manifest_bytes, signature_bytes, %{
               verifier
               | "min_boot_epoch" => 2
             })
  end

  test "revoked signer and Platform keys fail closed", %{
    manifest: manifest,
    manifest_bytes: manifest_bytes,
    signature_bytes: signature_bytes,
    installer: installer,
    verifier: verifier
  } do
    assert {:error, :signer_revoked} =
             Envelope.verify_boot_profile(manifest_bytes, signature_bytes, %{
               verifier
               | "revoked_signer_key_ids" => [installer.key_id]
             })

    assert {:error, :platform_key_revoked} =
             Envelope.verify_boot_profile(manifest_bytes, signature_bytes, %{
               verifier
               | "revoked_platform_key_ids" => [manifest["platform_key_id"]]
             })
  end

  test "release, profile, payload, and revocation-input mismatches fail closed", %{
    manifest: manifest,
    manifest_bytes: manifest_bytes,
    signature_bytes: signature_bytes,
    verifier: verifier
  } do
    assert {:error, :release_mismatch} =
             Envelope.verify_boot_profile(manifest_bytes, signature_bytes, %{
               verifier
               | "expected_release_id" => "arbor.platform.release.2"
             })

    assert {:error, :profile_mismatch} =
             Envelope.verify_boot_profile(manifest_bytes, signature_bytes, %{
               verifier
               | "expected_profile_id" => "other_profile"
             })

    assert {:error, :revocation_input_mismatch} =
             Envelope.verify_boot_profile(manifest_bytes, signature_bytes, %{
               verifier
               | "expected_revocation_input_id" => "revocation.platform.2"
             })

    [first, second] = manifest["payload_digests"]

    assert {:error, :payload_mismatch} =
             Envelope.verify_boot_profile(manifest_bytes, signature_bytes, %{
               verifier
               | "expected_payload_digests" => [
                   %{first | "sha256" => String.duplicate("33", 32)},
                   second
                 ]
             })

    extra = %{"id" => "payload.other", "sha256" => String.duplicate("44", 32)}

    assert {:error, :payload_mismatch} =
             Envelope.verify_boot_profile(manifest_bytes, signature_bytes, %{
               verifier
               | "expected_payload_digests" => [first, second, extra]
             })

    assert {:error, :invalid_field} =
             Envelope.verify_boot_profile(manifest_bytes, signature_bytes, %{
               verifier
               | "expected_payload_digests" => [second, first]
             })
  end

  test "platform key id must bind the Platform public key", %{
    installer: installer,
    platform: platform
  } do
    manifest = %{
      Envelope.boot_profile_fixture()
      | "platform_key_id" => String.duplicate("00", 32)
    }

    {manifest_bytes, signature_bytes, _signature} = sign_docs(manifest, installer)

    assert {:error, :platform_key_id_mismatch} =
             Envelope.verify_boot_profile(
               manifest_bytes,
               signature_bytes,
               verifier(manifest, installer)
             )

    assert platform.key_id != String.duplicate("00", 32)
  end

  test "atom-key and missing verifier input fail closed", %{
    manifest_bytes: manifest_bytes,
    signature_bytes: signature_bytes,
    verifier: verifier
  } do
    assert {:error, :invalid_verifier_input} =
             Envelope.verify_boot_profile(manifest_bytes, signature_bytes, now: verifier["now"])

    assert {:error, :malformed_encoding} =
             Envelope.verify_boot_profile(%{}, signature_bytes, verifier)
  end

  test "document decode precedes verifier validation when both fail", %{
    manifest_bytes: manifest_bytes,
    signature_bytes: signature_bytes
  } do
    bad_verifier = [now: "2026-08-17T00:00:00Z"]

    assert {:error, :malformed_encoding} =
             Envelope.verify_boot_profile(%{}, signature_bytes, bad_verifier)

    assert {:error, :malformed_encoding} =
             Envelope.verify_boot_profile("{", signature_bytes, bad_verifier)

    assert {:error, :malformed_encoding} =
             Envelope.verify_boot_profile(<<0xFF>>, signature_bytes, bad_verifier)

    assert {:error, :malformed_encoding} =
             Envelope.verify_boot_profile(manifest_bytes, "{", bad_verifier)

    assert {:error, :malformed_encoding} =
             Envelope.verify_boot_profile(manifest_bytes, "null", bad_verifier)

    assert {:error, :malformed_encoding} =
             Envelope.verify_boot_profile(manifest_bytes, "[]", bad_verifier)

    assert {:error, :invalid_envelope_shape} =
             Envelope.verify_boot_profile(manifest_bytes, "{}", bad_verifier)
  end

  test "valid_from after valid_until is rejected", %{manifest: manifest} do
    assert {:error, :invalid_validity_window} =
             Envelope.validate_boot_profile_manifest(%{
               manifest
               | "valid_from" => "2027-08-17T00:00:01Z",
                 "valid_until" => "2027-08-17T00:00:00Z"
             })
  end

  defp verifier(manifest, installer) do
    %{
      "now" => "2026-08-17T00:00:00Z",
      "expected_release_id" => manifest["release_id"],
      "expected_profile_id" => manifest["profile_id"],
      "expected_revocation_input_id" => manifest["revocation_input_id"],
      "expected_payload_digests" => manifest["payload_digests"],
      "min_boot_epoch" => 1,
      "revoked_platform_key_ids" => [],
      "revoked_signer_key_ids" => [],
      "trusted_signers" => [
        %{
          "signer_id" => "installer.arbor",
          "key_id" => installer.key_id,
          "public_key" => installer.public_key_hex
        }
      ]
    }
  end

  defp sign_docs(manifest, installer) do
    sign_docs_with(manifest, installer, installer.private_key)
  end

  defp sign_docs_with(manifest, installer, private_key) do
    {:ok, manifest_bytes} = Envelope.boot_profile_canonical_json(manifest)
    {:ok, digest} = Envelope.boot_profile_digest_of(manifest)

    unsigned = %{
      "schema" => Envelope.boot_profile_signature_schema(),
      "version" => Envelope.boot_profile_version(),
      "domain" => Envelope.boot_profile_schema(),
      "manifest_encoding" => Envelope.boot_profile_payload_encoding(),
      "manifest_sha256" => digest,
      "signer_id" => "installer.arbor",
      "key_id" => installer.key_id,
      "signature" => String.duplicate("00", 64)
    }

    signature = %{
      unsigned
      | "signature" => sign_hex(signing_message(unsigned), %{private_key: private_key})
    }

    {:ok, signature_bytes} = Envelope.boot_profile_signature_canonical_json(signature)
    {manifest_bytes, signature_bytes, signature}
  end

  defp keypair(seed) do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519, seed)

    %{
      public_key: public_key,
      private_key: private_key,
      public_key_hex: Base.encode16(public_key, case: :lower),
      key_id: Base.encode16(:crypto.hash(:sha256, public_key), case: :lower)
    }
  end

  defp signing_message(signature) do
    {:ok, message} = Envelope.boot_profile_signing_message(signature)
    message
  end

  defp sign_hex(message, %{private_key: private_key}) when is_binary(message) do
    private_key
    |> then(&:crypto.sign(:eddsa, :none, message, [&1, :ed25519]))
    |> then(&Base.encode16(&1, case: :lower))
  end

  defp flip_hex(hex) do
    last = String.last(hex)
    flipped = if last == "0", do: "1", else: "0"
    String.slice(hex, 0, byte_size(hex) - 1) <> flipped
  end

  defp lowercase_sha256(bytes) do
    Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
  end
end
