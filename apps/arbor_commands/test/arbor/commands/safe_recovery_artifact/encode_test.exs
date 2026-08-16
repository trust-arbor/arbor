defmodule Arbor.Commands.SafeRecoveryArtifact.EncodeTest do
  use ExUnit.Case, async: true

  alias Arbor.Commands.SafeRecoveryArtifact.{Core, Encode}
  alias Arbor.Commands.SafeRecoveryArtifactFixture, as: Fixture

  @moduletag :fast

  setup do
    {:ok, manifest} = Core.project(Fixture.candidate())
    {:ok, manifest: manifest}
  end

  test "emits compact canonical bytes and a framed domain digest", %{manifest: manifest} do
    assert {:ok, bytes} = Encode.encode_manifest(manifest)
    assert {:ok, ^bytes} = Encode.encode_manifest(manifest)
    refute String.contains?(bytes, "\n")
    refute String.contains?(bytes, "\": ")
    refute String.contains?(bytes, "manifest_digest")

    expected =
      Encode.framed_digest(Encode.manifest_domain(), bytes)

    assert {:ok, ^expected} = Encode.manifest_digest(manifest)
    assert Regex.match?(~r/\A[0-9a-f]{64}\z/, expected)
  end

  test "recomputes derived fields and rejects mutations", %{manifest: manifest} do
    assert :ok = Encode.validate_manifest(manifest)

    bad_digest = String.duplicate("c", 64)

    assert {:error, {:invalid_field, "build_inputs_digest", :derived_mismatch}} =
             Encode.validate_manifest(put_in(manifest, ["source", "build_inputs_digest"], bad_digest))

    assert {:error, {:invalid_field, "payload_tree_digest", :derived_mismatch}} =
             Encode.validate_manifest(put_in(manifest, ["release", "payload_tree_digest"], bad_digest))

    assert {:error, {:invalid_field, "applications_digest", :derived_mismatch}} =
             Encode.validate_manifest(put_in(manifest, ["release", "applications_digest"], bad_digest))

    assert {:error, {:invalid_field, "entry_count", :derived_mismatch}} =
             Encode.validate_manifest(put_in(manifest, ["release", "entry_count"], 0))

    [app | rest] = manifest["applications"]
    relabeled = [%{app | "class" => "third_party"} | rest]

    assert {:error, {:invalid_field, "class", :derived_mismatch}} =
             Encode.validate_manifest(%{manifest | "applications" => relabeled})

    assert {:error, {:invalid_field, "findings", :derived_mismatch}} =
             Encode.validate_manifest(%{manifest | "findings" => []})

    assert {:error, _} = Encode.encode_manifest(%{manifest | "findings" => []})
    assert {:error, _} = Encode.manifest_digest(%{manifest | "findings" => []})
  end

  test "rejects identical reproducibility when evidence disagrees", %{manifest: manifest} do
    repro = %{
      manifest["reproducibility"]
      | "status" => "identical",
        "differing_paths" => ["bin/erlexec"]
    }

    assert {:error, :inconsistent_reproducibility} =
             Encode.validate_manifest(%{manifest | "reproducibility" => repro})

    app_only = %{
      manifest["reproducibility"]
      | "status" => "different",
        "differing_paths" => []
    }

    assert :ok = Encode.validate_manifest(%{manifest | "reproducibility" => app_only})
  end

  test "digest avalanche across domains", %{manifest: manifest} do
    {:ok, payload} = Encode.payload_tree_digest(manifest["entries"])
    {:ok, apps} = Encode.applications_digest(manifest["applications"])
    {:ok, inputs} = Encode.build_inputs_digest(manifest["source"]["build_inputs"])
    {:ok, man} = Encode.manifest_digest(manifest)

    [entry | rest] = manifest["entries"]
    mutated_entries = [%{entry | "mode" => entry["mode"] + 1} | rest]
    {:ok, payload2} = Encode.payload_tree_digest(mutated_entries)
    refute payload2 == payload

    [app | rest_apps] = manifest["applications"]
    mutated_apps = [%{app | "start_type" => "temporary"} | rest_apps]
    {:ok, apps2} = Encode.applications_digest(mutated_apps)
    refute apps2 == apps

    [input | rest_inputs] = manifest["source"]["build_inputs"]
    mutated_inputs = [%{input | "sha256" => String.duplicate("d", 64)} | rest_inputs]
    {:ok, inputs2} = Encode.build_inputs_digest(mutated_inputs)
    refute inputs2 == inputs

    mutated_toolchain = %{manifest["toolchain"] | "mix_lock_sha256" => String.duplicate("e", 64)}
    {:ok, man2} = Encode.manifest_digest(%{manifest | "toolchain" => mutated_toolchain})
    refute man2 == man
  end

  test "checked-in fixture matches Core.project/1" do
    assert {:ok, from_file} = Core.project(Fixture.load_checked_in_fixture())
    assert {:ok, from_builder} = Core.project(Fixture.candidate())
    assert from_file == from_builder
    assert {:ok, bytes} = Encode.encode_manifest(from_file)
    assert {:ok, digest} = Encode.manifest_digest(from_file)
    assert byte_size(digest) == 64
    refute String.contains?(bytes, "manifest_digest")
  end
end
