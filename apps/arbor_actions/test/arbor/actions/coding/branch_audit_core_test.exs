defmodule Arbor.Actions.Coding.BranchAuditCoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Actions.Coding.BranchAuditCore, as: Core

  @oid String.duplicate("a", 40)
  @destination_oid String.duplicate("b", 40)
  @base_oid String.duplicate("c", 40)

  test "classification gives policy protection and deterministic duplicate survivor" do
    branches = [
      %{"ref" => "refs/heads/preserve/keep", "oid" => @oid},
      %{"ref" => "refs/heads/z-duplicate", "oid" => @oid},
      %{"ref" => "refs/heads/a-duplicate", "oid" => @oid},
      %{"ref" => "refs/heads/unique", "oid" => String.duplicate("b", 40)}
    ]

    entries =
      Core.classify(
        branches,
        %{"ref" => "refs/heads/main", "oid" => String.duplicate("c", 40)},
        %{},
        %{},
        %{}
      )

    assert Enum.map(entries, &{&1["ref"], &1["class"], &1["action"]}) == [
             {"refs/heads/a-duplicate", "duplicate_tip", "archive_and_retire"},
             {"refs/heads/preserve/keep", "explicitly_preserved", "preserve"},
             {"refs/heads/unique", "unclassified", "preserve"},
             {"refs/heads/z-duplicate", "duplicate_tip", "archive_and_retire"}
           ]

    for ref <- ["refs/heads/a-duplicate", "refs/heads/z-duplicate"] do
      entry = Enum.find(entries, &(&1["ref"] == ref))
      assert entry["reason"] == "duplicate_tip_of:refs/heads/preserve/keep"
    end
  end

  test "unprotected duplicate tips preserve exactly the lexical survivor" do
    branches =
      for name <- ["z-duplicate", "a-duplicate", "m-duplicate"] do
        %{"ref" => "refs/heads/#{name}", "oid" => @oid}
      end

    entries =
      Core.classify(
        branches,
        %{"ref" => "refs/heads/main", "oid" => @destination_oid},
        %{},
        %{},
        %{}
      )

    assert Enum.map(entries, &{&1["ref"], &1["action"], &1["reason"]}) == [
             {"refs/heads/a-duplicate", "preserve",
              "deterministic_survivor:refs/heads/a-duplicate"},
             {"refs/heads/m-duplicate", "archive_and_retire",
              "duplicate_tip_of:refs/heads/a-duplicate"},
             {"refs/heads/z-duplicate", "archive_and_retire",
              "duplicate_tip_of:refs/heads/a-duplicate"}
           ]
  end

  test "manifest digest is stable across map insertion order and closed schema rejects extras" do
    body = %{
      "identity" => "git-common",
      "path" => "/repo"
    }

    destination = %{"ref" => "refs/heads/main", "oid" => String.duplicate("b", 40)}
    limits = %{"max_branch_count" => 10, "max_proof_attempts" => 10, "max_manifest_bytes" => 4096}

    {:ok, first} = Core.manifest(body, destination, [], [], limits)

    {:ok, second} =
      Core.manifest(
        Enum.into([{"path", "/repo"}, {"identity", "git-common"}], %{}),
        destination,
        [],
        [],
        limits
      )

    assert first["manifest_sha256"] == second["manifest_sha256"]
    assert Core.canonical_json(first) == Core.canonical_json(second)
    assert {:ok, ^first} = Core.validate_manifest(first)
    assert {:error, _} = Core.validate_manifest(Map.put(first, "unexpected", true))
    assert {:error, _} = Core.validate_manifest(Map.put(first, :format, first["format"]))
  end

  test "manifest JSON decoder rejects duplicate keys before canonicalization" do
    json = ~s({"format":"arbor.coding.branch_audit","format":"other"})
    assert {:error, :duplicate_manifest_key} = Core.decode_manifest_json(json)
  end

  test "manifest-size fallback remains a closed fail-closed schema" do
    destination = %{"ref" => "refs/heads/main", "oid" => @destination_oid}

    entries = [
      %{
        "ref" => "refs/heads/main",
        "oid" => @destination_oid,
        "class" => "unclassified",
        "reason" => "manifest_bytes_limit",
        "action" => "preserve"
      },
      %{
        "ref" => "refs/heads/merged",
        "oid" => @oid,
        "class" => "unclassified",
        "reason" => "manifest_bytes_limit",
        "action" => "preserve"
      }
    ]

    assert {:ok, manifest} =
             Core.manifest(
               repository(),
               destination,
               entries,
               ["manifest_bytes_limit"],
               limits()
             )

    assert {:ok, ^manifest} = Core.validate_manifest(manifest)

    forged =
      manifest
      |> update_branch("refs/heads/merged", &Map.put(&1, "action", "archive_and_retire"))
      |> resign()

    assert {:error, _reason} = Core.validate_manifest(forged)
  end

  test "proof errors normalize to a bounded conservative reason" do
    destination = %{"ref" => "refs/heads/main", "oid" => @destination_oid}
    ref = "refs/heads/error"

    [entry] =
      Core.classify(
        [%{"ref" => ref, "oid" => @oid}],
        destination,
        %{},
        %{ref => {:error, "unsafe reason\n" <> String.duplicate("x", 2_000)}},
        %{}
      )

    assert entry["class"] == "unclassified"
    assert entry["reason"] == "proof_error:unknown"
    assert entry["action"] == "preserve"
    assert {:ok, _manifest} = Core.manifest(repository(), destination, [entry], [], limits())
  end

  test "known bounded proof failures retain useful operator diagnostics" do
    destination = %{"ref" => "refs/heads/main", "oid" => @destination_oid}

    reasons = %{
      "refs/heads/range" => {:error, {:range_too_large, :destination, 256}},
      "refs/heads/storage" =>
        {:error,
         {:invalid_input, {:git_storage_validation_failed, ["--git-path", "objects"], 137, ""}}},
      "refs/heads/command" => {:error, {:invalid_input, {:git_command_failed, 137}}}
    }

    entries =
      Core.classify(
        [
          %{"ref" => "refs/heads/range", "oid" => @oid},
          %{"ref" => "refs/heads/storage", "oid" => String.duplicate("d", 40)},
          %{"ref" => "refs/heads/command", "oid" => String.duplicate("e", 40)}
        ],
        destination,
        %{},
        reasons,
        %{}
      )

    assert Enum.map(entries, &{&1["ref"], &1["reason"]}) == [
             {"refs/heads/command", "proof_error:invalid_input:git_command_failed:137"},
             {"refs/heads/range", "proof_error:range_too_large:destination:256"},
             {"refs/heads/storage",
              "proof_error:invalid_input:git_storage_validation_failed:exit_137"}
           ]

    assert {:ok, _manifest} = Core.manifest(repository(), destination, entries, [], limits())
  end

  test "security regression: recomputed digests cannot authorize unsafe entry semantics" do
    manifest = semantic_manifest()
    assert {:ok, ^manifest} = Core.validate_manifest(manifest)

    unique_retirement =
      update_branch(manifest, "refs/heads/unique", &Map.put(&1, "action", "archive_and_retire"))

    proof_method_mismatch =
      update_branch(manifest, "refs/heads/merged", fn entry ->
        put_in(entry, ["proof", "method"], "patch_equivalence")
      end)

    proof_candidate_mismatch =
      update_branch(manifest, "refs/heads/merged", fn entry ->
        put_in(entry, ["proof", "candidate_commit"], String.duplicate("d", 40))
      end)

    proof_destination_ref_mismatch =
      update_branch(manifest, "refs/heads/merged", fn entry ->
        put_in(entry, ["proof", "destination_ref"], "refs/heads/other")
      end)

    proof_destination_oid_mismatch =
      update_branch(manifest, "refs/heads/merged", fn entry ->
        put_in(entry, ["proof", "destination_commit"], String.duplicate("d", 40))
      end)

    entry_oid_mismatch =
      update_branch(manifest, "refs/heads/merged", fn entry ->
        Map.put(entry, "oid", String.duplicate("d", 40))
      end)

    for tampered <- [
          unique_retirement,
          proof_method_mismatch,
          proof_candidate_mismatch,
          proof_destination_ref_mismatch,
          proof_destination_oid_mismatch,
          entry_oid_mismatch
        ] do
      assert {:error, _reason} = tampered |> resign() |> Core.validate_manifest()
    end
  end

  test "security regression: reviewed branch lists and nested schemas are closed" do
    manifest = semantic_manifest()
    [merged, unique] = manifest["branches"]

    unsorted = Map.put(manifest, "branches", [unique, merged])

    duplicate_refs =
      Map.put(manifest, "branches", [merged, Map.put(unique, "ref", merged["ref"])])

    unsafe_ref =
      Map.put(manifest, "branches", [merged, Map.put(unique, "ref", "refs/heads/bad~ref")])

    repository_extra = put_in(manifest, ["repository", "extra"], true)
    destination_extra = put_in(manifest, ["destination", "extra"], true)
    over_entry_limit = put_in(manifest, ["limits", "max_branch_count"], 1)

    mislabeled_duplicate_tip =
      update_branch(manifest, "refs/heads/unique", &Map.put(&1, "oid", merged["oid"]))

    for tampered <- [
          unsorted,
          duplicate_refs,
          unsafe_ref,
          repository_extra,
          destination_extra,
          over_entry_limit,
          mislabeled_duplicate_tip
        ] do
      assert {:error, _reason} = tampered |> resign() |> Core.validate_manifest()
    end
  end

  test "security regression: duplicate retirement names an existing same-OID survivor" do
    destination = %{"ref" => "refs/heads/main", "oid" => @destination_oid}

    entries =
      Core.classify(
        [
          %{"ref" => "refs/heads/a-copy", "oid" => @oid},
          %{"ref" => "refs/heads/z-copy", "oid" => @oid}
        ],
        destination,
        %{},
        %{},
        %{}
      )

    {:ok, manifest} =
      Core.manifest(repository(), destination, entries, [], limits())

    assert {:ok, ^manifest} = Core.validate_manifest(manifest)

    self_reference =
      update_branch(manifest, "refs/heads/z-copy", fn entry ->
        Map.put(entry, "reason", "duplicate_tip_of:refs/heads/z-copy")
      end)

    missing_survivor =
      update_branch(manifest, "refs/heads/z-copy", fn entry ->
        Map.put(entry, "reason", "duplicate_tip_of:refs/heads/missing")
      end)

    wrong_oid_survivor =
      manifest
      |> Map.update!("branches", fn branches ->
        branches ++
          [
            %{
              "ref" => "refs/heads/y-other",
              "oid" => String.duplicate("d", 40),
              "class" => "checked_out",
              "reason" => "checked_out_ref",
              "action" => "preserve"
            }
          ]
      end)
      |> Map.update!("branches", &Enum.sort_by(&1, fn entry -> entry["ref"] end))
      |> update_branch("refs/heads/z-copy", fn entry ->
        Map.put(entry, "reason", "duplicate_tip_of:refs/heads/y-other")
      end)

    for tampered <- [self_reference, missing_survivor, wrong_oid_survivor] do
      assert {:error, _reason} = tampered |> resign() |> Core.validate_manifest()
    end
  end

  defp semantic_manifest do
    destination = %{"ref" => "refs/heads/main", "oid" => @destination_oid}

    entries = [
      %{
        "ref" => "refs/heads/merged",
        "oid" => @oid,
        "class" => "merged",
        "reason" => "tip_is_ancestor_of_destination",
        "action" => "archive_and_retire",
        "proof" => ancestry_proof()
      },
      %{
        "ref" => "refs/heads/unique",
        "oid" => String.duplicate("d", 40),
        "class" => "unique",
        "reason" => "patch_not_represented_on_destination",
        "action" => "preserve"
      }
    ]

    {:ok, manifest} = Core.manifest(repository(), destination, entries, [], limits())
    manifest
  end

  defp ancestry_proof do
    %{
      "method" => "ancestry",
      "base_commit" => @base_oid,
      "candidate_commit" => @oid,
      "destination_ref" => "refs/heads/main",
      "destination_commit" => @destination_oid,
      "candidate_commit_count" => 1,
      "audit" => %{"candidate_range_count" => 1}
    }
  end

  defp repository, do: %{"identity" => "/repo/.git", "path" => "/repo"}

  defp limits,
    do: %{"max_branch_count" => 10, "max_proof_attempts" => 10, "max_manifest_bytes" => 4096}

  defp update_branch(manifest, ref, update) do
    Map.update!(manifest, "branches", fn branches ->
      Enum.map(branches, fn entry -> if entry["ref"] == ref, do: update.(entry), else: entry end)
    end)
  end

  defp resign(manifest), do: Map.put(manifest, "manifest_sha256", Core.digest(manifest))
end
