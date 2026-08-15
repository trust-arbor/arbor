defmodule Arbor.Commands.KernelMaterialization.CoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Commands.KernelMaterialization
  alias Arbor.Commands.KernelMaterialization.{Core, Encode, Evidence}
  alias Arbor.Commands.KernelMaterializationFixtures
  alias Arbor.Commands.SourceCoupling.GitInventory

  @moduletag :fast

  test "project+encode is deterministic" do
    files = fixture_files()
    assert {:ok, plan1} = Core.project(files)
    assert {:ok, plan2} = Core.project(files)
    assert {:ok, bytes1} = Encode.encode_plan(plan1)
    assert {:ok, bytes2} = Encode.encode_plan(plan2)
    assert bytes1 == bytes2
    assert plan1["entries_digest"] == plan2["entries_digest"]
    assert byte_size(plan1["entries_digest"]) == 64
    refute Map.has_key?(plan1, "phase")
    refute Map.has_key?(plan1, "status")
    refute Map.has_key?(plan1, "tree_oid")
  end

  test "accepts SHA-1 and SHA-256 OIDs and rejects mixed lengths" do
    sha1 = file("apps/arbor_contracts/lib/a.ex", "one\n")
    assert {:ok, [admitted]} = Core.admit_blobs([sha1], "sha1")
    assert admitted.blob_oid == Encode.git_blob_oid("one\n", "sha1")
    assert byte_size(admitted.blob_oid) == 40

    sha256 = file("apps/arbor_contracts/lib/a.ex", "one\n", format: "sha256")
    assert {:ok, [admitted256]} = Core.admit_blobs([sha256], "sha256")
    assert byte_size(admitted256.blob_oid) == 64

    mixed = [sha1, %{sha256 | path: "apps/arbor_contracts/lib/b.ex"}]
    assert {:error, :mixed_object_format} = Core.admit_blobs(mixed, "sha1")

    bad = %{sha1 | blob_oid: Encode.git_blob_oid("other\n", "sha1")}

    assert {:error, {:oid_content_mismatch, "apps/arbor_contracts/lib/a.ex"}} =
             Core.admit_blobs([bad], "sha1")
  end

  test "generic projection classifies exact moves and reviewed collisions" do
    assert {:ok, plan} = Core.project(fixture_files())
    assert plan["counts"]["source_entries"] == 10
    assert plan["counts"]["exact_moves"] == 2
    assert plan["counts"]["transform_inputs"] == 8
    assert plan["counts"]["collision_destinations"] == 4

    assert Enum.any?(
             plan["retained_targets"],
             &(&1["path"] == "apps/arbor_kernel/lib/arbor/kernel.ex")
           )

    assert Enum.all?(plan["entries"], fn entry ->
             if entry["disposition"] == "transform_input" do
               entry["destination_path"] in Core.collision_destinations()
             else
               true
             end
           end)
  end

  test "reviewed semantic transforms remain distinct from collision transforms" do
    semantic_source = "apps/arbor_contracts/lib/a.ex"

    assert {:ok, plan} =
             Core.project(fixture_files(),
               semantic_transform_source_paths: MapSet.new([semantic_source])
             )

    semantic_entry = Enum.find(plan["entries"], &(&1["source_path"] == semantic_source))
    assert semantic_entry["disposition"] == "transform_input"
    assert semantic_entry["collision_group"] == ""
    assert semantic_entry["target_precondition"] == "expected_absent"
    assert plan["counts"]["exact_moves"] == 1
    assert plan["counts"]["transform_inputs"] == 9
    assert plan["counts"]["collision_destinations"] == 4
    assert {:ok, _} = Core.admit_plan(plan)

    rows =
      plan
      |> Core.transform_destinations()
      |> Enum.map(&evidence_row(&1, "transform", "merged #{&1}\n"))

    assert {:ok, evidence} = Evidence.admit(evidence_doc(plan["entries_digest"], rows), plan)

    dest_files = materialized_dest_files(plan, fixture_files(), evidence)
    presence_none = Map.new(Core.source_apps(), &{&1, false})

    assert {:ok, report} =
             KernelMaterialization.run_for_test(
               mode: "check",
               phase: "materialized",
               root: tmp_root(),
               plan_map: plan,
               evidence_map: evidence,
               dest_files: dest_files,
               target_files: Map.values(dest_files),
               source_presence: presence_none
             )

    assert report["status"] == "ok"
  end

  test "unclassified collision fails outside the reviewed dest set" do
    files =
      fixture_files() ++
        [
          file("apps/arbor_common/README.md", "c\n"),
          file("apps/arbor_signals/README.md", "s\n")
        ]

    assert {:error, {:unclassified_collision, "apps/arbor_kernel_runtime/README.md"}} =
             Core.project(files)
  end

  test "excludes private arbor_integrations from projection" do
    files = fixture_files() ++ [file("apps/arbor_integrations/lib/x.ex", "priv\n")]
    assert {:ok, plan} = Core.project(files)
    refute Enum.any?(plan["entries"], &String.contains?(&1["source_path"], "integrations"))
  end

  test "enforce_production_policy derives counts from rows, not declared counts" do
    policy = Core.production_policy()
    assert policy["source_entries"] == 640
    assert policy["exact_moves"] == 610
    assert policy["transform_inputs"] == 30
    assert policy["collision_destinations"] == 4
    assert length(policy["semantic_transform_source_paths"]) == 22

    stub = production_stub_plan()
    assert {:error, :accepted_count_mismatch} = Core.enforce_production_policy(stub)

    {:ok, small} = Core.project(fixture_files())
    assert {:error, :accepted_count_mismatch} = Core.enforce_production_policy(small)

    dropped = %{stub | "retained_targets" => []}
    assert {:error, :accepted_count_mismatch} = Core.enforce_production_policy(dropped)
  end

  test "admit_plan rejects mutable, report, and unknown fields" do
    {:ok, plan} = Core.project(fixture_files())
    assert {:ok, _} = Core.admit_plan(plan)

    Enum.each(
      ["phase", "status", "tree_oid", "planned_tree_oid", "mode", "comparison", "errors"],
      fn key ->
        assert {:error, :plan_not_immutable} = Core.admit_plan(Map.put(plan, key, "x"))
      end
    )

    assert {:error, :plan_digest_mismatch} =
             Core.admit_plan(%{plan | "entries_digest" => String.duplicate("a", 64)})

    [first | rest] = plan["entries"]
    nested_unknown = redigest(%{plan | "entries" => [Map.put(first, "unknown", true) | rest]})
    assert {:error, :plan_not_immutable} = Core.admit_plan(nested_unknown)

    assert {:error, :plan_not_immutable} = Core.admit_plan(%{plan | "entries" => [42]})
    assert {:error, :plan_not_immutable} = Core.admit_plan(%{plan | "retained_targets" => [42]})
    assert {:error, :plan_not_immutable} = Core.admit_plan(%{plan | "collision_groups" => [42]})
  end

  test "admit_plan rejects duplicate identities, lying counts, and incoherent rows" do
    {:ok, plan} = Core.project(fixture_files())
    [first | rest] = plan["entries"]

    assert {:error, :duplicate_source} =
             Core.admit_plan(%{plan | "entries" => [first, first | rest]})

    [ret | rrest] = plan["retained_targets"]

    assert {:error, :duplicate_retained} =
             Core.admit_plan(%{plan | "retained_targets" => [ret, ret | rrest]})

    [group | grest] = plan["collision_groups"]

    assert {:error, :duplicate_group} =
             Core.admit_plan(%{plan | "collision_groups" => [group, group | grest]})

    lying = put_in(plan, ["counts", "source_entries"], 640)
    assert {:error, :accepted_count_mismatch} = Core.admit_plan(lying)

    [exact | _] = Enum.filter(plan["entries"], &(&1["disposition"] == "exact_move"))
    bad_exact = %{exact | "collision_group" => exact["destination_path"]}
    replaced = Enum.map(plan["entries"], fn e -> if e == exact, do: bad_exact, else: e end)
    assert {:error, :plan_not_immutable} = Core.admit_plan(%{plan | "entries" => replaced})

    redirected = %{exact | "destination_path" => "apps/arbor_kernel_runtime/lib/redirected.ex"}

    redirected_plan =
      %{plan | "entries" => Enum.map(plan["entries"], &if(&1 == exact, do: redirected, else: &1))}
      |> redigest()

    assert {:error, :plan_not_immutable} = Core.admit_plan(redirected_plan)

    alternate_map =
      Map.merge(plan["split"]["source_map"], %{
        "arbor_common" => "arbor_other_runtime",
        "arbor_monitor" => "arbor_other_runtime",
        "arbor_signals" => "arbor_other_runtime"
      })

    alternate_split = %{
      "passive_owner" => "arbor_kernel",
      "active_owner" => "arbor_other_runtime",
      "source_map" => alternate_map
    }

    split_plan = redigest(%{plan | "split" => alternate_split})
    assert {:error, :plan_not_immutable} = Core.admit_plan(split_plan)

    duplicate_preexisting = %{
      group
      | "preexisting_paths" => [group["destination_path"], group["destination_path"]]
    }

    group_plan = redigest(%{plan | "collision_groups" => [duplicate_preexisting | grest]})
    assert {:error, :plan_not_immutable} = Core.admit_plan(group_plan)
  end

  test "bind_empty rewrites empty evidence and fails closed on malformed or non-empty" do
    digest = String.duplicate("c", 64)
    assert {:ok, empty} = Evidence.bind_empty(nil, digest)
    assert empty["entries"] == []
    assert empty["plan_digest"] == digest

    {:ok, empty_bytes} = Encode.encode_evidence(empty)
    assert {:ok, rebound} = Evidence.bind_empty(empty_bytes, digest)
    assert rebound["plan_digest"] == digest

    assert {:error, :evidence_malformed} = Evidence.bind_empty("{not-json", digest)
    assert {:error, :evidence_malformed} = Evidence.bind_empty("{}", digest)

    unknown_empty = Jason.encode!(Map.put(empty, "unknown", true))
    assert {:error, :evidence_malformed} = Evidence.bind_empty(unknown_empty, digest)

    missing_digest = Jason.encode!(Map.delete(empty, "plan_digest"))
    assert {:error, :evidence_malformed} = Evidence.bind_empty(missing_digest, digest)

    nonempty = %{
      "schema" => "arbor.packaging.kernel_materialization.transform_evidence.v1",
      "version" => 1,
      "plan_digest" => digest,
      "entries" => [evidence_row("apps/arbor_kernel/mix.exs", "transform", "x\n")]
    }

    {:ok, nonempty_bytes} = Encode.encode_evidence(nonempty)
    assert {:error, :evidence_not_empty} = Evidence.bind_empty(nonempty_bytes, digest)
  end

  test "evidence requires plan digest, mode, and OID; empty entries admit" do
    {:ok, plan} = Core.project(fixture_files())
    digest = plan["entries_digest"]

    assert {:ok, admitted} = Evidence.admit(Evidence.empty(digest), plan)
    assert admitted["entries"] == []

    assert {:error, :transform_evidence_unbound} =
             Evidence.admit(Map.put(Evidence.empty(digest), "unknown", true), plan)

    assert {:error, :transform_evidence_unbound} =
             Evidence.admit(%{Evidence.empty(digest) | "entries" => [42]}, plan)

    assert {:error, :missing_evidence_identity} =
             Evidence.admit(Map.delete(Evidence.empty(digest), "plan_digest"), plan)

    assert {:error, :evidence_digest_mismatch} =
             Evidence.admit(Evidence.empty(String.duplicate("b", 64)), plan)

    row = %{
      "destination_path" => "apps/arbor_kernel/mix.exs",
      "kind" => "transform",
      "mode" => "100644"
    }

    assert {:error, :missing_evidence_identity} =
             Evidence.admit(
               %{
                 "schema" => "arbor.packaging.kernel_materialization.transform_evidence.v1",
                 "version" => 1,
                 "plan_digest" => digest,
                 "entries" => [row]
               },
               plan
             )

    unknown_row =
      evidence_row("apps/arbor_kernel/mix.exs", "transform", "x\n")
      |> Map.put("unknown", true)

    assert {:error, :transform_evidence_unbound} =
             Evidence.admit(evidence_doc(digest, [unknown_row]), plan)

    generated_outside = evidence_row("apps/arbor_commands/lib/x.ex", "generated", "x\n")

    assert {:error, :transform_evidence_unbound} =
             Evidence.admit(evidence_doc(digest, [generated_outside]), plan)

    overlap = evidence_row("apps/arbor_kernel/lib/arbor/kernel.ex", "generated", "x\n")

    assert {:error, :evidence_path_overlap} =
             Evidence.admit(evidence_doc(digest, [overlap]), plan)

    empty_path = evidence_row("", "generated", "x\n")

    assert {:error, {:invalid_path, ""}} =
             Evidence.admit(evidence_doc(digest, [empty_path]), plan)

    transform = evidence_row("apps/arbor_kernel/mix.exs", "transform", "merged mix\n")
    generated = evidence_row("apps/arbor_kernel/priv/generated.ex", "generated", "gen\n")

    assert {:ok, with_rows} = Evidence.admit(evidence_doc(digest, [transform, generated]), plan)
    assert Enum.map(with_rows["entries"], & &1["kind"]) == ["transform", "generated"]
  end

  test "planned compare fail-closes on oid drift, missing source, and mixed phase" do
    files = fixture_files()
    {:ok, plan} = Core.project(files)
    {:ok, evidence} = Evidence.admit(Evidence.empty(plan["entries_digest"]), plan)

    drifted =
      Enum.map(files, fn file ->
        if file.path == "apps/arbor_contracts/lib/a.ex" do
          file("apps/arbor_contracts/lib/a.ex", "changed\n")
        else
          file
        end
      end)

    assert {:ok, report} =
             KernelMaterialization.run_for_test(
               mode: "check",
               phase: "planned",
               root: tmp_root(),
               plan_map: plan,
               evidence_map: evidence,
               inventory: drifted
             )

    assert report["status"] == "failed"
    assert Enum.any?(report["comparison"]["failures"], &(&1["reason"] == "source_oid_drift"))

    missing = Enum.reject(files, &(&1.path == "apps/arbor_contracts/lib/a.ex"))

    assert {:ok, missing_report} =
             KernelMaterialization.run_for_test(
               mode: "check",
               phase: "planned",
               root: tmp_root(),
               plan_map: plan,
               evidence_map: evidence,
               inventory: missing
             )

    assert Enum.any?(
             missing_report["comparison"]["failures"],
             &(&1["reason"] == "missing_source")
           )

    present = Enum.map(files, & &1.path) ++ ["apps/arbor_kernel/lib/a.ex"]

    assert {:ok, mixed} =
             KernelMaterialization.run_for_test(
               mode: "check",
               phase: "planned",
               root: tmp_root(),
               plan_map: plan,
               evidence_map: evidence,
               inventory: files,
               present_paths: present
             )

    assert Enum.any?(mixed["comparison"]["failures"], &(&1["reason"] == "mixed_phase"))
  end

  test "materialized compare fail-closes on source presence, dest drift, and empty evidence" do
    files = fixture_files()
    {:ok, plan} = Core.project(files)
    digest = plan["entries_digest"]
    {:ok, empty} = Evidence.admit(Evidence.empty(digest), plan)

    dest_files = materialized_dest_files(plan, files)

    presence_all = Map.new(Core.source_apps(), &{&1, true})

    assert {:ok, still_present} =
             KernelMaterialization.run_for_test(
               mode: "check",
               phase: "materialized",
               root: tmp_root(),
               plan_map: plan,
               evidence_map: empty,
               dest_files: dest_files,
               target_files: Map.values(dest_files),
               source_presence: presence_all
             )

    assert Enum.any?(still_present["comparison"]["failures"], &(&1["reason"] == "phase_mismatch"))

    presence_none = Map.new(Core.source_apps(), &{&1, false})

    assert {:ok, empty_ev} =
             KernelMaterialization.run_for_test(
               mode: "check",
               phase: "materialized",
               root: tmp_root(),
               plan_map: plan,
               evidence_map: empty,
               dest_files: dest_files,
               target_files: Map.values(dest_files),
               source_presence: presence_none
             )

    assert Enum.any?(
             empty_ev["comparison"]["failures"],
             &(&1["reason"] == "missing_transform_evidence")
           )

    transform_rows =
      Enum.map(plan["collision_groups"], fn group ->
        dest = group["destination_path"]
        evidence_row(dest, "transform", "merged #{dest}\n")
      end)

    {:ok, ev} = Evidence.admit(evidence_doc(digest, transform_rows), plan)

    dest_files = materialized_dest_files(plan, files, ev)

    retained = Enum.find(plan["retained_targets"], &(&1["disposition"] == "retain"))
    drifted_bytes = "nope\n"

    drifted_retain = %{
      dest_files[retained["path"]]
      | blob_oid: Encode.git_blob_oid(drifted_bytes, "sha1"),
        byte_size: byte_size(drifted_bytes),
        bytes: drifted_bytes
    }

    dest_files = Map.put(dest_files, retained["path"], drifted_retain)

    assert {:ok, retain_drift} =
             KernelMaterialization.run_for_test(
               mode: "check",
               phase: "materialized",
               root: tmp_root(),
               plan_map: plan,
               evidence_map: ev,
               dest_files: dest_files,
               target_files: Map.values(dest_files),
               source_presence: presence_none
             )

    assert Enum.any?(
             retain_drift["comparison"]["failures"],
             &(&1["reason"] == "retained_oid_drift")
           )

    unexplained = file("apps/arbor_kernel/lib/extra.ex", "extra\n")

    assert {:ok, extra} =
             KernelMaterialization.run_for_test(
               mode: "check",
               phase: "materialized",
               root: tmp_root(),
               plan_map: plan,
               evidence_map: ev,
               dest_files: materialized_dest_files(plan, files, ev),
               target_files:
                 Map.values(materialized_dest_files(plan, files, ev)) ++ [unexplained],
               source_presence: presence_none
             )

    assert Enum.any?(
             extra["comparison"]["failures"],
             &(&1["reason"] == "unexplained_destination")
           )
  end

  test "load_selected_blobs isolates unselected symlink/gitlink and rejects selected symlink" do
    oid = Encode.git_blob_oid("mix\n", "sha1")

    staged = """
    120000 #{oid} 0\tdocs/link
    160000 #{oid} 0\tdeps/some_gitlink
    100644 #{oid} 0\tapps/arbor_contracts/mix.exs
    100644 #{oid} 0\tapps/arbor_integrations/lib/x.ex
    """

    run_git = fn _root, args, stdin ->
      cond do
        args == ["ls-files", "-z", "--stage"] ->
          {:ok, nul_join(staged)}

        args == ["cat-file", "--batch-check"] ->
          {:ok, batch_check_output(stdin, 4)}

        args == ["cat-file", "--batch"] ->
          {:ok, batch_payload_output(stdin, "mix\n")}

        true ->
          flunk("unexpected git args: #{inspect(args)}")
      end
    end

    assert {:ok, %{files: files}} =
             GitInventory.load_selected_blobs("/tmp", ["arbor_contracts"], run_git: run_git)

    assert Enum.map(files, & &1.path) == ["apps/arbor_contracts/mix.exs"]

    selected_symlink = "120000 #{oid} 0\tapps/arbor_contracts/lib/x.ex\n"

    run_symlink = fn _root, args, _stdin ->
      cond do
        args == ["ls-files", "-z", "--stage"] -> {:ok, nul_join(selected_symlink)}
        true -> flunk("git must not fetch blobs for a selected symlink")
      end
    end

    assert {:error, {:unsupported_selected_mode, "120000", "apps/arbor_contracts/lib/x.ex"}} =
             GitInventory.load_selected_blobs("/tmp", ["arbor_contracts"], run_git: run_symlink)
  end

  test "load_selected_blobs rejects malformed selected index input" do
    run_git = fn _root, args, _stdin ->
      cond do
        args == ["ls-files", "-z", "--stage"] -> {:ok, nul_join("not-a-stage-line\n")}
        true -> flunk("unexpected #{inspect(args)}")
      end
    end

    assert {:error, {:malformed_stage_line, "not-a-stage-line"}} =
             GitInventory.load_selected_blobs("/tmp", ["arbor_contracts"], run_git: run_git)
  end

  test "query_indexed_blobs_batched chunks, merges, and rejects duplicates or oversize" do
    assert GitInventory.destination_query_batch() == 64

    paths = Enum.map(1..65, &"apps/arbor_kernel/lib/f#{&1}.ex")

    assert {:error, :duplicate_paths} =
             GitInventory.query_indexed_blobs_batched("/tmp", ["a", "a"])

    oid = Encode.git_blob_oid("x\n", "sha1")

    run_git = fn _root, args, stdin ->
      cond do
        match?(["--literal-pathspecs", "ls-files", "-z", "--stage", "--" | _], args) ->
          requested = Enum.drop(args, 5)

          out =
            requested
            |> Enum.map(&"100644 #{oid} 0\t#{&1}")
            |> Enum.join("\0")

          {:ok, out}

        args == ["cat-file", "--batch-check"] ->
          count = stdin |> String.split("\n", trim: true) |> length()
          {:ok, batch_check_output(stdin, 2, count)}

        args == ["cat-file", "--batch"] ->
          {:ok, batch_payload_output(stdin, "x\n")}

        true ->
          flunk("unexpected #{inspect(args)}")
      end
    end

    assert {:ok, %{present: present, absent: []}} =
             GitInventory.query_indexed_blobs_batched("/tmp", paths, run_git: run_git)

    assert length(present) == 65
    assert Enum.map(present, & &1.path) == Enum.sort(paths)

    huge = fn _root, args, _stdin ->
      cond do
        match?(["--literal-pathspecs", "ls-files", "-z", "--stage", "--" | _], args) ->
          {:ok, "100644 #{oid} 0\tapps/arbor_kernel/lib/f1.ex"}

        args == ["cat-file", "--batch-check"] ->
          {:ok, "#{oid} blob 2000000\n"}

        true ->
          flunk("oversize must fail at batch-check: #{inspect(args)}")
      end
    end

    assert {:error, {:blob_too_large, "apps/arbor_kernel/lib/f1.ex", 2_000_000}} =
             GitInventory.query_indexed_blobs_batched(
               "/tmp",
               ["apps/arbor_kernel/lib/f1.ex"],
               run_git: huge
             )
  end

  defp fixture_files, do: KernelMaterializationFixtures.fixture_files()

  defp production_stub_plan do
    dests = Core.production_policy()["collision_destination_paths"]

    %{
      "counts" => %{
        "source_entries" => 640,
        "exact_moves" => 610,
        "transform_inputs" => 30,
        "collision_destinations" => 4,
        "retained_targets" => 3
      },
      "base_commit" => Core.production_policy()["base_commit"],
      "policy_version" => Core.production_policy()["policy_version"],
      "collision_groups" => Enum.map(dests, &%{"destination_path" => &1}),
      "retained_targets" => Core.production_policy()["kernel_identity"]
    }
  end

  defp file(path, bytes, opts \\ []) do
    KernelMaterializationFixtures.file(path, bytes, opts)
  end

  defp redigest(plan), do: Map.put(plan, "entries_digest", Encode.plan_digest(plan))

  defp evidence_row(dest, kind, bytes) do
    %{
      "destination_path" => dest,
      "kind" => kind,
      "mode" => "100644",
      "oid" => Encode.git_blob_oid(bytes, "sha1")
    }
  end

  defp evidence_doc(digest, entries) do
    %{
      "schema" => "arbor.packaging.kernel_materialization.transform_evidence.v1",
      "version" => 1,
      "plan_digest" => digest,
      "entries" => entries
    }
  end

  defp materialized_dest_files(plan, source_files, evidence \\ %{"entries" => []}) do
    by_source = Map.new(source_files, &{&1.path, &1})

    exact =
      plan["entries"]
      |> Enum.filter(&(&1["disposition"] == "exact_move"))
      |> Map.new(fn entry ->
        src = by_source[entry["source_path"]]
        {entry["destination_path"], %{src | path: entry["destination_path"]}}
      end)

    retain =
      plan["retained_targets"]
      |> Enum.filter(&(&1["disposition"] == "retain"))
      |> Map.new(fn entry ->
        src = by_source[entry["path"]]
        {entry["path"], src}
      end)

    ev =
      Map.new(evidence["entries"] || [], fn row ->
        bytes = "merged #{row["destination_path"]}\n"

        {row["destination_path"],
         %{
           path: row["destination_path"],
           mode: row["mode"],
           blob_oid: row["oid"],
           byte_size: byte_size(bytes),
           bytes: bytes
         }}
      end)

    Map.merge(exact, Map.merge(retain, ev))
  end

  defp tmp_root, do: KernelMaterializationFixtures.tmp_root()

  defp nul_join(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.join("\0")
  end

  defp batch_check_output(stdin, size, count \\ nil) do
    oids = String.split(stdin, "\n", trim: true)
    oids = if is_integer(count), do: Enum.take(oids, count), else: oids

    oids
    |> Enum.map(&"#{&1} blob #{size}")
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp batch_payload_output(stdin, payload) do
    stdin
    |> String.split("\n", trim: true)
    |> Enum.map(&"#{&1} blob #{byte_size(payload)}\n#{payload}\n")
    |> Enum.join()
  end
end
