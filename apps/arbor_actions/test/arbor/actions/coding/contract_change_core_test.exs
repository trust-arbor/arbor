defmodule Arbor.Actions.Coding.ContractChange.CoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Actions.Coding.BlobManifest
  alias Arbor.Actions.Coding.ContractChange.Core
  alias Arbor.Contracts.Coding.ValidationCapacityHandoff

  @moduletag :fast
  @preflight_sha String.duplicate("a", 64)
  @tests_sha String.duplicate("b", 64)
  @max_changed_files BlobManifest.max_changed_files()

  @kernel_suite [
    "apps/arbor_kernel/test/arbor/contracts/admission_test.exs",
    "apps/arbor_kernel/test/arbor/contracts/dependency_hierarchy_test.exs"
  ]

  @app_roots [
    "apps/arbor_kernel/mix.exs",
    "apps/arbor_security/mix.exs"
  ]

  describe "new/1" do
    test "defaults omitted stage_timeout to 600_000" do
      assert {:ok, input} = Core.new(%{workspace_id: "ws_closed"})
      assert input.stage_timeout == 600_000
      assert input.timeout == Core.default_timeout()
    end

    test "accepts only workspace_id and reviewed timeout controls" do
      assert {:ok, input} = Core.new(%{workspace_id: "ws_closed", timeout: 10_000})
      assert input.workspace_id == "ws_closed"
      assert input.timeout == 10_000
      assert input.stage_timeout == Core.default_stage_timeout()
      assert input.stage_timeout == 600_000

      assert {:ok, %{stage_timeout: 15_000}} =
               Core.new(%{workspace_id: "ws_closed", timeout: 10_000, stage_timeout: 15_000})

      assert {:error, :unsupported_parameter} =
               Core.new(%{workspace_id: "ws_closed", path: "/tmp"})

      assert {:error, :unsupported_parameter} =
               Core.new(%{workspace_id: "ws_closed", test_paths: ["apps/foo/test"]})

      assert {:error, :unsupported_parameter} =
               Core.new(%{workspace_id: "ws_closed", test_stage_timeout: 1_000})

      assert {:error, :invalid_timeout} =
               Core.new(%{workspace_id: "ws_closed", timeout: Core.maximum_timeout() + 1})

      assert {:error, :invalid_stage_timeout} =
               Core.new(%{
                 workspace_id: "ws_closed",
                 stage_timeout: Core.maximum_stage_timeout() + 1
               })
    end
  end

  describe "admit_contract_surface/3" do
    test "admits kernel contracts, barrel, app-owned contracts, CONTRACT_RULES, and census" do
      for path <- [
            "apps/arbor_kernel/lib/arbor/contracts/security/capability.ex",
            "apps/arbor_kernel/lib/arbor/contracts.ex",
            "apps/arbor_security/lib/arbor/security/contracts/foo.ex",
            "docs/arbor/CONTRACT_RULES.md",
            "apps/arbor_kernel/lib/mix/tasks/arbor.contracts.census.ex",
            "apps/arbor_kernel/lib/arbor/contracts_census.ex"
          ] do
        assert {:ok, true} = Core.admit_contract_surface([path], @app_roots, @app_roots)
      end
    end

    test "admits a contract surface plus unrelated consumer files" do
      assert {:ok, true} =
               Core.admit_contract_surface(
                 [
                   "apps/arbor_dashboard/lib/arbor/dashboard.ex",
                   "apps/arbor_kernel/lib/arbor/contracts/coding/plan.ex"
                 ],
                 @app_roots,
                 @app_roots
               )
    end

    test "rejects no-contract diffs and false prefixes" do
      for path <- [
            "apps/arbor_dashboard/lib/arbor/dashboard.ex",
            "apps/arbor_kernel/test/arbor/contracts/plan_test.exs",
            "apps/arbor_kernel/lib/arbor/contracts_extra.ex",
            "apps/arbor_kernel/lib/arbor/contract/foo.ex",
            "apps/foo/lib/bar/contracts.ex",
            "apps/foo/lib/bar/contracts_api/x.ex",
            "docs/arbor/CONTRACT_RULES.md.bak",
            "apps/arbor_kernel/lib/mix/tasks/arbor.contracts.census.bak.ex",
            "apps/arbor_contracts/lib/arbor/contracts/foo.ex"
          ] do
        assert {:ok, false} = Core.admit_contract_surface([path], @app_roots, @app_roots), path
      end
    end

    test "rejects leading and trailing whitespace paths without aliasing" do
      leading = " apps/arbor_kernel/lib/arbor/contracts/foo.ex"
      trailing = "apps/arbor_kernel/lib/arbor/contracts/foo.ex "

      assert {:error, {:invalid_repo_path, ^leading}} =
               Core.admit_contract_surface([leading], @app_roots, @app_roots)

      assert {:error, {:invalid_repo_path, ^trailing}} =
               Core.admit_contract_surface([trailing], @app_roots, @app_roots)
    end

    test "rejects double-slash and dot-segment paths as malformed" do
      double = "apps/arbor_kernel/lib/arbor/contracts/foo//bar.ex"
      dotted = "apps/arbor_kernel/lib/arbor/contracts/foo/./bar.ex"

      assert {:error, {:invalid_repo_path, ^double}} =
               Core.admit_contract_surface([double], @app_roots, @app_roots)

      assert {:error, {:invalid_repo_path, ^dotted}} =
               Core.admit_contract_surface([dotted], @app_roots, @app_roots)

      assert {:error, {:invalid_repo_path, ^double}} =
               Core.select_contract_tests([double], @kernel_suite)
    end

    test "app-owned contracts require mix.exs in the base or candidate inventory" do
      ghost = "apps/ghost_app/lib/ghost/contracts/foo.ex"
      kernel_only = ["apps/arbor_kernel/mix.exs"]

      assert {:ok, false} = Core.admit_contract_surface([ghost], kernel_only, kernel_only)

      assert {:ok, false} =
               Core.admit_contract_surface(
                 ["apps/arbor_dashboard/lib/arbor/dashboard.ex", ghost],
                 kernel_only,
                 kernel_only
               )

      assert {:ok, true} =
               Core.admit_contract_surface(
                 [ghost],
                 kernel_only,
                 kernel_only ++ ["apps/ghost_app/mix.exs"]
               )

      assert {:ok, true} =
               Core.admit_contract_surface(
                 [ghost],
                 kernel_only ++ ["apps/ghost_app/mix.exs"],
                 kernel_only
               )
    end

    test "enforces the changed-file bound without rewriting paths" do
      exact =
        Enum.map(1..@max_changed_files, fn i ->
          "apps/arbor_kernel/lib/arbor/contracts/f#{i}.ex"
        end)

      overflow = exact ++ ["apps/arbor_kernel/lib/arbor/contracts/overflow.ex"]

      assert {:ok, true} = Core.admit_contract_surface(exact, [], [])
      assert {:error, :too_many_paths} = Core.admit_contract_surface(overflow, [], [])
    end
  end

  describe "BlobManifest path identity" do
    test "preserves exact Git path bytes and uses segment-aware validation" do
      leading = " apps/arbor_kernel/lib/arbor/contracts/new.ex"
      trailing = "apps/arbor_kernel/lib/arbor/contracts/new.ex "
      trimmed = "apps/arbor_kernel/lib/arbor/contracts/new.ex"
      dots_name = "apps/arbor_kernel/lib/arbor/contracts/bar..baz.ex"

      assert {:ok, [^leading]} =
               BlobManifest.diff_blob_manifests([], [blob(leading, "b")])

      assert {:ok, [^trailing]} =
               BlobManifest.diff_blob_manifests([], [blob(trailing, "c")])

      assert {:ok, leading_changed} =
               BlobManifest.diff_blob_manifests(
                 [blob(trimmed)],
                 [blob(trimmed), blob(leading, "b")]
               )

      assert leading_changed == [leading]
      refute trimmed in leading_changed

      assert {:ok, trailing_changed} =
               BlobManifest.diff_blob_manifests(
                 [blob(trimmed)],
                 [blob(trimmed), blob(trailing, "c")]
               )

      assert trailing_changed == [trailing]
      refute trimmed in trailing_changed

      assert {:ok, [^dots_name]} =
               BlobManifest.diff_blob_manifests([], [blob(dots_name, "d")])

      assert {:error, :invalid_blob_manifest_path} =
               BlobManifest.diff_blob_manifests([], [blob("foo/../bar")])

      assert {:error, :invalid_blob_manifest_path} =
               BlobManifest.diff_blob_manifests([], [blob("foo//bar")])
    end
  end

  test "security regression: parse_ls_tree_z preserves a pathname tab after the metadata separator" do
    oid = String.duplicate("a", 40)
    listing = "100644 blob #{oid}\tfoo\tbar.ex" <> <<0>>

    assert {:ok, [entry]} = BlobManifest.parse_ls_tree_z(listing)
    assert entry.path == "foo\tbar.ex"
    assert entry.mode == "100644"
    assert entry.oid == oid

    assert {:error, :invalid_base_ls_tree_entry} =
             BlobManifest.parse_ls_tree_z("100644 blob #{oid} foo.ex" <> <<0>>)

    assert {:error, :invalid_base_ls_tree_entry} =
             BlobManifest.parse_ls_tree_z("100644 blob #{oid}\t" <> <<0>>)

    assert {:error, {:unsupported_base_gitlink, "vendor/lib"}} =
             BlobManifest.parse_ls_tree_z("160000 commit #{oid}\tvendor/lib" <> <<0>>)

    assert {:error, {:unexpected_base_tree_entry, "apps"}} =
             BlobManifest.parse_ls_tree_z("040000 tree #{oid}\tapps" <> <<0>>)

    assert {:error, {:invalid_base_blob_oid, "foo.ex"}} =
             BlobManifest.parse_ls_tree_z("100644 blob not-an-oid\tfoo.ex" <> <<0>>)
  end

  describe "select_contract_tests/2" do
    test "always includes the kernel suite and maps app-owned lib contracts" do
      freeze =
        @kernel_suite ++
          [
            "apps/arbor_security/lib/arbor/security/contracts/foo.ex",
            "apps/arbor_security/test/arbor/security/contracts/foo_test.exs",
            "apps/arbor_security/test/support/contracts/extra_test.exs",
            "apps/arbor_dashboard/lib/arbor/dashboard.ex"
          ]

      changed = [
        "apps/arbor_kernel/lib/arbor/contracts/coding/plan.ex",
        "apps/arbor_security/lib/arbor/security/contracts/foo.ex",
        "apps/arbor_security/test/support/contracts/extra_test.exs",
        "apps/arbor_dashboard/lib/arbor/dashboard.ex"
      ]

      assert {:ok, selected} = Core.select_contract_tests(changed, freeze)

      assert selected ==
               Enum.sort(
                 @kernel_suite ++
                   [
                     "apps/arbor_security/test/arbor/security/contracts/foo_test.exs",
                     "apps/arbor_security/test/support/contracts/extra_test.exs"
                   ]
               )
    end

    test "rejects false-prefix test paths and missing kernel suite" do
      freeze = [
        "apps/arbor_kernel/test/arbor/contracts_extra/foo_test.exs",
        "apps/foo/test/bar/contractss/x_test.exs"
      ]

      assert {:error, :contract_suite_missing} =
               Core.select_contract_tests(
                 ["apps/arbor_kernel/lib/arbor/contracts/foo.ex"],
                 freeze
               )
    end

    test "does not include candidate-supplied paths outside the freeze" do
      freeze = @kernel_suite

      assert {:ok, selected} =
               Core.select_contract_tests(
                 [
                   "apps/arbor_kernel/lib/arbor/contracts/coding/plan.ex",
                   "apps/evil/test/arbor/contracts/injected_test.exs"
                 ],
                 freeze
               )

      assert selected == Enum.sort(@kernel_suite)
      refute "apps/evil/test/arbor/contracts/injected_test.exs" in selected
    end
  end

  describe "preflight argv" do
    test "is owner-owned cold-build Mix.do compile/xref/census" do
      assert Core.preflight_argv() == [
               "do",
               "compile",
               "--warnings-as-errors",
               "+",
               "xref",
               "graph",
               "--no-deps-check",
               "+",
               "arbor.contracts.census",
               "--fail-on-violation"
             ]

      assert Core.test_argv_prefix() ==
               ["test", "--no-deps-check", "--warnings-as-errors", "--"]

      assert {:ok, args} = Core.test_argv(@kernel_suite)
      assert args == Core.test_argv_prefix() ++ Enum.sort(@kernel_suite)
    end
  end

  describe "show/1" do
    test "emits closed evidence with skipped checks when the surface is missing" do
      skipped = Core.skipped_check("contract_surface_missing")

      evidence =
        Core.show(%{
          changed_files: ["apps/arbor_dashboard/lib/arbor/dashboard.ex"],
          test_paths: [],
          checks: %{preflight: skipped, test: skipped},
          base_commit: String.duplicate("a", 40)
        })

      assert evidence.passed == false
      assert evidence.reason == "contract_surface_missing"
      assert evidence.preflight["status"] == "skipped"
      assert evidence.test["status"] == "skipped"
    end

    test "keeps exact sorted inventories at the 2000/256 transport bound" do
      files =
        Enum.map(1..2_000, fn i ->
          "apps/arbor_kernel/lib/arbor/contracts/file_#{i}.ex"
        end)

      tests =
        Enum.map(1..256, fn i ->
          n = String.pad_leading(Integer.to_string(i), 3, "0")
          "apps/arbor_kernel/test/arbor/contracts/file_#{n}_test.exs"
        end)

      assert {:ok, inventories} = Core.admit_transport_inventories(files, tests)
      passed = Core.completed_check(%{"passed" => true, "exit_code" => 0})

      evidence =
        Core.show(%{
          changed_files: inventories.changed_files,
          test_paths: inventories.test_paths,
          checks: %{preflight: passed, test: passed},
          base_commit: String.duplicate("a", 40)
        })

      assert evidence.changed_files == inventories.changed_files
      assert evidence.test_paths == inventories.test_paths
      assert length(evidence.changed_files) == 2_000
      assert length(evidence.test_paths) == 256
    end
  end

  describe "feedback_projection/1" do
    test "omits path lists and carries counts plus inventory digests" do
      files = ["apps/arbor_kernel/lib/arbor/contracts/coding/plan.ex"]
      tests = ["apps/arbor_kernel/test/arbor/contracts/admission_test.exs"]
      passed = Core.completed_check(%{"passed" => true, "exit_code" => 0})

      evidence =
        Core.show(%{
          changed_files: files,
          test_paths: tests,
          checks: %{preflight: passed, test: passed},
          base_commit: String.duplicate("a", 40)
        })

      assert {:ok, projection} = Core.feedback_projection(evidence)
      refute Map.has_key?(projection, :changed_files)
      refute Map.has_key?(projection, :test_paths)
      refute Map.has_key?(projection, "changed_files")
      refute Map.has_key?(projection, "test_paths")
      assert projection.passed == true
      assert projection.reason == "contract_change_validated"
      assert projection.base_commit == evidence.base_commit
      assert projection.preflight == evidence.preflight
      assert projection.test == evidence.test
      assert projection.changed_files_count == 1
      assert projection.test_paths_count == 1
      assert projection.changed_files_sha256 == Core.inventory_sha256(evidence.changed_files)
      assert projection.test_paths_sha256 == Core.inventory_sha256(evidence.test_paths)

      string_keyed =
        evidence
        |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)

      assert {:ok, ^projection} = Core.feedback_projection(string_keyed)
    end

    test "empty test_paths digest is sha256 of the empty inventory" do
      skipped = Core.skipped_check("contract_surface_missing")

      evidence =
        Core.show(%{
          changed_files: ["apps/arbor_dashboard/lib/arbor/dashboard.ex"],
          test_paths: [],
          checks: %{preflight: skipped, test: skipped},
          base_commit: String.duplicate("a", 40)
        })

      assert {:ok, projection} = Core.feedback_projection(evidence)
      assert projection.test_paths_count == 0
      assert projection.test_paths_sha256 == Core.inventory_sha256([])
      refute Map.has_key?(projection, :test_paths)
    end

    test "omits mixed check extras while keeping stage status and reason" do
      {:ok, capacity} =
        Core.capacity_check(:runtime, 10_000, %{
          completed: [preflight_batch()],
          unstarted: [tests_batch()]
        })

      mixed = Map.put(capacity, "termination", containment_termination())

      evidence =
        Core.show(%{
          changed_files: ["apps/arbor_kernel/lib/arbor/contracts/foo.ex"],
          test_paths: ["apps/arbor_kernel/test/arbor/contracts/admission_test.exs"],
          checks: %{
            preflight: mixed,
            test: Core.skipped_check("validation_capacity_exceeded")
          },
          base_commit: String.duplicate("c", 40)
        })

      assert {:ok, projection} = Core.feedback_projection(evidence)
      refute Map.has_key?(projection.preflight, "capacity_handoff")
      refute Map.has_key?(projection.preflight, "termination")
      assert MapSet.new(Map.keys(projection.preflight)) == closed_feedback_check_keys()
      assert projection.preflight["status"] == "completed"
      assert projection.preflight["reason"] == "validation_capacity_exceeded"
      assert projection.test["status"] == "skipped"
      assert projection.test["reason"] == "validation_capacity_exceeded"
    end

    test "rejects invalid inventories and incomplete evidence" do
      passed = Core.completed_check(%{"passed" => true, "exit_code" => 0})

      evidence =
        Core.show(%{
          changed_files: ["apps/arbor_kernel/lib/arbor/contracts/foo.ex"],
          test_paths: ["apps/arbor_kernel/test/arbor/contracts/admission_test.exs"],
          checks: %{preflight: passed, test: passed},
          base_commit: String.duplicate("a", 40)
        })

      assert {:error, :invalid_feedback_projection} =
               Core.feedback_projection(Map.put(evidence, :changed_files, "not-a-list"))

      assert {:error, :invalid_feedback_projection} =
               Core.feedback_projection(Map.put(evidence, :test_paths, :not_a_list))

      too_many =
        Enum.map(1..2_001, fn i ->
          "apps/arbor_kernel/lib/arbor/contracts/file_#{i}.ex"
        end)

      assert {:error, :invalid_feedback_projection} =
               Core.feedback_projection(Map.put(evidence, :changed_files, too_many))

      assert {:error, :invalid_feedback_projection} = Core.feedback_projection(%{})
      assert {:error, :invalid_feedback_projection} = Core.feedback_projection("nope")
    end

    test "security regression: oversized scalars and unknown check extras never copy into feedback" do
      passed = Core.completed_check(%{"passed" => true, "exit_code" => 0})

      evidence =
        Core.show(%{
          changed_files: ["apps/arbor_kernel/lib/arbor/contracts/foo.ex"],
          test_paths: ["apps/arbor_kernel/test/arbor/contracts/admission_test.exs"],
          checks: %{preflight: passed, test: passed},
          base_commit: String.duplicate("a", 40)
        })

      huge = String.duplicate("x", 2_000_000)

      assert {:error, :invalid_feedback_projection} =
               Core.feedback_projection(Map.put(evidence, :reason, huge))

      assert {:error, :invalid_feedback_projection} =
               Core.feedback_projection(Map.put(evidence, :base_commit, huge))

      dirty =
        passed
        |> Map.put("stdout_excerpt", huge)
        |> Map.put("stderr_excerpt", huge)
        |> Map.put("reason", huge)
        |> Map.put("unknown_blob", huge)
        |> Map.put("capacity_handoff", %{"noise" => huge})
        |> Map.put("termination", Map.put(containment_termination(), "payload", huge))

      assert {:error, :invalid_feedback_projection} =
               Core.feedback_projection(Map.put(evidence, :preflight, dirty))

      dirty_excerpt =
        passed
        |> Map.put("stdout_excerpt", huge)
        |> Map.put("unknown_blob", huge)
        |> Map.put("capacity_handoff", %{"noise" => huge})

      assert {:ok, projection} =
               Core.feedback_projection(Map.put(evidence, :preflight, dirty_excerpt))

      refute Map.has_key?(projection.preflight, "unknown_blob")
      refute Map.has_key?(projection.preflight, "capacity_handoff")
      refute Map.has_key?(projection.preflight, "termination")
      assert byte_size(projection.preflight["stdout_excerpt"]) <= 2_000
      assert projection.preflight["stdout_sha256"] == passed["stdout_sha256"]
      assert projection.preflight["stdout_truncated"] == true
      assert MapSet.new(Map.keys(projection.preflight)) == closed_feedback_check_keys()
      assert byte_size(Jason.encode!(projection)) <= 1_048_576

      for invalid_sha <- [huge, "not-a-digest", nil] do
        malformed_sha = Map.put(passed, "stdout_sha256", invalid_sha)

        assert {:error, :invalid_feedback_projection} =
                 Core.feedback_projection(Map.put(evidence, :preflight, malformed_sha))
      end

      missing_sha = Map.delete(passed, "stderr_sha256")

      assert {:error, :invalid_feedback_projection} =
               Core.feedback_projection(Map.put(evidence, :preflight, missing_sha))

      for invalid_exit_code <- [-1, 256, 10_000] do
        invalid_check = Map.put(passed, "exit_code", invalid_exit_code)

        assert {:error, :invalid_feedback_projection} =
                 Core.feedback_projection(Map.put(evidence, :preflight, invalid_check))
      end
    end

    test "max valid ordered 1024-byte paths stay under the consumer feedback ceiling" do
      files = Enum.map(1..2_000, &max_changed_path/1)
      tests = Enum.map(1..256, &max_test_path/1)
      assert byte_size(hd(files)) == 1_024
      assert byte_size(hd(tests)) == 1_024

      assert {:ok, inventories} = Core.admit_transport_inventories(files, tests)
      passed = Core.completed_check(%{"passed" => true, "exit_code" => 0})

      evidence =
        Core.show(%{
          changed_files: inventories.changed_files,
          test_paths: inventories.test_paths,
          checks: %{preflight: passed, test: passed},
          base_commit: String.duplicate("a", 40)
        })

      assert evidence.changed_files == inventories.changed_files
      assert evidence.test_paths == inventories.test_paths
      assert byte_size(Jason.encode!(evidence)) > 1_048_576

      assert {:ok, projection} = Core.feedback_projection(evidence)
      refute Map.has_key?(projection, :changed_files)
      refute Map.has_key?(projection, :test_paths)
      assert projection.changed_files_count == 2_000
      assert projection.test_paths_count == 256
      assert projection.changed_files_sha256 == Core.inventory_sha256(inventories.changed_files)
      assert projection.test_paths_sha256 == Core.inventory_sha256(inventories.test_paths)
      assert byte_size(Jason.encode!(projection)) <= 1_048_576
    end
  end

  describe "check_from_projection/4" do
    test "containment wins over killed and keeps Mix five-key envelope" do
      assert {:ok, check} =
               Core.check_from_projection(
                 feedback(),
                 containment_projection(),
                 :preflight,
                 preflight_plan()
               )

      assert check["passed"] == false
      assert check["exit_code"] == 0
      assert check["reason"] == "validation_containment_failure"
      assert check["termination"] == containment_termination()
      refute Map.has_key?(check, "capacity_handoff")
    end

    test "each capacity flag becomes interrupted runtime handoff without Mix termination" do
      for flag <- [:timed_out, :killed, :output_limit_exceeded, :cancelled] do
        assert {:ok, check} =
                 Core.check_from_projection(
                   feedback(),
                   capacity_projection(flag),
                   :preflight,
                   preflight_plan()
                 )

        assert check["passed"] == false, inspect(flag)
        assert check["exit_code"] == 0
        assert check["reason"] == "validation_capacity_exceeded"
        refute Map.has_key?(check, "termination")
        handoff = check["capacity_handoff"]
        assert ValidationCapacityHandoff.valid?(handoff)
        assert handoff["phase"] == "runtime"
        assert_canonical_batch(handoff["interrupted_batch"], 1, 2)
        assert Enum.map(handoff["unstarted_batches"], & &1["index"]) == [2]
        Enum.each(handoff["unstarted_batches"], &assert_canonical_batch(&1, &1["index"], 2))
      end
    end

    test "ordinary pass and fail do not attach extras" do
      assert {:ok, passed} =
               Core.check_from_projection(
                 feedback(),
                 %{exit_code: 0, passed: true, reason: nil, termination: nil},
                 :preflight,
                 preflight_plan()
               )

      assert passed["passed"] == true
      assert passed["reason"] == nil
      refute Map.has_key?(passed, "termination")
      refute Map.has_key?(passed, "capacity_handoff")

      assert {:ok, failed} =
               Core.check_from_projection(
                 feedback(exit_code: 1),
                 %{exit_code: 1, passed: false, reason: nil, termination: nil},
                 :preflight,
                 preflight_plan()
               )

      assert failed["passed"] == false
      assert failed["reason"] == "preflight_failed"
    end

    test "show preserves mixed extras without rewriting them" do
      {:ok, capacity} =
        Core.capacity_check(:runtime, 10_000, %{
          completed: [preflight_batch()],
          unstarted: [tests_batch()]
        })

      mixed = Map.put(capacity, "termination", containment_termination())

      evidence =
        Core.show(%{
          changed_files: ["apps/arbor_kernel/lib/arbor/contracts/foo.ex"],
          test_paths: ["apps/arbor_kernel/test/arbor/contracts/admission_test.exs"],
          checks: %{
            preflight: mixed,
            test: Core.skipped_check("validation_capacity_exceeded")
          },
          base_commit: String.duplicate("c", 40)
        })

      assert is_map(evidence.preflight["capacity_handoff"])
      assert evidence.preflight["termination"] == containment_termination()
    end
  end

  test "security regression: prelaunch_probe_timeout_capacity? converts only closed probe timeout after residual exhaustion" do
    assert Core.prelaunch_probe_timeout_capacity?(:probe_timeout, 0)
    assert Core.prelaunch_probe_timeout_capacity?(:probe_timeout, -1)
    refute Core.prelaunch_probe_timeout_capacity?(:probe_timeout, 1)

    assert Core.prelaunch_probe_timeout_capacity?(":probe_timeout", 0)
    refute Core.prelaunch_probe_timeout_capacity?(":probe_timeout", 1)

    refute Core.prelaunch_probe_timeout_capacity?(:probe_failed, 0)
    refute Core.prelaunch_probe_timeout_capacity?(:operation_deadline_exceeded, 0)
    refute Core.prelaunch_probe_timeout_capacity?("probe_timeout", 0)

    refute Core.prelaunch_probe_timeout_capacity?(
             {:test_execution_failed, "x", :probe_timeout},
             0
           )

    refute Core.prelaunch_probe_timeout_capacity?(:probe_timeout, "0")
  end

  test "security regression: resource_acquisition_deadline? is the exact atom only" do
    assert Core.resource_acquisition_deadline?(:operation_deadline_exceeded)
    refute Core.resource_acquisition_deadline?(":operation_deadline_exceeded")
    refute Core.resource_acquisition_deadline?({:wrapped, :operation_deadline_exceeded})
    refute Core.resource_acquisition_deadline?(:probe_timeout)
    refute Core.resource_acquisition_deadline?("operation_deadline_exceeded")
  end

  test "security regression: admit_transport_inventories admits 256/2000, rejects over-bound with the bound error, and rejects non-lists as invalid shape" do
    files_2000 =
      Enum.map(1..2_000, fn i ->
        "apps/arbor_kernel/lib/arbor/contracts/file_#{i}.ex"
      end)

    tests_256 =
      Enum.map(1..256, fn i ->
        n = String.pad_leading(Integer.to_string(i), 3, "0")
        "apps/arbor_kernel/test/arbor/contracts/file_#{n}_test.exs"
      end)

    assert {:ok, admitted} = Core.admit_transport_inventories(files_2000, tests_256)
    assert length(admitted.changed_files) == 2_000
    assert length(admitted.test_paths) == 256

    tests_257 =
      tests_256 ++ ["apps/arbor_kernel/test/arbor/contracts/file_257_test.exs"]

    assert {:error, :too_many_paths} = Core.admit_transport_inventories(files_2000, tests_257)

    files_2001 = files_2000 ++ ["apps/arbor_kernel/lib/arbor/contracts/file_2001.ex"]
    assert {:error, :too_many_paths} = Core.admit_transport_inventories(files_2001, tests_256)

    assert {:error, :invalid_contract_inventory} =
             Core.admit_transport_inventories("not-a-list", tests_256)

    assert {:error, :invalid_contract_inventory} =
             Core.admit_transport_inventories(files_2000, :not_a_list)

    assert {:error, :invalid_contract_inventory} =
             Core.admit_transport_inventories("not-a-list", :not_a_list)
  end

  describe "capacity_check/3 interrupted versus unstarted" do
    test "pre-launch unstarted suffix keeps interrupted_batch nil" do
      assert {:ok, check} =
               Core.capacity_check(:structural, 10_000, %{
                 completed: [],
                 unstarted: [preflight_batch(), tests_batch()]
               })

      handoff = check["capacity_handoff"]
      assert handoff["interrupted_batch"] == nil
      assert Enum.map(handoff["unstarted_batches"], & &1["index"]) == [1, 2]
      Enum.each(handoff["unstarted_batches"], &assert_canonical_batch(&1, &1["index"], 2))
      assert ValidationCapacityHandoff.valid?(handoff)
    end

    test "final-stage interrupt names the launched tests batch" do
      assert {:ok, check} =
               Core.capacity_check(:runtime, 10_000, %{
                 completed: [preflight_batch()],
                 interrupted: tests_batch(),
                 unstarted: []
               })

      handoff = check["capacity_handoff"]
      assert handoff["phase"] == "runtime"
      assert_canonical_batch(handoff["interrupted_batch"], 2, 2)
      assert handoff["unstarted_batches"] == []
      assert ValidationCapacityHandoff.valid?(handoff)
    end
  end

  defp blob(path, oid_seed \\ "a") do
    %{path: path, mode: "100644", oid: String.duplicate(oid_seed, 40)}
  end

  defp preflight_batch, do: Core.preflight_batch(@preflight_sha)
  defp tests_batch, do: Core.tests_batch(1, @tests_sha)

  defp assert_canonical_batch(batch, index, total) do
    assert batch["index"] == index
    assert batch["total"] == total
    assert is_integer(batch["count"]) and batch["count"] > 0

    assert batch["label"] ==
             "batch-#{index}-of-#{total}-n#{batch["count"]}-#{batch["inventory_sha256"]}"
  end

  defp preflight_plan do
    %{
      completed: [],
      current: preflight_batch(),
      unstarted: [tests_batch()],
      per_batch_budget_ms: 10_000
    }
  end

  defp feedback(opts \\ []) do
    Core.feedback_from_result(%{
      exit_code: Keyword.get(opts, :exit_code, 0),
      stdout: "ok",
      stderr: ""
    })
  end

  defp containment_termination do
    %{
      "timed_out" => false,
      "killed" => true,
      "output_limit_exceeded" => false,
      "cancelled" => false,
      "containment_failure" => true
    }
  end

  defp containment_projection do
    %{
      exit_code: 0,
      passed: false,
      reason: "validation_containment_failure",
      termination: containment_termination()
    }
  end

  defp capacity_projection(flag) do
    %{
      exit_code: 0,
      passed: false,
      reason: "validation_capacity_exceeded",
      termination: %{
        "timed_out" => flag == :timed_out,
        "killed" => flag == :killed,
        "output_limit_exceeded" => flag == :output_limit_exceeded,
        "cancelled" => flag == :cancelled
      }
    }
  end

  defp closed_feedback_check_keys do
    MapSet.new(~w(
      exit_code passed reason stderr_excerpt stderr_sha256 stderr_truncated
      status stdout_excerpt stdout_sha256 stdout_truncated
    ))
  end

  defp max_changed_path(i) do
    index = String.pad_leading(Integer.to_string(i), 4, "0")
    prefix = "apps/arbor_kernel/lib/arbor/contracts/"
    suffix = "_#{index}.ex"
    prefix <> String.duplicate("a", 1_024 - byte_size(prefix) - byte_size(suffix)) <> suffix
  end

  defp max_test_path(i) do
    index = String.pad_leading(Integer.to_string(i), 4, "0")
    prefix = "apps/arbor_kernel/test/arbor/contracts/"
    suffix = "_#{index}_test.exs"
    prefix <> String.duplicate("a", 1_024 - byte_size(prefix) - byte_size(suffix)) <> suffix
  end
end
