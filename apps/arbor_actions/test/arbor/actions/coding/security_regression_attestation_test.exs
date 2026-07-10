defmodule Arbor.Actions.Coding.SecurityRegression.AttestationTest do
  use ExUnit.Case, async: true

  alias Arbor.Actions.Coding.SecurityRegression.Attestation

  @moduletag :fast

  test "canonical digest is deterministic and binds every reviewed-tree field and council digest" do
    material = %{
      workspace_id: "ws_123",
      base_commit: String.duplicate("a", 40),
      candidate_commit: String.duplicate("b", 40),
      candidate_tree_oid: String.duplicate("c", 40),
      diff_sha256: String.duplicate("d", 64),
      selected_tests: [%{path: "test/security_test.exs", blob_sha256: String.duplicate("e", 64)}],
      validation_profile: "security_regression"
    }

    council = String.duplicate("f", 64)
    assert {:ok, first} = Attestation.new(material, council)
    assert {:ok, second} = Attestation.new(material, council)
    assert first.canonical_digest == second.canonical_digest

    assert {:ok, changed_tree} =
             Attestation.new(%{material | candidate_tree_oid: String.duplicate("1", 40)}, council)

    assert {:ok, changed_test} =
             Attestation.new(
               %{
                 material
                 | selected_tests: [
                     %{path: "test/security_test.exs", blob_sha256: String.duplicate("2", 64)}
                   ]
               },
               council
             )

    assert {:ok, changed_council} = Attestation.new(material, String.duplicate("3", 64))

    refute first.canonical_digest == changed_tree.canonical_digest
    refute first.canonical_digest == changed_test.canonical_digest
    refute first.canonical_digest == changed_council.canonical_digest
  end

  test "rejects invalid git hashes and hostile selected paths" do
    material = %{
      workspace_id: "ws_123",
      base_commit: String.duplicate("a", 40),
      candidate_commit: String.duplicate("b", 40),
      candidate_tree_oid: String.duplicate("c", 40),
      diff_sha256: String.duplicate("d", 64),
      selected_tests: [%{path: "../escape_test.exs", blob_sha256: String.duplicate("e", 64)}],
      validation_profile: "security_regression"
    }

    assert {:error, :invalid_review_material} =
             Attestation.new(material, String.duplicate("f", 64))

    assert {:error, :invalid_review_material} =
             Attestation.new(
               %{material | selected_tests: [%{path: "test/good_test.exs", blob_sha256: "bad"}]},
               String.duplicate("f", 64)
             )
  end
end
