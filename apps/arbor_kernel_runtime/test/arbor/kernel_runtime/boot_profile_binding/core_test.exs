defmodule Arbor.KernelRuntime.BootProfileBinding.CoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Extension.Envelope
  alias Arbor.KernelRuntime.BootProfileBinding.Core

  @moduletag :fast

  @forbidden_impurity [
    ~r/DateTime\.utc_now/,
    ~r/System\.(monotonic|os|system)_time/,
    ~r/:rand\./,
    ~r/:erlang\.unique_integer/,
    ~r/\bmake_ref\s*\(/,
    ~r/Application\.(get_env|fetch_env|put_env)/,
    ~r/GenServer\.(call|cast|reply|start_link|start)\b/,
    ~r/:ets\./,
    ~r/\bLogger\./,
    ~r/\bProcess\.(send|send_after|monitor|spawn)/,
    ~r/\bFile\.(read|write|open|rm|ls)/,
    ~r/String\.to_atom/,
    ~r/:persistent_term\./,
    ~r{Envelope\.verify_boot_profile\s*\(}
  ]

  @digest "374dabaf63c89a46a92b87bbf0f2e871330ecfe01eb9a230560137b1a7a18268"
  @installer_key_id "37eb0623867f14c690e51a9e24c55fd98ae4b353a00cd3a37ec953330ddda395"

  test "project/1 returns the closed snapshot from an Envelope success map" do
    manifest = Envelope.boot_profile_fixture()

    assert {:ok, snapshot} =
             Core.project(%{
               "manifest" => manifest,
               "manifest_sha256" => @digest,
               "signer_id" => "installer.arbor",
               "signer_key_id" => @installer_key_id
             })

    assert snapshot["schema"] == Core.schema()
    assert snapshot["version"] == 1
    assert snapshot["manifest_sha256"] == @digest
    assert snapshot["release_id"] == manifest["release_id"]
    assert snapshot["profile_id"] == manifest["profile_id"]
    assert snapshot["boot_epoch"] == manifest["boot_epoch"]
    assert snapshot["platform_public_key"] == manifest["platform_public_key"]
    assert snapshot["platform_key_id"] == manifest["platform_key_id"]
    assert snapshot["payload_digests"] == manifest["payload_digests"]
    assert snapshot["revocation_input_id"] == manifest["revocation_input_id"]
    assert snapshot["valid_from"] == manifest["valid_from"]
    assert snapshot["valid_until"] == manifest["valid_until"]
    assert snapshot["signer_id"] == "installer.arbor"
    assert snapshot["signer_key_id"] == @installer_key_id
    refute Map.has_key?(snapshot, "trusted_signers")
    refute Map.has_key?(snapshot, "now")
  end

  test "project/1 rejects extra, missing, and mixed keys" do
    manifest = Envelope.boot_profile_fixture()

    ok = %{
      "manifest" => manifest,
      "manifest_sha256" => @digest,
      "signer_id" => "installer.arbor",
      "signer_key_id" => @installer_key_id
    }

    assert {:error, :invalid_verify_result} = Core.project(Map.put(ok, "extra", "no"))
    assert {:error, :invalid_verify_result} = Core.project(Map.delete(ok, "signer_id"))
    assert {:error, :invalid_verify_result} = Core.project(Map.put(ok, :signer_id, "x"))
    assert {:error, :invalid_verify_result} = Core.project(%{})
    assert {:error, :invalid_verify_result} = Core.project(:nope)
  end

  test "identity_token/1 is stable for the same stage-zero and changes when roots change" do
    stage = stage_zero()
    assert {:ok, token} = Core.identity_token(stage)
    assert {:ok, ^token} = Core.identity_token(stage)
    assert byte_size(token) == 32
    assert Core.same_identity?(token, token)

    mutated = %{stage | "expected_release_id" => "arbor.platform.release.2"}
    assert {:ok, other} = Core.identity_token(mutated)
    refute Core.same_identity?(token, other)
    refute Core.same_identity?(token, "short")

    assert {:error, :malformed_stage_zero} =
             Core.identity_token(Map.put(stage, "now", "2026-08-17T00:00:00Z"))

    assert {:error, :malformed_stage_zero} =
             Core.identity_token(Map.put(stage, "extra", "no"))

    assert {:error, :malformed_stage_zero} =
             Core.identity_token(Map.delete(stage, "trusted_signers"))
  end

  test "admit_snapshot/1 requires the exact closed snapshot shape" do
    manifest = Envelope.boot_profile_fixture()

    assert {:ok, snapshot} =
             Core.project(%{
               "manifest" => manifest,
               "manifest_sha256" => @digest,
               "signer_id" => "installer.arbor",
               "signer_key_id" => @installer_key_id
             })

    assert {:ok, ^snapshot} = Core.admit_snapshot(snapshot)
    assert {:error, :invalid_snapshot} = Core.admit_snapshot(Map.put(snapshot, "extra", "no"))
    assert {:error, :invalid_snapshot} = Core.admit_snapshot(Map.delete(snapshot, "schema"))
    assert {:error, :invalid_snapshot} = Core.admit_snapshot(%{snapshot | "schema" => "other"})
    assert {:error, :invalid_snapshot} = Core.admit_snapshot(:nope)
  end

  test "verifier_input/2 inserts now without changing identity-bearing fields" do
    stage = stage_zero()
    input = Core.verifier_input(stage, "2026-08-17T00:00:00Z")

    assert input["now"] == "2026-08-17T00:00:00Z"
    assert input["trusted_signers"] == stage["trusted_signers"]
    assert input["expected_release_id"] == stage["expected_release_id"]
    assert input["min_boot_epoch"] == 1
    refute Map.has_key?(input, "manifest_bytes")
  end

  test "the core source stays free of Process, IO, Application, time, and verify" do
    path =
      Path.expand(
        "../../../../lib/arbor/kernel_runtime/boot_profile_binding/core.ex",
        __DIR__
      )

    assert File.exists?(path)
    src = File.read!(path)

    Enum.each(@forbidden_impurity, fn re ->
      refute Regex.match?(re, src),
             "impure pattern #{inspect(re.source)} found in #{Path.basename(path)}"
    end)
  end

  defp stage_zero do
    %{
      "manifest_bytes" => "m",
      "signature_bytes" => "s",
      "trusted_signers" => [
        %{
          "signer_id" => "installer.arbor",
          "key_id" => @installer_key_id,
          "public_key" => "347f4f2c0221027fb01086e2d5b8ee0264ae43ddb99aea3dacf04ce0331f89b8"
        }
      ],
      "expected_release_id" => "arbor.platform.release.1",
      "expected_profile_id" => "safe_recovery",
      "expected_revocation_input_id" => "revocation.platform.1",
      "expected_payload_digests" => Envelope.boot_profile_fixture()["payload_digests"],
      "min_boot_epoch" => 1,
      "revoked_signer_key_ids" => [],
      "revoked_platform_key_ids" => []
    }
  end
end
