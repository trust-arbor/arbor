defmodule Arbor.KernelRuntime.ConfigTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Extension.Envelope
  alias Arbor.KernelRuntime.Config

  @moduletag :fast

  @fixture_dir Path.expand(
                 "../../../../arbor_kernel/test/fixtures/extension_envelopes/v1",
                 __DIR__
               )
  @installer_key_id "37eb0623867f14c690e51a9e24c55fd98ae4b353a00cd3a37ec953330ddda395"
  @installer_public_key "347f4f2c0221027fb01086e2d5b8ee0264ae43ddb99aea3dacf04ce0331f89b8"

  setup do
    before = Application.fetch_env(:arbor_kernel, :kernel_runtime)
    on_exit(fn -> restore(before) end)
    :ok
  end

  test "admits the closed P1A-1 fixture stage-zero" do
    put_boot_profile(fixture_boot_profile())
    assert {:ok, stage} = Config.boot_profile_stage_zero()
    assert stage["expected_release_id"] == "arbor.platform.release.1"
    assert length(stage["trusted_signers"]) == 1
    refute Map.has_key?(stage, "now")
  end

  test "rejects unbounded lists and strings without calling Envelope" do
    signer = hd(fixture_boot_profile()[:trusted_signers])

    assert {:error, :malformed_stage_zero} =
             stage(trusted_signers: List.duplicate(signer, 33))

    assert {:error, :malformed_stage_zero} =
             stage(expected_payload_digests: [])

    digest = hd(Envelope.boot_profile_fixture()["payload_digests"])

    assert {:error, :malformed_stage_zero} =
             stage(expected_payload_digests: List.duplicate(digest, 33))

    assert {:error, :malformed_stage_zero} =
             stage(revoked_signer_key_ids: List.duplicate(@installer_key_id, 33))

    assert {:error, :malformed_stage_zero} =
             stage(expected_release_id: String.duplicate("a", 129))

    assert {:error, :malformed_stage_zero} =
             stage(
               trusted_signers: [
                 %{signer | "public_key" => String.duplicate("a", 65)}
               ]
             )

    assert {:error, :malformed_stage_zero} =
             stage(manifest_bytes: String.duplicate("x", 16_385))

    assert {:error, :malformed_stage_zero} =
             stage(revoked_signer_key_ids: [@installer_key_id | :not_a_list])
  end

  test "malformed namespace is a fail-closed stage-zero error, not a raise" do
    Application.put_env(:arbor_kernel, :kernel_runtime, :not_a_keyword)
    assert {:error, :malformed_stage_zero} = Config.boot_profile_stage_zero()
  end

  defp stage(overrides) do
    put_boot_profile(fixture_boot_profile(overrides))
    Config.boot_profile_stage_zero()
  end

  defp put_boot_profile(boot_profile) do
    current = Application.get_env(:arbor_kernel, :kernel_runtime, []) || []

    Application.put_env(
      :arbor_kernel,
      :kernel_runtime,
      Keyword.put(current, :boot_profile, boot_profile)
    )
  end

  defp restore({:ok, value}), do: Application.put_env(:arbor_kernel, :kernel_runtime, value)
  defp restore(:error), do: Application.delete_env(:arbor_kernel, :kernel_runtime)

  defp fixture_boot_profile(overrides \\ []) do
    Keyword.merge(
      [
        manifest_bytes: File.read!(Path.join(@fixture_dir, "boot_profile_manifest.json")),
        signature_bytes: File.read!(Path.join(@fixture_dir, "boot_profile_signature.json")),
        trusted_signers: [
          %{
            "signer_id" => "installer.arbor",
            "key_id" => @installer_key_id,
            "public_key" => @installer_public_key
          }
        ],
        expected_release_id: "arbor.platform.release.1",
        expected_profile_id: "safe_recovery",
        expected_revocation_input_id: "revocation.platform.1",
        expected_payload_digests: Envelope.boot_profile_fixture()["payload_digests"],
        min_boot_epoch: 1,
        revoked_signer_key_ids: [],
        revoked_platform_key_ids: []
      ],
      overrides
    )
  end
end
