defmodule Arbor.Commands.SafeRecoveryArtifact.BuildVerifyCoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Commands.SafeRecoveryArtifact.{BuildVerifyCore, Encode}
  alias Arbor.Commands.TwoBuildFactFixture, as: TB

  @moduletag :fast

  setup_all do
    {:ok, manifest} =
      Arbor.Commands.SafeRecoveryArtifact.compose_from_facts_for_test(%{
        mode: :compose,
        facts: TB.facts()
      })

    %{manifest: manifest}
  end

  test "identical evidence admits", ctx do
    assert :ok = BuildVerifyCore.equal_evidence(ctx.manifest, ctx.manifest)
  end

  test "only the Git provenance pointers are exempt: commit and tree may advance", ctx do
    moved =
      ctx.manifest
      |> put_in(["source", "commit"], String.duplicate("a", 40))
      |> put_in(["source", "tree"], String.duplicate("b", 40))

    assert {:ok, moved_digest} = Encode.manifest_digest(moved)
    assert {:ok, committed_digest} = Encode.manifest_digest(ctx.manifest)
    assert moved_digest != committed_digest
    assert :ok = BuildVerifyCore.equal_evidence(ctx.manifest, moved)
  end

  test "different reproducibility evidence fails closed with both digests", ctx do
    repro = %{
      ctx.manifest["reproducibility"]
      | "payload_tree_digests" => [
          hd(ctx.manifest["reproducibility"]["payload_tree_digests"]),
          String.duplicate("c", 64)
        ]
    }

    fresh = %{ctx.manifest | "reproducibility" => Map.put(repro, "status", "different")}
    assert :ok = Encode.validate_manifest(fresh)

    assert {:error, {:build_verify_mismatch, info}} =
             BuildVerifyCore.equal_evidence(ctx.manifest, fresh)

    assert {:ok, committed_digest} = Encode.manifest_digest(ctx.manifest)
    assert {:ok, fresh_digest} = Encode.manifest_digest(fresh)
    assert info[:committed_manifest_digest] == committed_digest
    assert info[:fresh_manifest_digest] == fresh_digest
    assert info[:committed_manifest_digest] != info[:fresh_manifest_digest]
  end

  test "different build inputs fail closed even when internally re-digested", ctx do
    source = ctx.manifest["source"]
    [first_input | rest] = source["build_inputs"]
    changed = [%{first_input | "sha256" => String.duplicate("d", 64)} | rest]
    {:ok, inputs_digest} = Encode.build_inputs_digest(changed)

    fresh =
      %{ctx.manifest | "source" => %{source | "build_inputs" => changed}}
      |> put_in(["source", "build_inputs_digest"], inputs_digest)

    assert :ok = Encode.validate_manifest(fresh)

    assert {:error, {:build_verify_mismatch, _info}} =
             BuildVerifyCore.equal_evidence(ctx.manifest, fresh)
  end

  # Applications, entries, and findings differences are isomorphic to the
  # two cases above: every manifest field participates in the compared
  # canonical bytes, and a manifest with different applications/entries only
  # validates when its derived findings and release facts are recomputed --
  # which still changes the compared bytes.

  test "non-manifest shapes fail closed", ctx do
    assert {:error, :invalid_manifest} = BuildVerifyCore.equal_evidence(ctx.manifest, :nope)
    assert {:error, :invalid_manifest} = BuildVerifyCore.equal_evidence(:nope, ctx.manifest)
  end
end
