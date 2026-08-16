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
             Encode.validate_manifest(
               put_in(manifest, ["source", "build_inputs_digest"], bad_digest)
             )

    assert {:error, {:invalid_field, "payload_tree_digest", :derived_mismatch}} =
             Encode.validate_manifest(
               put_in(manifest, ["release", "payload_tree_digest"], bad_digest)
             )

    assert {:error, {:invalid_field, "applications_digest", :derived_mismatch}} =
             Encode.validate_manifest(
               put_in(manifest, ["release", "applications_digest"], bad_digest)
             )

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

    # Residual: app-only drift is status=different with equal payload
    # digests and empty differing_paths. The frozen shape has no second
    # applications digest, so this remains valid Core output.
    app_only = %{
      manifest["reproducibility"]
      | "status" => "different",
        "differing_paths" => []
    }

    assert :ok = Encode.validate_manifest(%{manifest | "reproducibility" => app_only})
  end

  test "rejects mutated application evidence that no longer matches entries", %{
    manifest: manifest
  } do
    [app | rest] = manifest["applications"]
    mutated_hash = [%{app | "app_spec_sha256" => String.duplicate("a", 64)} | rest]
    {:ok, hash_digest} = Encode.applications_digest(mutated_hash)

    assert {:error, {:invalid_field, "app_spec_sha256", :derived_mismatch}} =
             Encode.validate_manifest(%{
               manifest
               | "applications" => mutated_hash,
                 "release" => %{manifest["release"] | "applications_digest" => hash_digest}
             })

    mutated_path = [%{app | "app_spec_path" => "lib/other-1.0.0/ebin/other.app"} | rest]
    {:ok, path_digest} = Encode.applications_digest(mutated_path)

    assert {:error, {:invalid_field, "app_spec_path", :derived_mismatch}} =
             Encode.validate_manifest(%{
               manifest
               | "applications" => mutated_path,
                 "release" => %{manifest["release"] | "applications_digest" => path_digest}
             })

    [entry | entry_rest] = manifest["entries"]
    mutated_owner = [%{entry | "owner_application" => "jason"} | entry_rest]
    {:ok, payload} = Encode.payload_tree_digest(mutated_owner)
    [_, second] = manifest["reproducibility"]["payload_tree_digests"]

    assert {:error, {:invalid_field, "owner_application", :derived_mismatch}} =
             Encode.validate_manifest(%{
               manifest
               | "entries" => mutated_owner,
                 "release" => %{manifest["release"] | "payload_tree_digest" => payload},
                 "reproducibility" => %{
                   manifest["reproducibility"]
                   | "payload_tree_digests" => [payload, second]
                 }
             })

    declared = app["declared_applications"]
    overlap = %{declared | "included" => declared["required"]}
    mutated_deps = [%{app | "declared_applications" => overlap} | rest]
    {:ok, deps_digest} = Encode.applications_digest(mutated_deps)

    assert {:error, :invalid_dependency_list} =
             Encode.validate_manifest(%{
               manifest
               | "applications" => mutated_deps,
                 "release" => %{manifest["release"] | "applications_digest" => deps_digest}
             })
  end

  test "canonical_json/1 rejects atoms and floats" do
    assert {:error, :non_string_keys} = Encode.canonical_json(:atom)
    assert {:error, :unsupported_syntax} = Encode.canonical_json(1.5)
  end

  test "security regression: canonical_json/1 returns bounded errors for invalid UTF-8" do
    invalid = <<0xFF, 0xFF>>

    assert {:error, :invalid_utf8} = Encode.canonical_json(invalid)
    assert {:error, :invalid_utf8} = Encode.canonical_json(["ok", invalid])
    assert {:error, :invalid_utf8} = Encode.canonical_json(%{"k" => invalid})
    assert {:error, :invalid_utf8} = Encode.canonical_json(%{invalid => 1})

    escaped = "a\nb\t\r\"\\"
    assert {:ok, Jason.encode!(escaped)} = Encode.canonical_json(escaped)
    assert {:ok, ~s({"a":1,"b":2})} = Encode.canonical_json(%{"b" => 2, "a" => 1})
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
