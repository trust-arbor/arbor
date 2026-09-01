defmodule Arbor.Actions.Coding.CandidateMaterializationAdmissionCoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Actions.Coding.CandidateMaterializationAdmissionCore, as: Core
  alias Arbor.Contracts.Coding.CandidateMaterialization

  @moduletag :fast

  @oid40_a String.duplicate("a", 40)
  @oid40_b String.duplicate("b", 40)
  @oid40_c String.duplicate("c", 40)
  @oid40_d String.duplicate("d", 40)
  @oid64_a String.duplicate("a", 64)
  @oid64_b String.duplicate("b", 64)
  @oid64_c String.duplicate("c", 64)

  defp descriptor_attrs(overrides \\ %{}) do
    %{
      "source_commit_oid" => @oid40_a,
      "expected_tree_oid" => @oid40_b,
      "entries" => [
        %{"path" => "lib/a.ex", "blob_oid" => @oid40_c, "mode" => 100_644}
      ]
    }
    |> Map.merge(overrides)
  end

  defp admitted_descriptor(overrides \\ %{}) do
    {:ok, descriptor} = CandidateMaterialization.new(descriptor_attrs(overrides))
    descriptor
  end

  defp blob(path, oid, mode \\ "100644") do
    %{path: path, mode: mode, oid: oid}
  end

  defp lookup do
    %{
      task_id: "task_g5b2a",
      principal_id: "agent_g5b2a",
      workspace_id: "ws_g5b2a"
    }
  end

  defp lease(overrides \\ %{}) do
    Map.merge(
      %{
        task_id: "task_g5b2a",
        principal_id: "agent_g5b2a",
        workspace_id: "ws_g5b2a",
        active: true,
        base_commit: @oid40_d,
        repo_path: "/tmp/repo"
      },
      overrides
    )
  end

  defp facts(overrides \\ %{}) do
    descriptor = admitted_descriptor()

    Map.merge(
      %{
        descriptor: descriptor,
        source_object_type: "commit",
        source_is_descendant: true,
        observed_source_tree_oid: descriptor.expected_tree_oid,
        observed_base_tree_oid: @oid40_d,
        base_commit: @oid40_d,
        base_manifest: [blob("README.md", @oid40_a)],
        candidate_manifest: [
          blob("README.md", @oid40_a),
          blob("lib/a.ex", @oid40_c)
        ]
      },
      overrides
    )
  end

  test "admit_input accepts closed identities and re-admits the kernel descriptor" do
    assert {:ok, request} =
             Core.admit_input(%{
               workspace_id: "ws_g5b2a",
               task_id: "task_g5b2a",
               principal_id: "agent_g5b2a",
               candidate_materialization: descriptor_attrs()
             })

    assert request.workspace_id == "ws_g5b2a"
    assert request.descriptor.source_commit_oid == @oid40_a
  end

  test "admit_input rejects invented identity/base keys including base_commit" do
    assert {:error, {:unknown_fields, ["base_commit"]}} =
             Core.admit_input(%{
               workspace_id: "ws_g5b2a",
               task_id: "task_g5b2a",
               principal_id: "agent_g5b2a",
               base_commit: @oid40_d,
               candidate_materialization: descriptor_attrs()
             })
  end

  test "admit_input rejects duplicate atom/string aliases" do
    assert {:error, {:duplicate_fields, ["workspace_id"]}} =
             Core.admit_input(%{
               "workspace_id" => "ws_other",
               workspace_id: "ws_g5b2a",
               task_id: "task_g5b2a",
               principal_id: "agent_g5b2a",
               candidate_materialization: descriptor_attrs()
             })
  end

  test "authorize_identity exact-compares lookup identities with the lease" do
    assert {:ok, authorized} = Core.authorize_identity(lookup(), lease())
    assert authorized.base_commit == @oid40_d
    assert authorized.repo_path == "/tmp/repo"
  end

  test "authorize_identity does not succeed by copying request identities into the lease" do
    assert {:error, :invalid_task_principal} =
             Core.authorize_identity(lookup(), %{
               workspace_id: "ws_g5b2a",
               active: true,
               base_commit: @oid40_d,
               repo_path: "/tmp/repo"
             })

    assert {:error, :workspace_unauthorized} =
             Core.authorize_identity(
               lookup(),
               lease(%{task_id: "task_other", principal_id: "agent_other"})
             )
  end

  test "authorize_identity rejects wrong task, principal, workspace, and inactive leases" do
    assert {:error, :workspace_unauthorized} =
             Core.authorize_identity(lookup(), lease(%{task_id: "task_other"}))

    assert {:error, :workspace_unauthorized} =
             Core.authorize_identity(lookup(), lease(%{principal_id: "agent_other"}))

    assert {:error, :workspace_unauthorized} =
             Core.authorize_identity(lookup(), lease(%{workspace_id: "ws_other"}))

    assert {:error, :inactive_workspace_lease} =
             Core.authorize_identity(lookup(), lease(%{active: false}))
  end

  test "prove_trees_and_delta succeeds for an exact add of a regular blob" do
    assert {:ok, proof} = Core.prove_trees_and_delta(facts())
    assert proof.object_format == :sha1
    assert proof.changed_paths == ["lib/a.ex"]
  end

  test "prove_trees_and_delta fails closed on missing source, non-descendant, and tree mismatch" do
    assert {:error, :source_commit_missing} =
             Core.prove_trees_and_delta(facts(%{source_object_type: "blob"}))

    assert {:error, :source_not_descendant} =
             Core.prove_trees_and_delta(facts(%{source_is_descendant: false}))

    assert {:error, :admitted_tree_mismatch} =
             Core.prove_trees_and_delta(facts(%{observed_source_tree_oid: @oid40_a}))
  end

  test "prove_trees_and_delta requires observed_base_tree_oid even when the base manifest is empty" do
    empty_candidate = [blob("lib/a.ex", @oid40_c)]

    empty_base =
      facts(%{
        base_manifest: [],
        candidate_manifest: empty_candidate,
        observed_base_tree_oid: nil
      })

    assert {:error, :base_tree_oid_unavailable} = Core.prove_trees_and_delta(empty_base)

    assert {:ok, proof} =
             Core.prove_trees_and_delta(
               facts(%{
                 base_manifest: [],
                 candidate_manifest: empty_candidate,
                 observed_base_tree_oid: @oid40_d
               })
             )

    assert proof.object_format == :sha1

    assert {:error, :mixed_object_format} =
             Core.prove_trees_and_delta(
               facts(%{
                 base_manifest: [],
                 candidate_manifest: empty_candidate,
                 observed_base_tree_oid: @oid64_a,
                 base_commit: @oid64_a
               })
             )
  end

  test "prove_trees_and_delta rejects extra, missing, deleted, and non-regular deltas" do
    extra =
      admitted_descriptor(%{
        "entries" => [
          %{"path" => "lib/a.ex", "blob_oid" => @oid40_c, "mode" => 100_644},
          %{"path" => "lib/z.ex", "blob_oid" => @oid40_a, "mode" => 100_644}
        ]
      })

    assert {:error, :extra_descriptor_path} =
             Core.prove_trees_and_delta(facts(%{descriptor: extra}))

    missing =
      admitted_descriptor(%{
        "entries" => [%{"path" => "lib/only.ex", "blob_oid" => @oid40_c, "mode" => 100_644}]
      })

    assert {:error, :missing_descriptor_path} =
             Core.prove_trees_and_delta(
               facts(%{
                 descriptor: missing,
                 candidate_manifest: [
                   blob("README.md", @oid40_a),
                   blob("lib/a.ex", @oid40_c),
                   blob("lib/only.ex", @oid40_c)
                 ]
               })
             )

    assert {:error, :descriptor_deletion} =
             Core.prove_trees_and_delta(
               facts(%{
                 candidate_manifest: [],
                 descriptor:
                   admitted_descriptor(%{
                     "entries" => [
                       %{"path" => "README.md", "blob_oid" => @oid40_a, "mode" => 100_644}
                     ]
                   })
               })
             )

    assert {:error, :non_regular_changed_entry} =
             Core.prove_trees_and_delta(
               facts(%{
                 candidate_manifest: [
                   blob("README.md", @oid40_a),
                   blob("lib/a.ex", @oid40_c, "120000")
                 ]
               })
             )
  end

  test "prove_trees_and_delta rejects mode/OID and mixed-format mismatches" do
    assert {:error, :descriptor_mode_oid_mismatch} =
             Core.prove_trees_and_delta(
               facts(%{
                 candidate_manifest: [blob("README.md", @oid40_a), blob("lib/a.ex", @oid40_a)]
               })
             )

    assert {:error, :descriptor_mode_oid_mismatch} =
             Core.prove_trees_and_delta(
               facts(%{
                 candidate_manifest: [
                   blob("README.md", @oid40_a),
                   blob("lib/a.ex", @oid40_c, "100755")
                 ]
               })
             )

    sha256_descriptor =
      admitted_descriptor(%{
        "source_commit_oid" => @oid64_a,
        "expected_tree_oid" => @oid64_b,
        "entries" => [%{"path" => "lib/a.ex", "blob_oid" => @oid64_c, "mode" => 100_644}]
      })

    assert {:error, :mixed_object_format} =
             Core.prove_trees_and_delta(
               facts(%{
                 descriptor: sha256_descriptor,
                 observed_source_tree_oid: @oid64_b,
                 candidate_manifest: [
                   blob("README.md", @oid40_a),
                   blob("lib/a.ex", @oid64_c)
                 ]
               })
             )
  end

  test "prove_trees_and_delta preserves unchanged symlinks outside the descriptor" do
    assert {:ok, proof} =
             Core.prove_trees_and_delta(
               facts(%{
                 base_manifest: [
                   blob("README.md", @oid40_a),
                   blob("priv/link", @oid40_d, "120000")
                 ],
                 candidate_manifest: [
                   blob("README.md", @oid40_a),
                   blob("lib/a.ex", @oid40_c),
                   blob("priv/link", @oid40_d, "120000")
                 ]
               })
             )

    assert proof.changed_paths == ["lib/a.ex"]
  end

  test "decide_effects emits snapshot then pin and never a Mix launch" do
    {:ok, proof} = Core.prove_trees_and_delta(facts())
    assert {:ok, :commit, effects} = Core.decide_effects(proof, lookup())
    assert [{:materialize_object_snapshot, snap}, {:pin_evidence_ref, pin}] = effects
    assert snap.source_commit_oid == @oid40_a
    assert pin.task_id == "task_g5b2a"
    refute Enum.any?(effects, fn {kind, _} -> kind in [:run_mix, :launch_validation] end)
  end
end
