defmodule Arbor.Orchestrator.CodingPlan.ArtifactStoreTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Arbor.Contracts.Coding.{TaskTerminalEnvelope, ValidationCapacityHandoff}
  alias Arbor.Orchestrator.CodingPlan.{ArtifactStore, OutcomeMapper, ValidationCapacityTerminal}

  @compilation_seal_filename ".coding-compilation-seal.json"
  @compilation_publication_barrier_key {ArtifactStore, :compilation_publication_barrier}
  @verification_tree_oid String.duplicate("a", 40)
  @verification_observed_at "2026-07-22T12:00:00.000Z"

  setup do
    base =
      Path.join(
        System.tmp_dir!(),
        "coding_plan_artifact_store_#{System.unique_integer([:positive])}"
      )

    root = Path.join([base, "nested", "task-root"])
    on_exit(fn -> File.rm_rf(base) end)

    %{base: base, root: root}
  end

  test "archives exact DOT bytes and JSON-clean plan and manifest", %{root: root} do
    plan = plan_fixture()
    dot_source = "digraph coding {\n  start -> done;\n}\n"
    manifest = manifest_for(dot_source)

    assert {:ok, descriptor} = ArtifactStore.archive(root, plan, dot_source, manifest)

    expanded_root = Path.expand(root)

    assert descriptor == %{
             "coding_plan_path" => Path.join(expanded_root, "coding-plan.json"),
             "coding_pipeline_path" => Path.join(expanded_root, "coding-pipeline.dot"),
             "compile_manifest_path" => Path.join(expanded_root, "coding-compile-manifest.json"),
             "graph_hash" => manifest["graph_hash"],
             "compiler_version" => manifest["compiler_version"]
           }

    assert File.read!(descriptor["coding_pipeline_path"]) == dot_source
    assert Jason.decode!(File.read!(descriptor["coding_plan_path"])) == plan
    assert Jason.decode!(File.read!(descriptor["compile_manifest_path"])) == manifest
    assert {:ok, _encoded_descriptor} = Jason.encode(descriptor)

    assert Enum.sort(File.ls!(expanded_root)) == [
             @compilation_seal_filename,
             "coding-compile-manifest.json",
             "coding-pipeline.dot",
             "coding-plan.json"
           ]
  end

  test "creates mode-0600 files", %{root: root} do
    dot_source = "digraph G {}"

    assert {:ok, descriptor} =
             ArtifactStore.archive(root, plan_fixture(), dot_source, manifest_for(dot_source))

    paths = [
      descriptor["coding_plan_path"],
      descriptor["coding_pipeline_path"],
      descriptor["compile_manifest_path"],
      compilation_seal_path(root)
    ]

    for path <- paths do
      assert {:ok, stat} = File.lstat(path)
      assert stat.type == :regular
      assert (stat.mode &&& 0o777) == 0o600
    end
  end

  test "security regression: nonempty temporary artifacts are already mode 0600", %{
    root: root
  } do
    parent = self()
    dot_source = :binary.copy("x", 4_096)
    stage = {:before_compilation_artifact_link, "coding-pipeline.dot"}

    archive_task =
      Task.async(fn ->
        Process.put(@compilation_publication_barrier_key, {parent, stage})
        ArtifactStore.archive(root, plan_fixture(), dot_source, manifest_for(dot_source))
      end)

    assert_receive {:artifact_store_compilation_barrier, archive_pid, ^stage}, 1_000

    assert [%{mode: 0o600, size: size}] = temporary_file_observations(root)
    assert size == byte_size(dot_source)

    send(archive_pid, {:artifact_store_compilation_continue, stage})
    assert {:ok, _descriptor} = Task.await(archive_task, 5_000)
  end

  test "same-content replay is idempotent and repairs fixed artifact modes", %{root: root} do
    plan = plan_fixture()
    dot_source = "digraph G { start -> validate -> done }"
    manifest = manifest_for(dot_source)

    assert {:ok, first_descriptor} =
             ArtifactStore.archive(root, plan, dot_source, manifest)

    first_bytes = read_artifacts(first_descriptor)

    for {_name, path} <- artifact_paths(first_descriptor) do
      File.chmod!(path, 0o644)
    end

    assert {:ok, second_descriptor} =
             ArtifactStore.archive(root, plan, dot_source, manifest)

    assert second_descriptor == first_descriptor
    assert read_artifacts(second_descriptor) == first_bytes

    for {_name, path} <- artifact_paths(second_descriptor) do
      assert {:ok, stat} = File.stat(path)
      assert (stat.mode &&& 0o777) == 0o600
    end

    refute Enum.any?(File.ls!(root), &String.contains?(&1, ".tmp-"))
  end

  test "security regression: sealed compilation rejects conflicting replay", %{root: root} do
    plan = plan_fixture()
    dot_source = "digraph G { start -> validate -> done }"
    manifest = manifest_for(dot_source)

    assert {:ok, descriptor} = ArtifactStore.archive(root, plan, dot_source, manifest)
    original = read_artifacts(descriptor)

    assert {:error, :compilation_seal_conflict} =
             ArtifactStore.archive(
               root,
               Map.put(plan, "task", "caller-selected replacement"),
               dot_source,
               manifest
             )

    assert read_artifacts(descriptor) == original
  end

  test "security regression: concurrent different writers produce one immutable bundle", %{
    base: base
  } do
    task_id = "task_concurrent_compilation_writers"
    root = compilation_task_root(base, task_id)
    parent = self()
    stage = :before_compilation_seal_link

    candidates = [
      compilation_candidate("first writer", "digraph G { start -> first -> done }"),
      compilation_candidate("second writer", "digraph G { start -> second -> done }")
    ]

    tasks =
      Enum.map(candidates, fn candidate ->
        Task.async(fn ->
          Process.put(@compilation_publication_barrier_key, {parent, stage})
          send(parent, {:compilation_writer_ready, self()})

          receive do
            :start_compilation_writer -> :ok
          end

          {candidate,
           ArtifactStore.archive(
             root,
             candidate.plan,
             candidate.dot_source,
             candidate.manifest
           )}
        end)
      end)

    Enum.each(tasks, fn task ->
      assert_receive {:compilation_writer_ready, writer_pid} when writer_pid == task.pid, 1_000
    end)

    Enum.each(tasks, &send(&1.pid, :start_compilation_writer))

    Enum.each(tasks, fn task ->
      assert_receive {:artifact_store_compilation_barrier, writer_pid, ^stage}
                     when writer_pid == task.pid,
                     1_000
    end)

    Enum.each(tasks, &send(&1.pid, {:artifact_store_compilation_continue, stage}))

    results = Enum.map(tasks, &Task.await(&1, 5_000))

    assert [{winner, {:ok, _descriptor}}] =
             Enum.filter(results, fn {_candidate, result} ->
               match?({:ok, _descriptor}, result)
             end)

    assert [{loser, {:error, :compilation_seal_conflict}}] =
             Enum.reject(results, fn {_candidate, result} ->
               match?({:ok, _descriptor}, result)
             end)

    assert {:ok, compilation} = ArtifactStore.read_task_compilation(base, task_id)
    assert compilation["plan"] == winner.plan
    assert compilation["dot_source"] == winner.dot_source
    assert compilation["manifest"] == winner.manifest

    assert {:error, :compilation_seal_conflict} =
             ArtifactStore.archive(root, loser.plan, loser.dot_source, loser.manifest)
  end

  test "security regression: deleted artifact rejects conflict and permits same-content repair",
       %{
         base: base
       } do
    task_id = "task_deleted_compilation_artifact"
    root = compilation_task_root(base, task_id)
    original = compilation_candidate("original", "digraph G { start -> original -> done }")
    conflicting = compilation_candidate("conflicting", "digraph G { start -> conflict -> done }")

    assert {:ok, descriptor} =
             ArtifactStore.archive(root, original.plan, original.dot_source, original.manifest)

    pipeline_path = descriptor["coding_pipeline_path"]
    File.rm!(pipeline_path)

    assert {:error, :compilation_seal_conflict} =
             ArtifactStore.archive(
               root,
               conflicting.plan,
               conflicting.dot_source,
               conflicting.manifest
             )

    refute File.exists?(pipeline_path)

    assert {:ok, ^descriptor} =
             ArtifactStore.archive(root, original.plan, original.dot_source, original.manifest)

    assert File.read!(pipeline_path) == original.dot_source
    assert {:ok, _compilation} = ArtifactStore.read_task_compilation(base, task_id)
  end

  test "security regression: seal-first crash rejects conflict and same replay recovers", %{
    base: base
  } do
    task_id = "task_seal_first_crash"
    root = compilation_task_root(base, task_id)
    original = compilation_candidate("original", "digraph G { start -> sealed -> done }")
    conflicting = compilation_candidate("conflicting", "digraph G { start -> other -> done }")
    parent = self()
    stage = :after_compilation_seal_link

    archive_task =
      Task.async(fn ->
        Process.put(@compilation_publication_barrier_key, {parent, stage})
        ArtifactStore.archive(root, original.plan, original.dot_source, original.manifest)
      end)

    assert_receive {:artifact_store_compilation_barrier, archive_pid, ^stage}, 1_000
    assert File.exists?(compilation_seal_path(root))
    refute Enum.any?(descriptor_artifact_paths(root), &File.exists?/1)

    assert {:error, :compilation_seal_conflict} =
             ArtifactStore.archive(
               root,
               conflicting.plan,
               conflicting.dot_source,
               conflicting.manifest
             )

    assert Task.shutdown(archive_task, :brutal_kill) == nil

    assert {:ok, _descriptor} =
             ArtifactStore.archive(root, original.plan, original.dot_source, original.manifest)

    assert {:ok, _compilation} = ArtifactStore.read_task_compilation(base, task_id)
    refute Process.alive?(archive_pid)
  end

  test "security regression: partial sealed publication is completed by same replay", %{
    base: base
  } do
    task_id = "task_partial_compilation_publication"
    root = compilation_task_root(base, task_id)
    original = compilation_candidate("original", "digraph G { start -> partial -> done }")
    conflicting = compilation_candidate("conflicting", "digraph G { start -> other -> done }")
    parent = self()
    stage = {:after_compilation_artifact_link, "coding-plan.json"}

    archive_task =
      Task.async(fn ->
        Process.put(@compilation_publication_barrier_key, {parent, stage})
        ArtifactStore.archive(root, original.plan, original.dot_source, original.manifest)
      end)

    assert_receive {:artifact_store_compilation_barrier, archive_pid, ^stage}, 1_000
    assert File.exists?(compilation_seal_path(root))
    assert File.exists?(Path.join(root, "coding-plan.json"))
    refute File.exists?(Path.join(root, "coding-pipeline.dot"))
    refute File.exists?(Path.join(root, "coding-compile-manifest.json"))

    assert {:error, :compilation_seal_conflict} =
             ArtifactStore.archive(
               root,
               conflicting.plan,
               conflicting.dot_source,
               conflicting.manifest
             )

    assert Task.shutdown(archive_task, :brutal_kill) == nil

    assert {:ok, _descriptor} =
             ArtifactStore.archive(root, original.plan, original.dot_source, original.manifest)

    assert {:ok, _compilation} = ArtifactStore.read_task_compilation(base, task_id)
    refute Process.alive?(archive_pid)
  end

  test "upgrades matching pre-seal archives but never seals over an existing conflict", %{
    root: root
  } do
    candidate = compilation_candidate("legacy archive", "digraph G { start -> legacy -> done }")
    source_root = root <> "-source"

    assert {:ok, source_descriptor} =
             ArtifactStore.archive(
               source_root,
               candidate.plan,
               candidate.dot_source,
               candidate.manifest
             )

    File.rm!(compilation_seal_path(source_root))

    assert {:ok, ^source_descriptor} =
             ArtifactStore.archive(
               source_root,
               candidate.plan,
               candidate.dot_source,
               candidate.manifest
             )

    partial_root = root <> "-partial"
    File.mkdir_p!(partial_root)
    copy_compilation_artifact!(source_descriptor["coding_plan_path"], partial_root)

    assert {:ok, partial_descriptor} =
             ArtifactStore.archive(
               partial_root,
               candidate.plan,
               candidate.dot_source,
               candidate.manifest
             )

    assert Enum.all?(artifact_paths(partial_descriptor), fn {_name, path} ->
             File.exists?(path)
           end)

    assert File.exists?(compilation_seal_path(partial_root))

    conflicting_root = root <> "-conflicting"
    File.mkdir_p!(conflicting_root)
    File.write!(Path.join(conflicting_root, "coding-plan.json"), "existing conflicting bytes")
    File.chmod!(Path.join(conflicting_root, "coding-plan.json"), 0o600)

    assert {:error, {:compilation_artifact_conflict, "coding-plan.json"}} =
             ArtifactStore.archive(
               conflicting_root,
               candidate.plan,
               candidate.dot_source,
               candidate.manifest
             )

    refute File.exists?(compilation_seal_path(conflicting_root))
  end

  test "graph mismatch is rejected before sealing and a corrected bundle remains readable", %{
    base: base
  } do
    task_id = "task_read_sealed_compilation"
    root = compilation_task_root(base, task_id)
    candidate = compilation_candidate("read sealed", "digraph G { start -> read -> done }")

    assert {:ok, _descriptor} =
             ArtifactStore.archive(root, candidate.plan, candidate.dot_source, candidate.manifest)

    assert {:ok, compilation} = ArtifactStore.read_task_compilation(base, task_id)

    assert compilation == %{
             "task_id" => task_id,
             "plan" => candidate.plan,
             "dot_source" => candidate.dot_source,
             "manifest" => candidate.manifest,
             "plan_sha256" => sha256(Jason.encode!(candidate.plan, pretty: true)),
             "pipeline_sha256" => sha256(candidate.dot_source),
             "manifest_sha256" => sha256(Jason.encode!(candidate.manifest, pretty: true))
           }

    bad_task_id = "task_bad_compilation_graph_hash"
    bad_root = compilation_task_root(base, bad_task_id)

    assert {:error, :compilation_graph_hash_mismatch} =
             ArtifactStore.archive(
               bad_root,
               candidate.plan,
               candidate.dot_source,
               manifest_fixture()
             )

    refute File.exists?(bad_root)

    assert {:ok, _descriptor} =
             ArtifactStore.archive(
               bad_root,
               candidate.plan,
               candidate.dot_source,
               candidate.manifest
             )

    assert {:ok, _compilation} = ArtifactStore.read_task_compilation(base, bad_task_id)
  end

  test "security regression: reader rejects a missing or tampered compilation seal", %{base: base} do
    task_id = "task_missing_or_tampered_seal"
    root = compilation_task_root(base, task_id)
    candidate = compilation_candidate("sealed reader", "digraph G { start -> seal -> done }")

    assert {:ok, _descriptor} =
             ArtifactStore.archive(root, candidate.plan, candidate.dot_source, candidate.manifest)

    seal_path = compilation_seal_path(root)
    File.rm!(seal_path)

    assert {:error, :coding_compilation_provenance_unavailable} =
             ArtifactStore.read_task_compilation(base, task_id)

    assert {:ok, _descriptor} =
             ArtifactStore.archive(root, candidate.plan, candidate.dot_source, candidate.manifest)

    File.write!(seal_path, "{}")
    File.chmod!(seal_path, 0o600)

    assert {:error, :coding_compilation_provenance_unavailable} =
             ArtifactStore.read_task_compilation(base, task_id)

    assert {:error, :compilation_seal_conflict} =
             ArtifactStore.archive(root, candidate.plan, candidate.dot_source, candidate.manifest)
  end

  test "reader rejects insecure and indirect sealed compilation files", %{base: base} do
    task_id = "task_invalid_sealed_compilation_file"
    root = compilation_task_root(base, task_id)
    candidate = compilation_candidate("fixed files", "digraph G { start -> fixed -> done }")

    assert {:ok, descriptor} =
             ArtifactStore.archive(root, candidate.plan, candidate.dot_source, candidate.manifest)

    plan_path = descriptor["coding_plan_path"]
    File.chmod!(plan_path, 0o644)

    assert {:error, :coding_compilation_provenance_unavailable} =
             ArtifactStore.read_task_compilation(base, task_id)

    File.chmod!(plan_path, 0o600)
    outside = Path.join(base, "outside-coding-plan.json")
    File.write!(outside, File.read!(plan_path))
    File.chmod!(outside, 0o600)
    File.rm!(plan_path)
    File.ln_s!(outside, plan_path)

    assert {:error, :coding_compilation_provenance_unavailable} =
             ArtifactStore.read_task_compilation(base, task_id)
  end

  test "oversized compilation is rejected before sealing and a corrected bundle remains readable",
       %{base: base} do
    task_id = "task_oversized_sealed_compilation"
    root = compilation_task_root(base, task_id)
    oversized_dot = :binary.copy("x", 4_194_305)

    corrected =
      compilation_candidate("corrected size", "digraph G { start -> corrected -> done }")

    assert {:error, {:compilation_artifact_size_out_of_bounds, "coding-pipeline.dot"}} =
             ArtifactStore.archive(
               root,
               corrected.plan,
               oversized_dot,
               manifest_for(oversized_dot)
             )

    refute File.exists?(root)

    assert {:ok, _descriptor} =
             ArtifactStore.archive(
               root,
               corrected.plan,
               corrected.dot_source,
               corrected.manifest
             )

    assert {:ok, compilation} = ArtifactStore.read_task_compilation(base, task_id)
    assert compilation["dot_source"] == corrected.dot_source
  end

  test "rejects malformed arguments with tagged errors before creating files", %{root: root} do
    manifest = manifest_fixture()

    assert {:error, {:invalid_root, :expected_string}} =
             ArtifactStore.archive(nil, plan_fixture(), "digraph G {}", manifest)

    assert {:error, {:invalid_root, :empty}} =
             ArtifactStore.archive("  ", plan_fixture(), "digraph G {}", manifest)

    assert {:error, {:invalid_plan, :expected_string_keyed_map}} =
             ArtifactStore.archive(root, [], "digraph G {}", manifest)

    assert {:error, {:invalid_plan, {:non_string_key, []}}} =
             ArtifactStore.archive(root, %{version: 1}, "digraph G {}", manifest)

    assert {:error, {:invalid_plan, {:non_json_value, ["worker", "pid"]}}} =
             ArtifactStore.archive(
               root,
               %{"worker" => %{"pid" => self()}},
               "digraph G {}",
               manifest
             )

    assert {:error, {:invalid_dot_source, :expected_non_empty_binary}} =
             ArtifactStore.archive(root, plan_fixture(), "", manifest)

    assert {:error, {:invalid_manifest, {:non_string_key, []}}} =
             ArtifactStore.archive(
               root,
               plan_fixture(),
               "digraph G {}",
               %{graph_hash: "abc", compiler_version: "v1"}
             )

    assert {:error, {:invalid_manifest_field, "graph_hash"}} =
             ArtifactStore.archive(
               root,
               plan_fixture(),
               "digraph G {}",
               %{"compiler_version" => "v1"}
             )

    assert {:error, {:invalid_manifest_field, "compiler_version"}} =
             ArtifactStore.archive(
               root,
               plan_fixture(),
               "digraph G {}",
               %{"graph_hash" => "abc", "compiler_version" => " "}
             )

    refute File.exists?(root)
  end

  test "returns a tagged filesystem error when the root is not a directory", %{
    base: base
  } do
    root_file = Path.join(base, "not-a-directory")
    File.mkdir_p!(base)
    File.write!(root_file, "occupied")

    assert {:error, {:create_artifact_root_failed, reason}} =
             ArtifactStore.archive(
               root_file,
               plan_fixture(),
               "digraph G {}",
               manifest_for("digraph G {}")
             )

    assert reason in [:eexist, :enotdir]
  end

  test "rejects a non-regular fixed artifact without leaving a temporary file", %{root: root} do
    destination = Path.join(root, "coding-plan.json")
    File.mkdir_p!(destination)

    assert {:error, {:invalid_compilation_artifact, "coding-plan.json"}} =
             ArtifactStore.archive(
               root,
               plan_fixture(),
               "digraph G {}",
               manifest_for("digraph G {}")
             )

    refute Enum.any?(File.ls!(root), &String.contains?(&1, ".tmp-"))
    refute File.exists?(compilation_seal_path(root))
  end

  test "archives closed terminal evidence with digest, size, and restrictive mode", %{root: root} do
    File.mkdir_p!(root)
    {:ok, root} = Arbor.Common.SafePath.resolve_real(root)
    result = terminal_result(root)
    controls = [terminal_control()]

    assert {:ok, descriptor} =
             ArtifactStore.archive_terminal_evidence(root, "task_coding_1", result, controls)

    {:ok, canonical_root} = Arbor.Common.SafePath.resolve_real(root)
    evidence_path = Path.join(canonical_root, "coding-terminal-evidence.json")
    bytes = File.read!(evidence_path)

    assert descriptor == %{
             "path" => evidence_path,
             "sha256" => Base.encode16(:crypto.hash(:sha256, bytes), case: :lower),
             "byte_size" => byte_size(bytes),
             "schema_version" => 1,
             "task_id" => "task_coding_1"
           }

    assert {:ok, stat} = File.stat(evidence_path)
    assert (stat.mode &&& 0o777) == 0o600

    assert Jason.decode!(bytes) == %{
             "schema_version" => 1,
             "task_id" => "task_coding_1",
             "terminal_status" => "change_committed",
             "canonical_status" => "change_committed",
             "outcome" => %{
               "version" => 1,
               "disposition" => "succeeded",
               "code" => "change_committed",
               "phase" => "commit",
               "origin" => "arbor",
               "retry" => "none"
             },
             "compiled_workflow" => %{
               "coding_plan_path" => Path.join(canonical_root, "coding-plan.json"),
               "coding_pipeline_path" => Path.join(canonical_root, "coding-pipeline.dot"),
               "compile_manifest_path" =>
                 Path.join(canonical_root, "coding-compile-manifest.json"),
               "graph_hash" => String.duplicate("a", 64),
               "compiler_version" => "coding-plan-1"
             },
             "steering_history" => controls,
             "validation_outputs" => [%{"command" => "mix test", "passed" => true}],
             "review_verdict" => %{
               "recommendation" => "approve",
               "reviewer_outcomes" => %{
                 "security" => %{
                   "status" => "failed",
                   "reason_code" => "branch_failed",
                   "provider" => "openai_oauth",
                   "model" => "gpt-5.6-sol",
                   "effective_vote" => "abstain"
                 }
               },
               "tier_decision" => "allow",
               "human_required" => false,
               "security_veto" => false,
               "blast_radius" => "low"
             }
           }

    assert Enum.sort(File.ls!(root)) == [
             "coding-terminal-evidence.json"
           ]
  end

  test "persists verification reports, rejects forged status pairs, and accepts legacy v1", %{
    root: root
  } do
    File.mkdir_p!(root)
    report = verification_report()
    result = Map.put(terminal_result(root), "verification_report", report)

    assert {:ok, descriptor} =
             ArtifactStore.archive_terminal_evidence(root, "task_verified", result, [])

    evidence = descriptor["path"] |> File.read!() |> Jason.decode!()
    assert evidence["schema_version"] == 1
    assert evidence["verification_report"] == report

    {:ok, rework_outcome} =
      OutcomeMapper.map_terminal("rework_exhausted", %{
        "worker_msg" => %{"delivery_status" => "delivered", "stop_reason" => "end_turn"}
      })

    compatible_rework =
      result
      |> Map.put("status", "validation_failed")
      |> Map.put("canonical_status", "rework_exhausted")
      |> Map.put("outcome", rework_outcome)
      |> Map.put("verification_report", verification_report("blocked"))

    assert {:ok, _descriptor} =
             ArtifactStore.archive_terminal_evidence(
               root,
               "task_rework_validation",
               compatible_rework,
               []
             )

    forged = Map.put(result, "verification_report", verification_report("blocked"))

    assert {:error, {:invalid_terminal_result, :verification_status_mismatch}} =
             ArtifactStore.archive_terminal_evidence(root, "task_forged", forged, [])

    malformed = Map.put(result, "verification_report", Map.put(report, "authority", "secret"))

    assert {:error, {:invalid_terminal_field, "verification_report"}} =
             ArtifactStore.archive_terminal_evidence(root, "task_malformed", malformed, [])

    legacy = terminal_result(root)

    assert {:ok, legacy_descriptor} =
             ArtifactStore.archive_terminal_evidence(root, "task_legacy_v1", legacy, [])

    legacy_evidence = legacy_descriptor["path"] |> File.read!() |> Jason.decode!()
    assert legacy_evidence["schema_version"] == 1
    refute Map.has_key?(legacy_evidence, "verification_report")
  end

  test "security regression: verification reports match candidate validation terminals", %{
    root: root
  } do
    File.mkdir_p!(root)

    validation_failed =
      terminal_result_for(
        root,
        "validation_failed",
        "validation_failed",
        terminal_outcome("validation_failed", "failed", "validation", "validator", "same_session")
      )

    for report_status <- ~w(failed blocked) do
      assert {:ok, _descriptor} =
               archive_verification_case(
                 root,
                 :validation_failed,
                 validation_failed,
                 report_status
               )
    end

    assert_verification_mismatch(
      archive_verification_case(root, :validation_failed, validation_failed, "passed")
    )

    legacy_validation_failure =
      terminal_result_for(
        root,
        "validation_failed",
        "rework_exhausted",
        terminal_outcome("rework_exhausted", "failed", "review", "runtime", "new_session")
      )

    for report_status <- ~w(failed blocked) do
      assert {:ok, _descriptor} =
               archive_verification_case(
                 root,
                 :legacy_validation_failure,
                 legacy_validation_failure,
                 report_status
               )
    end

    assert_verification_mismatch(
      archive_verification_case(
        root,
        :legacy_validation_failure,
        legacy_validation_failure,
        "passed"
      )
    )

    mismatched_validation_failure =
      terminal_result_for(
        root,
        "validation_failed",
        "approval_denied",
        terminal_outcome("approval_denied", "rejected", "commit", "operator", "none")
      )

    assert_verification_mismatch(
      archive_verification_case(
        root,
        :mismatched_validation_failure,
        mismatched_validation_failure,
        "failed"
      )
    )

    capacity =
      terminal_result_for(
        root,
        "validation_capacity_exceeded",
        "validation_capacity_exceeded",
        terminal_outcome(
          "validation_capacity_exceeded",
          "requires_input",
          "validation",
          "validator",
          "after_external_change"
        )
      )
      |> Map.put("validation", capacity_validation())

    assert {:ok, _descriptor} =
             archive_verification_case(root, :validation_capacity, capacity, "blocked")

    for report_status <- ~w(passed failed) do
      assert_verification_mismatch(
        archive_verification_case(root, :validation_capacity, capacity, report_status)
      )
    end

    non_validation_terminals = [
      approval_denied:
        terminal_result_for(
          root,
          "approval_denied",
          "approval_denied",
          terminal_outcome("approval_denied", "rejected", "commit", "operator", "none")
        ),
      review_rejected:
        terminal_result_for(
          root,
          "review_rejected",
          "review_rejected",
          terminal_outcome("review_rejected", "rejected", "review", "reviewer", "none")
        ),
      human_review_required:
        terminal_result_for(
          root,
          "human_review_required",
          "human_review_required",
          terminal_outcome(
            "human_review_required",
            "requires_input",
            "review",
            "reviewer",
            "none"
          )
        ),
      review_rework_exhausted:
        terminal_result_for(
          root,
          "review_requires_rework",
          "rework_exhausted",
          terminal_outcome("rework_exhausted", "failed", "review", "runtime", "new_session")
        ),
      operator_rework_exhausted:
        terminal_result_for(
          root,
          "rework_exhausted",
          "rework_exhausted",
          terminal_outcome("rework_exhausted", "failed", "review", "runtime", "new_session")
        )
        |> Map.put("error", "operator_approval_rework_exhausted")
    ]

    for {name, result} <- non_validation_terminals do
      assert {:ok, _descriptor} =
               archive_verification_case(root, name, result, "passed")

      for report_status <- ~w(failed blocked) do
        assert_verification_mismatch(archive_verification_case(root, name, result, report_status))
      end
    end

    cancelled =
      terminal_result_for(
        root,
        "cancelled",
        "change_committed",
        terminal_outcome("change_committed", "succeeded", "commit", "arbor", "none")
      )

    assert {:error, {:invalid_terminal_result, :not_successful}} =
             archive_verification_case(root, :cancelled, cancelled, "passed")
  end

  test "archives every canonical task terminal without changing the callback envelope", %{
    base: base
  } do
    task_id = "task_all_terminal_1"

    {:ok, success} =
      TaskTerminalEnvelope.from_code("no_changes", "done", %{
        "kind" => "executor_result",
        "result" => %{
          "status" => "no_changes",
          "artifacts" => %{
            "task_evidence" => %{
              "schema_version" => 1,
              "task_id" => task_id,
              "path" => "/trusted/evidence.json",
              "sha256" => String.duplicate("a", 64),
              "byte_size" => 123
            }
          }
        }
      })

    {:ok, pipeline_failure} =
      TaskTerminalEnvelope.from_code("worker_turn_no_progress", "failed", %{
        "kind" => "pipeline_failure",
        "result" => %{"status" => "pipeline_error"}
      })

    {:ok, cancellation} =
      TaskTerminalEnvelope.from_code("task_cancelled", "cancelled", %{
        "kind" => "task_cancelled"
      })

    {:ok, owner_death} =
      TaskTerminalEnvelope.from_code("task_owner_died", "failed", %{
        "kind" => "task_owner_died"
      })

    {:ok, invalid_evidence} =
      TaskTerminalEnvelope.from_code("invalid_terminal_evidence", "failed", %{
        "kind" => "invalid_terminal_evidence"
      })

    {:ok, legacy_finalizer_failure} = TaskTerminalEnvelope.finalization_failed(success)

    {:ok, invalid_legacy_finalizer_failure} =
      TaskTerminalEnvelope.finalization_failed(invalid_evidence)

    cases = [
      success: success,
      pipeline_failure: pipeline_failure,
      cancellation: cancellation,
      owner_death: owner_death,
      invalid_evidence: invalid_evidence,
      legacy_finalizer_failure: legacy_finalizer_failure,
      invalid_legacy_finalizer_failure: invalid_legacy_finalizer_failure
    ]

    for {name, envelope} <- cases do
      root = Path.join(base, Atom.to_string(name))
      File.mkdir_p!(root)
      controls = if name == :success, do: [terminal_control(%{"task_id" => task_id})], else: []

      assert {:ok, descriptor} =
               ArtifactStore.archive_task_terminal(root, task_id, envelope, controls)

      body = descriptor["path"] |> File.read!() |> Jason.decode!()

      assert body == %{
               "schema_version" => 1,
               "task_id" => task_id,
               "terminal_envelope" => envelope,
               "controls" => controls
             }

      assert body["terminal_envelope"] === envelope
      assert descriptor["terminal_state"] == envelope["terminal_state"]
      assert descriptor["outcome_code"] == envelope["outcome"]["code"]
      assert descriptor["sha256"] == sha256(File.read!(descriptor["path"]))
      assert descriptor["byte_size"] == File.stat!(descriptor["path"]).size

      assert Map.keys(descriptor) |> MapSet.new() ==
               MapSet.new(
                 ~w(schema_version task_id path sha256 byte_size terminal_state outcome_code)
               )

      assert (File.stat!(descriptor["path"]).mode &&& 0o777) == 0o600
    end
  end

  test "task terminal archive is exactly idempotent and rejects conflicting rewrite", %{
    root: root
  } do
    File.mkdir_p!(root)
    envelope = successful_task_terminal_envelope("task_coding_1")

    assert {:ok, first} =
             ArtifactStore.archive_task_terminal(root, "task_coding_1", envelope, [])

    first_bytes = File.read!(first["path"])

    assert {:ok, ^first} =
             ArtifactStore.archive_task_terminal(root, "task_coding_1", envelope, [])

    assert File.read!(first["path"]) == first_bytes

    {:ok, conflicting} =
      TaskTerminalEnvelope.from_code("task_owner_died", "failed", %{
        "kind" => "task_owner_died"
      })

    assert {:error, :task_terminal_conflict} =
             ArtifactStore.archive_task_terminal(root, "task_coding_1", conflicting, [])

    assert File.read!(first["path"]) == first_bytes
  end

  test "rejects malformed or noncanonical task terminals and mismatched controls", %{root: root} do
    File.mkdir_p!(root)
    envelope = successful_task_terminal_envelope("task_coding_1")

    atom_keyed = Map.new(envelope, fn {key, value} -> {String.to_existing_atom(key), value} end)
    extra_key = Map.put(envelope, "unexpected", true)
    wrong_state = Map.put(envelope, "terminal_state", "failed")
    forged_outcome = put_in(envelope, ["outcome", "disposition"], "failed")
    wrong_embedded_task = put_in(envelope, ["evidence", "result", "task_id"], "other-task")

    over_bound =
      put_in(envelope, ["evidence", "result", "detail"], String.duplicate("x", 70_000))

    for malformed <- [atom_keyed, extra_key, forged_outcome, over_bound] do
      assert {:error, :invalid_task_terminal_envelope} =
               ArtifactStore.archive_task_terminal(root, "task_coding_1", malformed, [])
    end

    assert {:error, :invalid_task_terminal_semantics} =
             ArtifactStore.archive_task_terminal(root, "task_coding_1", wrong_state, [])

    assert {:error, :task_terminal_task_id_mismatch} =
             ArtifactStore.archive_task_terminal(root, "task_coding_1", wrong_embedded_task, [])

    assert {:error, {:invalid_terminal_control, :identity_or_order}} =
             ArtifactStore.archive_task_terminal(
               root,
               "task_coding_1",
               envelope,
               [terminal_control(%{"task_id" => "other-task"})]
             )

    assert {:error, {:invalid_terminal_control, :nonterminal_or_malformed}} =
             ArtifactStore.archive_task_terminal(
               root,
               "task_coding_1",
               envelope,
               [
                 terminal_control(%{
                   "status" => "queued",
                   "delivered_at" => nil,
                   "delivery_mode" => nil
                 })
               ]
             )

    assert {:error, {:invalid_terminal_controls, :too_many}} =
             ArtifactStore.archive_task_terminal(
               root,
               "task_coding_1",
               envelope,
               Enum.map(1..101, fn sequence ->
                 terminal_control(%{
                   "control_id" => "control_#{sequence}",
                   "sequence" => sequence
                 })
               end)
             )
  end

  test "task terminal archive rejects symlink roots and unsafe destination files", %{
    base: base,
    root: root
  } do
    File.mkdir_p!(root)
    envelope = successful_task_terminal_envelope("task_coding_1")
    root_link = Path.join(base, "task-root-link")
    File.ln_s!(root, root_link)

    assert {:error, :invalid_task_terminal_root} =
             ArtifactStore.archive_task_terminal(root_link, "task_coding_1", envelope, [])

    path = Path.join(root, "coding-task-terminal.json")
    outside = Path.join(base, "outside-terminal.json")
    File.write!(outside, "outside")
    File.ln_s!(outside, path)

    assert {:error, :task_terminal_symlink} =
             ArtifactStore.archive_task_terminal(root, "task_coding_1", envelope, [])

    File.rm!(path)
    File.mkdir!(path)

    assert {:error, :invalid_task_terminal_file} =
             ArtifactStore.archive_task_terminal(root, "task_coding_1", envelope, [])
  end

  test "task terminal replay rejects an insecure existing file mode", %{root: root} do
    File.mkdir_p!(root)
    envelope = successful_task_terminal_envelope("task_coding_1")

    assert {:ok, descriptor} =
             ArtifactStore.archive_task_terminal(root, "task_coding_1", envelope, [])

    File.chmod!(descriptor["path"], 0o644)

    assert {:error, :insecure_task_terminal_mode} =
             ArtifactStore.archive_task_terminal(root, "task_coding_1", envelope, [])
  end

  test "accepts only complete validated CrossApp capacity evidence", %{root: root} do
    File.mkdir_p!(root)

    result =
      terminal_result(root)
      |> Map.put("status", "validation_capacity_exceeded")
      |> Map.put("canonical_status", "validation_capacity_exceeded")
      |> Map.put(
        "outcome",
        terminal_outcome(
          "validation_capacity_exceeded",
          "requires_input",
          "validation",
          "validator",
          "after_external_change"
        )
      )
      |> Map.put("validation", capacity_validation())

    assert {:ok, _descriptor} =
             ArtifactStore.archive_terminal_evidence(root, "task_coding_capacity", result, [])
  end

  test "accepts live interrupted-final CrossApp capacity evidence", %{root: root} do
    File.mkdir_p!(root)

    result =
      terminal_result(root)
      |> Map.put("status", "validation_capacity_exceeded")
      |> Map.put("canonical_status", "validation_capacity_exceeded")
      |> Map.put(
        "outcome",
        terminal_outcome(
          "validation_capacity_exceeded",
          "requires_input",
          "validation",
          "validator",
          "after_external_change"
        )
      )
      |> Map.put("validation", interrupted_capacity_validation())

    assert {:ok, _descriptor} =
             ArtifactStore.archive_terminal_evidence(
               root,
               "task_coding_capacity_interrupted",
               result,
               []
             )

    archived =
      root
      |> Path.join("coding-terminal-evidence.json")
      |> File.read!()
      |> Jason.decode!()

    handoff =
      get_in(archived, [
        "validation_outputs",
        Access.at(0),
        "test",
        "capacity_handoff"
      ])

    assert handoff["interrupted_batch"]["index"] == 1
    assert handoff["unstarted_batches"] == []
    refute Map.has_key?(handoff["interrupted_batch"], "paths")
  end

  test "maximum compact capacity terminal evidence stays below the archive cap", %{root: root} do
    File.mkdir_p!(root)

    result =
      terminal_result(root)
      |> Map.put("status", "validation_capacity_exceeded")
      |> Map.put("canonical_status", "validation_capacity_exceeded")
      |> Map.put(
        "outcome",
        terminal_outcome(
          "validation_capacity_exceeded",
          "requires_input",
          "validation",
          "validator",
          "after_external_change"
        )
      )
      |> Map.put("validation", capacity_validation(343))

    assert {:ok, _descriptor} =
             ArtifactStore.archive_terminal_evidence(root, "task_coding_capacity_max", result, [])

    bytes = File.read!(Path.join(root, "coding-terminal-evidence.json"))
    assert byte_size(bytes) < 1_048_576
    refute bytes =~ "\"paths\""
  end

  test "rejects malformed capacity status and capacity evidence mismatches", %{root: root} do
    File.mkdir_p!(root)
    result = terminal_result(root)

    malformed =
      result
      |> Map.put("status", "validation_capacity_exceeded")
      |> Map.put("canonical_status", "validation_capacity_exceeded")
      |> Map.put(
        "outcome",
        terminal_outcome(
          "validation_capacity_exceeded",
          "requires_input",
          "validation",
          "validator",
          "after_external_change"
        )
      )
      |> Map.put("validation", [%{"reason" => "validation_capacity_exceeded"}])

    assert {:error, {:invalid_terminal_result, :capacity_handoff}} =
             ArtifactStore.archive_terminal_evidence(root, "task_coding_capacity", malformed, [])

    mismatched =
      result
      |> Map.put("validation", capacity_validation())
      |> Map.put("status", "validation_failed")
      |> Map.put("canonical_status", "validation_failed")
      |> Map.put(
        "outcome",
        terminal_outcome("validation_failed", "failed", "validation", "validator", "same_session")
      )

    assert {:error, {:invalid_terminal_result, :capacity_evidence_mismatch}} =
             ArtifactStore.archive_terminal_evidence(root, "task_coding_capacity", mismatched, [])
  end

  test "archive-read verifies historical schema-v1/v2 and live v3; live write rejects v1/v2", %{
    root: root
  } do
    File.mkdir_p!(root)
    inventory_sha256 = String.duplicate("a", 64)

    batch = %{
      "index" => 1,
      "total" => 1,
      "count" => 1,
      "label" => "batch-1-of-1-n1-#{inventory_sha256}",
      "inventory_sha256" => inventory_sha256
    }

    {:ok, ordered_plan_sha256} = ValidationCapacityHandoff.ordered_plan_digest([batch])

    v1_handoff = %{
      "schema_version" => 1,
      "phase" => "structural",
      "available_budget_ms" => 1_000,
      "per_batch_budget_ms" => 1_200_000,
      "required_budget_ms" => 1_200_000,
      "completed_batch_count" => 0,
      "completed_file_count" => 0,
      "unstarted_batch_count" => 1,
      "unstarted_file_count" => 1,
      "total_batch_count" => 1,
      "total_file_count" => 1,
      "ordered_plan_sha256" => ordered_plan_sha256,
      "unstarted_batches" => [batch]
    }

    v2_handoff = %{
      "schema_version" => 2,
      "phase" => "structural",
      "available_budget_ms" => 0,
      "per_batch_budget_ms" => 1_200_000,
      "completed_batch_count" => 0,
      "completed_file_count" => 0,
      "unstarted_batch_count" => 1,
      "unstarted_file_count" => 1,
      "total_batch_count" => 1,
      "total_file_count" => 1,
      "ordered_plan_sha256" => ordered_plan_sha256,
      "unstarted_batches" => [batch]
    }

    v3_handoff = %{
      "schema_version" => 3,
      "phase" => "structural",
      "available_budget_ms" => 0,
      "per_batch_budget_ms" => 1_200_000,
      "completed_batch_count" => 0,
      "completed_file_count" => 0,
      "unstarted_batch_count" => 1,
      "unstarted_file_count" => 1,
      "total_batch_count" => 1,
      "total_file_count" => 1,
      "ordered_plan_sha256" => ordered_plan_sha256,
      "interrupted_batch" => nil,
      "unstarted_batches" => [batch]
    }

    # Archive-read boundary accepts every known generation.
    assert {:ok, archived_v1} =
             ValidationCapacityTerminal.verify_archived_capacity_handoff(v1_handoff)

    assert archived_v1["schema_version"] == 1
    assert archived_v1["required_budget_ms"] == 1_200_000

    assert {:ok, archived_v2} =
             ValidationCapacityTerminal.verify_archived_capacity_handoff(v2_handoff)

    assert archived_v2["schema_version"] == 2

    assert {:ok, archived_v3} =
             ValidationCapacityTerminal.verify_archived_capacity_handoff(v3_handoff)

    assert archived_v3["schema_version"] == 3
    assert archived_v3["interrupted_batch"] == nil

    assert :error =
             ValidationCapacityTerminal.verify_archived_capacity_handoff(
               Map.put(v3_handoff, "schema_version", 99)
             )

    # Live normalize/write path rejects v1/v2 (no dual escape).
    assert {:error, _} = ValidationCapacityHandoff.normalize(v1_handoff)

    assert {:error, _} = ValidationCapacityHandoff.normalize(v2_handoff)

    assert {:ok, _} = ValidationCapacityHandoff.normalize(v3_handoff)

    result =
      terminal_result(root)
      |> Map.put("status", "validation_capacity_exceeded")
      |> Map.put("canonical_status", "validation_capacity_exceeded")
      |> Map.put(
        "outcome",
        terminal_outcome(
          "validation_capacity_exceeded",
          "requires_input",
          "validation",
          "validator",
          "after_external_change"
        )
      )
      |> Map.put("validation", [
        %{
          "passed" => false,
          "reason" => "validation_capacity_exceeded",
          "test" => %{
            "passed" => false,
            "reason" => "validation_capacity_exceeded",
            "capacity_handoff" => v1_handoff
          }
        }
      ])

    assert {:error, {:invalid_terminal_result, :capacity_handoff}} =
             ArtifactStore.archive_terminal_evidence(root, "task_coding_capacity_v1", result, [])

    # Tampered historical v1 fails archive-read as well.
    assert :error =
             ValidationCapacityTerminal.verify_archived_capacity_handoff(
               Map.put(v1_handoff, "required_budget_ms", 1)
             )
  end

  test "normalizes terminal lifecycle descriptors and rejects authority-bearing artifacts", %{
    root: root
  } do
    File.mkdir_p!(root)
    {:ok, root} = Arbor.Common.SafePath.resolve_real(root)

    lifecycle = %{
      "branch_status" => "pending",
      "cleanup_status" => "retrying",
      "cleanup_retry_count" => 1,
      "cleanup_retry_limit" => 3,
      "cleanup_failure_category" => "worktree_remove_failed",
      "discard_phase" => "worktree"
    }

    release = %{"workspace_release_status" => "discard_pending"}

    result =
      update_in(
        terminal_result(root),
        ["artifacts"],
        &Map.merge(&1, %{
          "workspace_release" => release,
          "branch_lifecycle" => lifecycle
        })
      )

    assert {:ok, descriptor} =
             ArtifactStore.archive_terminal_evidence(root, "task_coding_1", result, [])

    evidence = descriptor["path"] |> File.read!() |> Jason.decode!()
    assert evidence["workspace_release"] == release
    assert evidence["branch_lifecycle"] == lifecycle

    mismatched =
      Map.put(result, "branch_lifecycle", %{
        "branch_status" => "retired",
        "cleanup_status" => "complete"
      })

    assert {:error, {:terminal_descriptor_mismatch, "branch_lifecycle"}} =
             ArtifactStore.archive_terminal_evidence(root, "task_coding_1", mismatched, [])

    for {key, bad} <- [
          {"workspace_release",
           %{"workspace_release_status" => "discard_pending", "workspace_id" => "authority"}},
          {"branch_lifecycle", Map.put(lifecycle, "command", "git rm")}
        ] do
      invalid = update_in(terminal_result(root), ["artifacts"], &Map.put(&1, key, bad))

      assert {:error, {:invalid_terminal_artifact, ^key}} =
               ArtifactStore.archive_terminal_evidence(root, "task_coding_1", invalid, [])
    end
  end

  test "terminal evidence is deterministic and closed", %{root: root} do
    File.mkdir_p!(root)
    {:ok, root} = Arbor.Common.SafePath.resolve_real(root)
    result = terminal_result(root)

    assert {:ok, first} =
             ArtifactStore.archive_terminal_evidence(root, "task_coding_1", result, [])

    first_bytes = File.read!(first["path"])

    assert {:ok, second} =
             ArtifactStore.archive_terminal_evidence(root, "task_coding_1", result, [])

    assert second == first
    assert File.read!(second["path"]) == first_bytes

    top_level_keys =
      ~r/^  "([^"]+)":/m
      |> Regex.scan(first_bytes, capture: :all_but_first)
      |> List.flatten()

    assert top_level_keys == Enum.sort(top_level_keys)

    evidence = Jason.decode!(first_bytes)
    assert Map.keys(evidence) |> MapSet.new() == MapSet.new(~w(
               schema_version
               task_id
               terminal_status
               canonical_status
               outcome
               compiled_workflow
             steering_history
             validation_outputs
             review_verdict
           ))
    assert evidence["validation_outputs"] == [%{"command" => "mix test", "passed" => true}]

    assert evidence["review_verdict"] == %{
             "recommendation" => "approve",
             "reviewer_outcomes" => %{
               "security" => %{
                 "status" => "failed",
                 "reason_code" => "branch_failed",
                 "provider" => "openai_oauth",
                 "model" => "gpt-5.6-sol",
                 "effective_vote" => "abstain"
               }
             },
             "tier_decision" => "allow",
             "human_required" => false,
             "security_veto" => false,
             "blast_radius" => "low"
           }
  end

  test "terminal evidence binds the published candidate identity", %{root: root} do
    File.mkdir_p!(root)
    candidate_commit = String.duplicate("b", 40)
    base_commit = String.duplicate("a", 40)

    result =
      root
      |> terminal_result()
      |> Map.merge(%{
        "workspace_id" => "ws_candidate_1",
        "repo_path" => Path.expand(root),
        "branch" => "test/candidate",
        "base_commit" => base_commit,
        "commit_hash" => candidate_commit,
        "branch_provenance" => "created",
        "evidence_ref" => "refs/arbor/evidence/workspace/task"
      })

    assert {:ok, descriptor} =
             ArtifactStore.archive_terminal_evidence(root, "task_coding_1", result, [])

    evidence = descriptor["path"] |> File.read!() |> Jason.decode!()

    assert evidence["candidate"] == %{
             "task_id" => "task_coding_1",
             "workspace_id" => "ws_candidate_1",
             "repo_path" => Path.expand(root),
             "branch" => "test/candidate",
             "base_commit" => base_commit,
             "candidate_commit" => candidate_commit,
             "branch_provenance" => "created",
             "evidence_ref" => "refs/arbor/evidence/workspace/task"
           }
  end

  test "adoption evidence is content-addressed, immutable, and replayable", %{root: root} do
    File.mkdir_p!(root)

    candidate = %{
      "task_id" => "task_coding_1",
      "workspace_id" => "ws_candidate_1",
      "candidate_commit" => String.duplicate("b", 40)
    }

    proof = %{
      "method" => "ancestry",
      "destination_ref" => "refs/heads/main",
      "destination_commit" => String.duplicate("c", 40)
    }

    assert {:ok, first} =
             ArtifactStore.archive_adoption_evidence(
               root,
               "task_coding_1",
               candidate,
               proof
             )

    assert {:ok, ^first} =
             ArtifactStore.archive_adoption_evidence(
               root,
               "task_coding_1",
               candidate,
               proof
             )

    assert Path.basename(first["path"]) =~
             ~r/\Acoding-adoption-evidence-[0-9a-f]{64}\.json\z/

    body = first["path"] |> File.read!() |> Jason.decode!()
    assert body["candidate"] == candidate
    assert body["proof"] == proof

    moved_proof = Map.put(proof, "destination_commit", String.duplicate("d", 40))

    assert {:ok, second} =
             ArtifactStore.archive_adoption_evidence(
               root,
               "task_coding_1",
               candidate,
               moved_proof
             )

    assert second["path"] != first["path"]
    assert File.read!(first["path"]) |> Jason.decode!() == body
  end

  test "large unretained result fields do not prevent bounded evidence archival", %{root: root} do
    File.mkdir_p!(root)

    result =
      root
      |> terminal_result()
      |> Map.put("diff", String.duplicate("x", 1_100_000))

    assert {:ok, descriptor} =
             ArtifactStore.archive_terminal_evidence(root, "task_coding_1", result, [])

    evidence = File.read!(descriptor["path"])
    refute evidence =~ ~s("diff")
    assert byte_size(evidence) < 1_048_576
  end

  test "rejects symlink roots, malformed evidence, oversized data, and bad controls", %{
    base: base,
    root: root
  } do
    File.mkdir_p!(root)
    {:ok, root} = Arbor.Common.SafePath.resolve_real(root)
    result = terminal_result(root)
    link = Path.join(base, "root-link")
    File.ln_s!(root, link)

    assert {:error, {:invalid_terminal_root, _reason}} =
             ArtifactStore.archive_terminal_evidence(link, "task_coding_1", result, [])

    assert {:error, {:invalid_terminal_result, :not_successful}} =
             ArtifactStore.archive_terminal_evidence(
               root,
               "task_coding_1",
               Map.put(result, "canonical_status", "unknown"),
               []
             )

    assert {:error, {:invalid_terminal_result, :not_successful}} =
             ArtifactStore.archive_terminal_evidence(
               root,
               "task_coding_1",
               Map.put(result, "status", "unknown"),
               []
             )

    forged_outcome =
      Map.put(result, "outcome", Map.put(result["outcome"], "code", "validation_failed"))

    assert {:error, {:invalid_terminal_result, :not_successful}} =
             ArtifactStore.archive_terminal_evidence(root, "task_coding_1", forged_outcome, [])

    oversized = Map.put(result, "validation", [String.duplicate("x", 1_048_576)])

    assert {:error, {:terminal_evidence_too_large, 1_048_576}} =
             ArtifactStore.archive_terminal_evidence(root, "task_coding_1", oversized, [])

    assert {:error, {:invalid_terminal_controls, :expected_list}} =
             ArtifactStore.archive_terminal_evidence(root, "task_coding_1", result, %{})

    assert {:error, {:invalid_terminal_task_id, :invalid_value}} =
             ArtifactStore.archive_terminal_evidence(root, "task\nwith-control", result, [])

    assert {:error, {:invalid_terminal_control, :identity_or_order}} =
             ArtifactStore.archive_terminal_evidence(
               root,
               "task_coding_1",
               result,
               [terminal_control(%{"task_id" => "other-task"})]
             )

    assert {:error, {:invalid_terminal_controls, :too_many}} =
             ArtifactStore.archive_terminal_evidence(
               root,
               "task_coding_1",
               result,
               Enum.map(1..101, &terminal_control(%{"sequence" => &1, "control_id" => "c-#{&1}"}))
             )
  end

  test "archives design artifacts as mode-0600 immutable files and admits 17585 bytes", %{
    root: root
  } do
    alias Arbor.Contracts.Coding.DesignArtifactDescriptor

    File.mkdir_p!(root)
    design = String.duplicate("d", 17_585)
    task_id = "task_design_1"

    assert {:ok, descriptor} = ArtifactStore.archive_design_artifact(root, task_id, 1, design)
    assert DesignArtifactDescriptor.valid?(descriptor)
    assert descriptor["byte_size"] == 17_585
    assert descriptor["task_id"] == task_id
    assert descriptor["design_attempt"] == 1
    assert {:ok, canonical_root} = Arbor.Common.SafePath.resolve_real(root)
    assert descriptor["path"] == Path.join(canonical_root, "coding-design-attempt-1.txt")

    assert {:ok, %File.Stat{type: :regular, mode: mode}} = File.lstat(descriptor["path"])
    assert (mode &&& 0o777) == 0o600
    assert File.read!(descriptor["path"]) == design

    # Idempotent same content
    assert {:ok, ^descriptor} = ArtifactStore.archive_design_artifact(root, task_id, 1, design)

    # Conflict on different content
    assert {:error, :design_artifact_conflict} =
             ArtifactStore.archive_design_artifact(root, task_id, 1, design <> "x")

    assert {:ok, ^design} = ArtifactStore.read_design_artifact(root, task_id, descriptor)
  end

  test "design artifact read fails closed on missing, replaced, escaped, wrong task/attempt", %{
    root: root
  } do
    alias Arbor.Contracts.Coding.DesignArtifactDescriptor

    File.mkdir_p!(root)
    design = "exact design text"
    task_id = "task_design_2"

    assert {:ok, descriptor} = ArtifactStore.archive_design_artifact(root, task_id, 2, design)

    File.rm!(descriptor["path"])

    assert {:error, :design_artifact_unavailable} =
             ArtifactStore.read_design_artifact(root, task_id, descriptor)

    assert {:ok, descriptor} = ArtifactStore.archive_design_artifact(root, task_id, 2, design)
    File.rm!(descriptor["path"])
    File.write!(descriptor["path"], "replaced")
    File.chmod!(descriptor["path"], 0o600)

    assert {:error, :design_artifact_unavailable} =
             ArtifactStore.read_design_artifact(root, task_id, descriptor)

    assert {:ok, descriptor} = ArtifactStore.archive_design_artifact(root, task_id, 3, design)

    escaped =
      descriptor
      |> Map.put("path", "/etc/passwd")
      |> Map.put(
        "sha256",
        Base.encode16(:crypto.hash(:sha256, "x"), case: :lower)
      )

    assert {:error, reason} = ArtifactStore.read_design_artifact(root, task_id, escaped)
    assert reason in [:design_artifact_path_escaped, :design_artifact_unavailable]

    assert {:error, :design_artifact_unavailable} =
             ArtifactStore.read_design_artifact(root, "wrong-task", descriptor)

    wrong_attempt = Map.put(descriptor, "design_attempt", 99)

    assert {:error, :design_artifact_unavailable} =
             ArtifactStore.read_design_artifact(root, task_id, wrong_attempt)

    oversized = String.duplicate("x", DesignArtifactDescriptor.max_bytes() + 1)

    assert {:error, :design_body_too_large} =
             ArtifactStore.archive_design_artifact(root, task_id, 4, oversized)
  end

  defp plan_fixture do
    %{
      "version" => 1,
      "task" => "Add a focused regression test",
      "worker" => %{"provider" => "grok", "permission_mode" => "default"},
      "requested_paths" => ["apps/arbor_orchestrator/test/example_test.exs"]
    }
  end

  defp manifest_fixture do
    %{
      "compiler_version" => "coding-plan-1",
      "graph_hash" => String.duplicate("a", 64),
      "template_version" => "coding-change-v1"
    }
  end

  defp manifest_for(dot_source) do
    Map.put(manifest_fixture(), "graph_hash", sha256(dot_source))
  end

  defp compilation_candidate(task, dot_source) do
    %{
      plan: Map.put(plan_fixture(), "task", task),
      dot_source: dot_source,
      manifest: manifest_for(dot_source)
    }
  end

  defp compilation_task_root(base, task_id) do
    digest = :crypto.hash(:sha256, task_id) |> Base.encode16(case: :lower)
    Path.join(base, "task-" <> digest)
  end

  defp compilation_seal_path(root), do: Path.join(root, @compilation_seal_filename)

  defp descriptor_artifact_paths(root) do
    [
      Path.join(root, "coding-plan.json"),
      Path.join(root, "coding-pipeline.dot"),
      Path.join(root, "coding-compile-manifest.json")
    ]
  end

  defp copy_compilation_artifact!(source, destination_root) do
    destination = Path.join(destination_root, Path.basename(source))
    File.cp!(source, destination)
    File.chmod!(destination, 0o600)
  end

  defp terminal_result(root) do
    {:ok, expanded_root} = Arbor.Common.SafePath.resolve_real(root)

    %{
      "status" => "change_committed",
      "canonical_status" => "change_committed",
      "outcome" => %{
        "version" => 1,
        "disposition" => "succeeded",
        "code" => "change_committed",
        "phase" => "commit",
        "origin" => "arbor",
        "retry" => "none"
      },
      "validation" => [%{"command" => "mix test", "passed" => true}],
      "review" => %{
        "recommendation" => "approve",
        "reviewer_outcomes" => %{
          "security" => %{
            "status" => "failed",
            "reason_code" => "branch_failed",
            "provider" => "openai_oauth",
            "model" => "gpt-5.6-sol",
            "effective_vote" => "abstain"
          }
        }
      },
      "tier_decision" => "allow",
      "human_required" => false,
      "security_veto" => false,
      "blast_radius" => "low",
      "artifacts" => %{
        "coding_plan_path" => Path.join(expanded_root, "coding-plan.json"),
        "coding_pipeline_path" => Path.join(expanded_root, "coding-pipeline.dot"),
        "compile_manifest_path" => Path.join(expanded_root, "coding-compile-manifest.json"),
        "graph_hash" => String.duplicate("a", 64),
        "compiler_version" => "coding-plan-1"
      }
    }
  end

  defp terminal_result_for(root, status, canonical_status, outcome) do
    terminal_result(root)
    |> Map.merge(%{
      "status" => status,
      "canonical_status" => canonical_status,
      "outcome" => outcome
    })
  end

  defp archive_verification_case(root, name, result, report_status) do
    case_root = Path.join(root, "#{name}-#{report_status}")
    File.mkdir_p!(case_root)

    ArtifactStore.archive_terminal_evidence(
      case_root,
      "task_verification_#{name}_#{report_status}",
      Map.put(result, "verification_report", verification_report(report_status)),
      []
    )
  end

  defp assert_verification_mismatch(result) do
    assert result == {:error, {:invalid_terminal_result, :verification_status_mismatch}}
  end

  defp verification_report(status \\ "passed") do
    %{
      "version" => 1,
      "status" => status,
      "profile" => "default",
      "candidate_ref" => "git-tree:" <> @verification_tree_oid,
      "observed_at" => @verification_observed_at,
      "diagnostics" => []
    }
  end

  defp terminal_outcome(code, disposition, phase, origin, retry) do
    %{
      "version" => 1,
      "disposition" => disposition,
      "code" => code,
      "phase" => phase,
      "origin" => origin,
      "retry" => retry
    }
  end

  defp capacity_validation(batch_count \\ 1) do
    batches =
      Enum.map(1..batch_count, fn index ->
        count =
          cond do
            batch_count == 1 -> 1
            index <= 255 -> 1
            index <= 342 -> 20
            true -> 5
          end

        inventory_sha256 =
          :crypto.hash(:sha256, "inventory-#{index}")
          |> Base.encode16(case: :lower)

        %{
          "index" => index,
          "total" => batch_count,
          "count" => count,
          "label" => "batch-#{index}-of-#{batch_count}-n#{count}-#{inventory_sha256}",
          "inventory_sha256" => inventory_sha256
        }
      end)

    {:ok, ordered_plan_sha256} = ValidationCapacityHandoff.ordered_plan_digest(batches)
    file_count = Enum.sum(Enum.map(batches, & &1["count"]))
    per_batch_budget_ms = 1_200_000

    handoff = %{
      "schema_version" => 3,
      "phase" => "structural",
      "available_budget_ms" => 0,
      "per_batch_budget_ms" => per_batch_budget_ms,
      "completed_batch_count" => 0,
      "completed_file_count" => 0,
      "unstarted_batch_count" => batch_count,
      "unstarted_file_count" => file_count,
      "total_batch_count" => batch_count,
      "total_file_count" => file_count,
      "ordered_plan_sha256" => ordered_plan_sha256,
      "interrupted_batch" => nil,
      "unstarted_batches" => batches
    }

    [
      %{
        "passed" => false,
        "reason" => "validation_capacity_exceeded",
        "test" => %{
          "passed" => false,
          "reason" => "validation_capacity_exceeded",
          "capacity_handoff" => handoff
        }
      }
    ]
  end

  defp interrupted_capacity_validation do
    inventory_sha256 = String.duplicate("a", 64)

    batch = %{
      "index" => 1,
      "total" => 1,
      "count" => 1,
      "label" => "batch-1-of-1-n1-#{inventory_sha256}",
      "inventory_sha256" => inventory_sha256
    }

    {:ok, ordered_plan_sha256} = ValidationCapacityHandoff.ordered_plan_digest([batch])

    [
      %{
        "passed" => false,
        "reason" => "validation_capacity_exceeded",
        "test" => %{
          "passed" => false,
          "reason" => "validation_capacity_exceeded",
          "capacity_handoff" => %{
            "schema_version" => 3,
            "phase" => "runtime",
            "available_budget_ms" => 0,
            "per_batch_budget_ms" => 1_200_000,
            "completed_batch_count" => 0,
            "completed_file_count" => 0,
            "unstarted_batch_count" => 0,
            "unstarted_file_count" => 0,
            "total_batch_count" => 1,
            "total_file_count" => 1,
            "ordered_plan_sha256" => ordered_plan_sha256,
            "interrupted_batch" => batch,
            "unstarted_batches" => []
          }
        }
      }
    ]
  end

  defp terminal_control(overrides \\ %{}) do
    Map.merge(
      %{
        "control_id" => "control_exact_1",
        "task_id" => "task_coding_1",
        "sequence" => 1,
        "status" => "delivered",
        "sender_id" => "agent_owner",
        "message" => "apply the correction",
        "queued_at" => "2026-07-10T12:00:00Z",
        "delivered_at" => "2026-07-10T12:01:00Z",
        "target_stage" => nil,
        "delivery_mode" => "same_session_follow_up",
        "error" => nil
      },
      overrides
    )
  end

  defp successful_task_terminal_envelope(task_id) do
    {:ok, envelope} =
      TaskTerminalEnvelope.from_code("no_changes", "done", %{
        "kind" => "executor_result",
        "result" => %{"status" => "no_changes", "task_id" => task_id}
      })

    envelope
  end

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp read_artifacts(descriptor) do
    Map.new(artifact_paths(descriptor), fn {name, path} -> {name, File.read!(path)} end)
  end

  defp artifact_paths(descriptor) do
    Map.take(descriptor, [
      "coding_plan_path",
      "coding_pipeline_path",
      "compile_manifest_path"
    ])
  end

  defp temporary_file_observations(root) do
    case File.ls(root) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.starts_with?(&1, ".coding-pipeline.dot.tmp-"))
        |> Enum.flat_map(fn name ->
          path = Path.join(root, name)

          case File.stat(path) do
            {:ok, stat} -> [%{name: name, size: stat.size, mode: stat.mode &&& 0o777}]
            {:error, :enoent} -> []
          end
        end)

      {:error, :enoent} ->
        []
    end
  end
end
