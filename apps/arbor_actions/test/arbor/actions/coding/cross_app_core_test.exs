defmodule Arbor.Actions.Coding.CrossApp.CoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Actions.Coding.CrossApp.Core

  @moduletag :fast

  test "accepts only bounded workspace_id, optional timeout, and test_stage_timeout" do
    assert {:ok, input} =
             Core.new(%{
               workspace_id: "ws_opaque",
               timeout: 10_000,
               test_stage_timeout: 20_000
             })

    assert input.workspace_id == "ws_opaque"
    assert input.timeout == 10_000
    assert input.test_stage_timeout == 20_000

    assert {:ok, %{timeout: 300_000, test_stage_timeout: 300_000}} =
             Core.new(%{workspace_id: "ws_opaque"})

    assert {:ok, intensive_ceiling} = Arbor.Shell.spawn_capable_max_timeout_ms(:intensive)
    assert intensive_ceiling == 1_200_000
    standard_ceiling = Arbor.Shell.spawn_capable_max_timeout_ms()
    assert standard_ceiling == 600_000
    stage_ceiling = Core.maximum_test_stage_timeout()
    assert stage_ceiling == 4_200_000
    assert stage_ceiling == Arbor.Actions.cross_app_maximum_test_stage_timeout_ms()

    # Per-op derives from intensive Shell; aggregate stage is a separate Actions max.
    assert Core.maximum_timeout() == intensive_ceiling
    assert Core.maximum_test_stage_timeout() == stage_ceiling
    assert Core.maximum_test_stage_timeout() > Core.maximum_timeout()
    assert Core.maximum_timeout() > standard_ceiling

    assert {:ok, %{timeout: ^intensive_ceiling}} =
             Core.new(%{
               workspace_id: "ws_opaque",
               timeout: Integer.to_string(intensive_ceiling)
             })

    assert {:ok, %{test_stage_timeout: 4_200_000}} =
             Core.new(%{workspace_id: "ws_opaque", test_stage_timeout: "4200000"})

    # Values above the standard ceiling are valid for cross_app (intensive).
    assert {:ok, %{timeout: 900_000}} =
             Core.new(%{workspace_id: "ws_opaque", timeout: 900_000})

    # Aggregate stage may exceed the intensive per-process ceiling.
    assert {:ok, %{test_stage_timeout: 1_800_000}} =
             Core.new(%{workspace_id: "ws_opaque", test_stage_timeout: 1_800_000})

    for invalid <- [
          Integer.to_string(intensive_ceiling + 1),
          "999",
          "01200000",
          "1200000ms",
          " 1200000"
        ] do
      assert {:error, :invalid_timeout} =
               Core.new(%{workspace_id: "ws_opaque", timeout: invalid})
    end

    assert {:error, :invalid_test_stage_timeout} =
             Core.new(%{workspace_id: "ws_opaque", test_stage_timeout: 4_200_001})

    assert {:error, :invalid_test_stage_timeout} =
             Core.new(%{workspace_id: "ws_opaque", test_stage_timeout: "999"})

    assert {:error, :unsupported_parameter} =
             Core.new(%{workspace_id: "ws_opaque", path: "/tmp/repo"})

    assert {:error, :unsupported_parameter} =
             Core.new(%{workspace_id: "ws_opaque", base_commit: "abc"})

    assert {:error, :unsupported_parameter} =
             Core.new(%{workspace_id: "ws_opaque", test_paths: ["apps/a/test"]})

    assert {:error, :invalid_workspace_id} = Core.new(%{})
  end

  test "selects directly changed apps plus every downstream in-umbrella dependent" do
    assert {:ok, graph} =
             Core.build_graph([
               %{dir: "alpha", app: "alpha", deps: []},
               %{dir: "beta", app: "beta", deps: ["alpha"]},
               %{dir: "gamma", app: "gamma", deps: ["beta"]},
               %{dir: "delta", app: "delta", deps: []}
             ])

    assert {:ok, selection} =
             Core.select(["apps/alpha/lib/alpha.ex", "docs/readme.md"], graph)

    assert selection.changed_apps == ["alpha"]
    assert selection.affected_apps == ["alpha", "beta", "gamma"]
    assert selection.test_paths == ["apps/alpha/test", "apps/beta/test", "apps/gamma/test"]
    refute selection.root_wide
    assert "docs/readme.md" in selection.changed_files
  end

  test "root build-impact files select all apps; unrelated docs do not widen app-scoped change" do
    assert {:ok, graph} =
             Core.build_graph([
               %{dir: "alpha", app: "alpha", deps: []},
               %{dir: "beta", app: "beta", deps: ["alpha"]},
               %{dir: "delta", app: "delta", deps: []}
             ])

    assert {:ok, root_selection} = Core.select(["mix.lock", "docs/guide.md"], graph)
    assert root_selection.root_wide
    assert root_selection.changed_apps == []
    assert root_selection.affected_apps == ["alpha", "beta", "delta"]

    assert {:ok, docs_only} = Core.select(["README.md", "docs/guide.md"], graph)
    refute docs_only.root_wide
    assert docs_only.changed_apps == []
    assert docs_only.affected_apps == []
    assert docs_only.test_paths == []

    assert {:ok, scoped} =
             Core.select(["apps/beta/lib/beta.ex", "docs/guide.md"], graph)

    assert scoped.changed_apps == ["beta"]
    # docs do not add other apps
    assert scoped.affected_apps == ["beta"]
  end

  test "fails closed for malformed or ambiguous dependency metadata" do
    assert {:error, :app_dir_name_mismatch} =
             Core.build_graph([%{dir: "alpha", app: "other", deps: []}])

    assert {:error, :duplicate_app_dir} =
             Core.build_graph([
               %{dir: "alpha", app: "alpha", deps: []},
               %{dir: "alpha", app: "alpha", deps: []}
             ])

    assert {:error, {:unknown_in_umbrella_dep, _}} =
             Core.build_graph([
               %{dir: "alpha", app: "alpha", deps: ["missing"]}
             ])

    assert {:ok, graph} =
             Core.build_graph([%{dir: "alpha", app: "alpha", deps: []}])

    assert {:error, {:changed_unknown_app, "ghost"}} =
             Core.select(["apps/ghost/lib/x.ex"], graph)
  end

  test "show assembles domain failure evidence without claiming zero cycles" do
    selection = %{
      changed_files: ["apps/alpha/lib/a.ex"],
      changed_apps: ["alpha"],
      affected_apps: ["alpha", "beta"],
      test_paths: ["apps/alpha/test", "apps/beta/test"],
      root_wide: false
    }

    compile_fail =
      Core.completed_check(%{
        "exit_code" => 1,
        "passed" => false,
        "stdout_excerpt" => "error",
        "stderr_excerpt" => "",
        "stdout_truncated" => false,
        "stderr_truncated" => false,
        "stdout_sha256" => String.duplicate("a", 64),
        "stderr_sha256" => String.duplicate("b", 64)
      })

    evidence =
      Core.show(%{
        selection: selection,
        checks: %{
          compile: compile_fail,
          xref: Core.skipped_check("compile_failed"),
          test_compile: Core.skipped_check("compile_failed"),
          test: Core.skipped_check("compile_failed")
        },
        base_commit: "abc123"
      })

    refute evidence.passed
    assert evidence.reason == "compile_failed"
    assert evidence.xref["status"] == "skipped"
    assert evidence.test_compile["status"] == "skipped"
    assert evidence.test["status"] == "skipped"
    assert evidence.affected_apps == ["alpha", "beta"]
    assert {:ok, _} = Jason.encode(evidence)
  end

  test "show requires test_compile and surfaces test_compile_failed as default reason" do
    selection = %{
      changed_files: ["apps/alpha/lib/a.ex"],
      changed_apps: ["alpha"],
      affected_apps: ["alpha"],
      test_paths: ["apps/alpha/test"],
      root_wide: false
    }

    pass_check =
      Core.completed_check(%{
        "exit_code" => 0,
        "passed" => true,
        "stdout_excerpt" => "ok",
        "stderr_excerpt" => "",
        "stdout_truncated" => false,
        "stderr_truncated" => false,
        "stdout_sha256" => String.duplicate("1", 64),
        "stderr_sha256" => String.duplicate("2", 64)
      })

    test_compile_fail =
      Core.completed_check(
        %{
          "exit_code" => 1,
          "passed" => false,
          "stdout_excerpt" => "test env compile error",
          "stderr_excerpt" => "",
          "stdout_truncated" => false,
          "stderr_truncated" => false,
          "stdout_sha256" => String.duplicate("3", 64),
          "stderr_sha256" => String.duplicate("4", 64)
        },
        reason: "test_compile_failed"
      )

    failed =
      Core.show(%{
        selection: selection,
        checks: %{
          compile: pass_check,
          xref: pass_check,
          test_compile: test_compile_fail,
          test: Core.skipped_check("test_compile_failed")
        },
        base_commit: "abc123"
      })

    refute failed.passed
    assert failed.reason == "test_compile_failed"
    assert failed.test_compile["passed"] == false
    assert failed.test["status"] == "skipped"
    assert failed.test["reason"] == "test_compile_failed"

    # Missing test_compile is not a pass — overall requires the stage.
    missing_stage =
      Core.show(%{
        selection: selection,
        checks: %{
          compile: pass_check,
          xref: pass_check,
          test: pass_check
        },
        base_commit: "abc123"
      })

    refute missing_stage.passed
    assert missing_stage.reason == "test_compile_failed"
    refute missing_stage.test_compile["passed"]

    all_pass =
      Core.show(%{
        selection: selection,
        checks: %{
          compile: pass_check,
          xref: pass_check,
          test_compile: pass_check,
          test: pass_check
        },
        base_commit: "abc123"
      })

    assert all_pass.passed
    assert all_pass.reason == "cross_app_validated"
    assert all_pass.test_compile["passed"]
    assert {:ok, _} = Jason.encode(all_pass)
  end

  test "next_test_step caps each child by min(operation ceiling, remaining aggregate)" do
    assert :complete = Core.next_test_step(10_000, [], 600_000)

    # Two exact files from different apps pack into separate children
    # because the app test root boundary forces a batch reset.
    assert {:ok, [_alpha_batch, _beta_batch] = pair_batches} =
             Core.partition_test_batches([
               "apps/alpha/test/a_test.exs",
               "apps/beta/test/b_test.exs"
             ])

    assert length(pair_batches) == 2

    assert [pair_alpha, pair_beta] = pair_batches
    assert pair_alpha.paths == ["apps/alpha/test/a_test.exs"]
    assert pair_alpha.count == 1
    assert pair_beta.paths == ["apps/beta/test/b_test.exs"]
    assert pair_beta.count == 1

    # Remaining aggregate above operation ceiling still yields the operation cap.
    assert {:run, ^pair_alpha, 30_000, [^pair_beta]} =
             Core.next_test_step(900_000, pair_batches, 30_000)

    # Force two batches (full + final partial) so timeout/rest shapes can be asserted.
    many =
      for i <- 1..(Core.max_test_batch_files() + 1) do
        "apps/alpha/test/f#{String.pad_leading(Integer.to_string(i), 4, "0")}_test.exs"
      end

    assert {:ok, [first, second] = batches} = Core.partition_test_batches(many)
    assert length(batches) == 2
    assert first.count == Core.max_test_batch_files()
    assert second.count == 1

    assert {:run, ^first, 5_000, [^second]} =
             Core.next_test_step(5_000, batches, 600_000)

    assert {:timeout, ^second, []} =
             Core.next_test_step(0, [second], 600_000)

    assert {:timeout, ^first, [^second]} =
             Core.next_test_step(-3, [first, second], 10_000)
  end

  test "next_test_step malformed arguments fail closed rather than completing" do
    assert {:error, {:invalid_test_step_input, meta}} =
             Core.next_test_step("not-int", [%{label: "x"}], 10_000)

    assert is_map(meta)

    assert {:error, {:invalid_test_step_input, _}} =
             Core.next_test_step(10_000, :not_a_list, 10_000)

    assert {:error, {:invalid_test_step_input, _}} =
             Core.next_test_step(10_000, [""], 10_000)

    assert {:error, {:invalid_test_step_input, _}} =
             Core.next_test_step(10_000, [%{not: :a_batch}], 10_000)

    assert {:ok, [batch]} = Core.partition_test_batches(["apps/alpha/test/a_test.exs"])

    assert {:error, {:invalid_test_step_input, _}} =
             Core.next_test_step(10_000, [batch], 0)

    assert {:error, {:invalid_test_step_input, _}} =
             Core.next_test_step(10_000, [batch], -1)

    assert {:error, {:invalid_test_step_input, _}} =
             Core.next_test_step(10_000, [batch], "600000")

    # Empty remaining batches still require a positive operation ceiling.
    assert {:error, {:invalid_test_step_input, _}} =
             Core.next_test_step(10_000, [], 0)
  end

  test "next_test_step rejects forged batch metadata and incoherent remaining lists" do
    assert {:ok, [honest]} = Core.partition_test_batches(["apps/alpha/test/a_test.exs"])
    assert {:run, ^honest, 1_000, []} = Core.next_test_step(1_000, [honest], 1_000)

    forged_digest = %{
      honest
      | inventory_sha256: String.duplicate("a", 64),
        label: "batch-1-of-1-n1-" <> String.duplicate("a", 64)
    }

    assert {:error, {:invalid_test_step_input, _}} =
             Core.next_test_step(10_000, [forged_digest], 10_000)

    forged_label = %{honest | label: "batch-forged"}

    assert {:error, {:invalid_test_step_input, _}} =
             Core.next_test_step(10_000, [forged_label], 10_000)

    # Unnormalized / unbounded path inventory must not pass.
    bad_paths = %{
      honest
      | paths: ["/tmp/evil_test.exs"],
        count: 1,
        inventory_sha256: String.duplicate("b", 64),
        label: "batch-1-of-1-n1-" <> String.duplicate("b", 64)
    }

    assert {:error, {:invalid_test_step_input, _}} =
             Core.next_test_step(10_000, [bad_paths], 10_000)

    many =
      for i <- 1..(Core.max_test_batch_files() + 1) do
        "apps/alpha/test/f#{String.pad_leading(Integer.to_string(i), 4, "0")}_test.exs"
      end

    assert {:ok, [first, second]} = Core.partition_test_batches(many)
    assert first.count == Core.max_test_batch_files()
    assert second.count == 1

    # Remaining list must be a coherent ordered suffix (indices … total).
    assert {:error, {:invalid_test_step_input, _}} =
             Core.next_test_step(10_000, [second, first], 10_000)

    assert {:error, {:invalid_test_step_input, _}} =
             Core.next_test_step(10_000, [first], 10_000)

    assert {:run, ^first, 10_000, [^second]} =
             Core.next_test_step(10_000, [first, second], 10_000)

    assert {:run, ^second, 10_000, []} =
             Core.next_test_step(10_000, [second], 10_000)

    # Valid-looking per-batch metadata cannot hide duplicate or reordered
    # inventory across batch boundaries. Artificially split single-file
    # children are also forged under the multi-file runtime cap (two paths
    # must pack into one child).
    duplicate_across_batches = [
      signed_batch(["apps/alpha/test/a_test.exs"], 1, 2),
      signed_batch(["apps/alpha/test/a_test.exs"], 2, 2)
    ]

    reordered_across_batches = [
      signed_batch(["apps/alpha/test/b_test.exs"], 1, 2),
      signed_batch(["apps/alpha/test/a_test.exs"], 2, 2)
    ]

    underpacked_one_file_each = [
      signed_batch(["apps/alpha/test/a_test.exs"], 1, 2),
      signed_batch(["apps/alpha/test/b_test.exs"], 2, 2)
    ]

    for forged <- [
          duplicate_across_batches,
          reordered_across_batches,
          underpacked_one_file_each
        ] do
      assert {:error, {:invalid_test_step_input, _}} =
               Core.next_test_step(10_000, forged, 10_000)
    end

    correct_pair = [
      signed_batch(
        ["apps/alpha/test/a_test.exs", "apps/alpha/test/b_test.exs"],
        1,
        1
      )
    ]

    assert {:run, correct, 10_000, []} =
             Core.next_test_step(10_000, correct_pair, 10_000)

    assert correct.paths == ["apps/alpha/test/a_test.exs", "apps/alpha/test/b_test.exs"]
    assert correct.count == 2

    # Overpacked multi-file child above the runtime/argv batch cap fails closed.
    overpacked_paths =
      for i <- 1..(Core.max_test_batch_files() + 5) do
        "apps/alpha/test/o#{String.pad_leading(Integer.to_string(i), 4, "0")}_test.exs"
      end

    overpacked_material = Enum.join(overpacked_paths, <<0>>)
    overpacked_sha = :crypto.hash(:sha256, overpacked_material) |> Base.encode16(case: :lower)

    overpacked = %{
      label: "batch-1-of-1-n#{length(overpacked_paths)}-#{overpacked_sha}",
      paths: overpacked_paths,
      index: 1,
      total: 1,
      count: length(overpacked_paths),
      inventory_sha256: overpacked_sha
    }

    assert {:error, {:invalid_test_step_input, _}} =
             Core.next_test_step(10_000, [overpacked], 10_000)

    # Oversized path list even with matching-looking fields fails closed.
    oversized_paths =
      for i <- 1..(Core.max_test_batch_files() + 5) do
        "apps/alpha/test/g#{String.pad_leading(Integer.to_string(i), 4, "0")}_test.exs"
      end

    material = Enum.join(oversized_paths, <<0>>)
    sha = :crypto.hash(:sha256, material) |> Base.encode16(case: :lower)

    oversized = %{
      label: "batch-1-of-1-n#{length(oversized_paths)}-#{sha}",
      paths: oversized_paths,
      index: 1,
      total: 1,
      count: length(oversized_paths),
      inventory_sha256: sha
    }

    assert {:error, {:invalid_test_step_input, _}} =
             Core.next_test_step(10_000, [oversized], 10_000)
  end

  test "normalize_expanded_test_files bounds, sorts, and rejects bad paths" do
    assert {:ok, ["apps/alpha/test/a_test.exs", "apps/alpha/test/nested/b_test.exs"]} =
             Core.normalize_expanded_test_files([
               "apps/alpha/test/nested/b_test.exs",
               "apps/alpha/test/a_test.exs",
               "apps/alpha/test/a_test.exs"
             ])

    assert {:error, :path_escape} =
             Core.normalize_expanded_test_files(["apps/alpha/test/../secret_test.exs"])

    assert {:error, :absolute_test_file_path} =
             Core.normalize_expanded_test_files(["/tmp/apps/alpha/test/a_test.exs"])

    assert {:error, {:not_test_file, "apps/alpha/test/helper.exs"}} =
             Core.normalize_expanded_test_files(["apps/alpha/test/helper.exs"])

    assert {:error, :too_many_test_files} =
             Core.normalize_expanded_test_files(
               for i <- 1..(Core.max_expanded_test_files() + 1) do
                 "apps/alpha/test/f#{i}_test.exs"
               end
             )
  end

  test "partition_test_batches is deterministic, exact-once, ordered, and bound-respecting" do
    assert Core.max_test_batch_runtime_files() == 20

    assert Core.max_test_batch_argv_files() ==
             Arbor.Shell.spawn_capable_max_command_args() - 2

    assert Core.max_test_batch_files() ==
             min(Core.max_test_batch_runtime_files(), Core.max_test_batch_argv_files())

    assert Core.max_test_batch_files() == 20
    assert Core.max_test_batch_arg_bytes() == 65_536

    # Two files pack into one multi-file child while preserving inventory order.
    pair = [
      "apps/alpha/test/a_test.exs",
      "apps/alpha/test/b_test.exs"
    ]

    assert {:ok, [pair_batch] = pair_batches} = Core.partition_test_batches(pair)
    assert pair_batch.paths == pair
    assert pair_batch.count == 2
    assert pair_batch.index == 1
    assert pair_batch.total == 1
    assert pair_batch.label == "batch-1-of-1-n2-#{pair_batch.inventory_sha256}"
    assert byte_size(pair_batch.inventory_sha256) == 64

    expected_pair_sha =
      :crypto.hash(:sha256, Enum.join(pair, <<0>>)) |> Base.encode16(case: :lower)

    assert pair_batch.inventory_sha256 == expected_pair_sha
    assert Enum.flat_map(pair_batches, & &1.paths) == pair
    assert Core.partition_test_batches(pair) == {:ok, pair_batches}

    # Three files from two apps pack into two children (app root boundary).
    files = [
      "apps/alpha/test/a_test.exs",
      "apps/alpha/test/b_test.exs",
      "apps/beta/test/c_test.exs"
    ]

    assert {:ok, [alpha_batch, beta_batch] = three_batches} = Core.partition_test_batches(files)

    assert alpha_batch.paths == [
             "apps/alpha/test/a_test.exs",
             "apps/alpha/test/b_test.exs"
           ]

    assert alpha_batch.count == 2
    assert alpha_batch.index == 1
    assert alpha_batch.total == 2

    assert beta_batch.paths == ["apps/beta/test/c_test.exs"]
    assert beta_batch.count == 1
    assert beta_batch.index == 2
    assert beta_batch.total == 2

    assert alpha_batch.label =~ ~r/^batch-1-of-2-n2-[0-9a-f]{64}$/
    assert beta_batch.label =~ ~r/^batch-2-of-2-n1-[0-9a-f]{64}$/
    assert byte_size(alpha_batch.inventory_sha256) == 64
    assert byte_size(beta_batch.inventory_sha256) == 64
    assert Enum.flat_map(three_batches, & &1.paths) == files
    assert Core.partition_test_batches(files) == {:ok, three_batches}

    # Every path exactly once across batches; sorted order preserved; final partial.
    many =
      for i <- 1..(Core.max_test_batch_files() + 3) do
        "apps/alpha/test/f#{String.pad_leading(Integer.to_string(i), 4, "0")}_test.exs"
      end

    assert length(many) == 23
    assert {:ok, batches} = Core.partition_test_batches(many)
    assert length(batches) == 2
    assert Enum.at(batches, 0).count == Core.max_test_batch_files()
    assert Enum.at(batches, 1).count == 3
    assert Enum.flat_map(batches, & &1.paths) == many
    assert Enum.all?(batches, fn b -> b.paths != [] end)

    for b <- batches do
      arg_bytes = Enum.reduce(b.paths, 0, fn p, acc -> acc + byte_size(p) + 1 end)
      assert length(b.paths) == b.count
      assert length(b.paths) <= Core.max_test_batch_files()
      assert length(b.paths) <= Core.max_test_batch_runtime_files()
      assert arg_bytes <= Core.max_test_batch_arg_bytes()
      assert b.label == "batch-#{b.index}-of-#{b.total}-n#{b.count}-#{b.inventory_sha256}"
      assert b.label =~ ~r/^batch-\d+-of-\d+-n\d+-[0-9a-f]{64}$/
    end

    # Uneven inventories always retain a non-empty final partial batch.
    for remainder <- [1, 5, 11] do
      uneven =
        for i <- 1..(Core.max_test_batch_files() + remainder) do
          "apps/alpha/test/u#{String.pad_leading(Integer.to_string(i), 4, "0")}_test.exs"
        end

      assert {:ok, uneven_batches} = Core.partition_test_batches(uneven)
      assert length(uneven_batches) == 2
      assert Enum.at(uneven_batches, 0).count == Core.max_test_batch_files()
      assert Enum.at(uneven_batches, 1).count == remainder
      assert Enum.flat_map(uneven_batches, & &1.paths) == uneven
      assert Enum.all?(uneven_batches, &(&1.paths != []))
    end

    # Byte-heavy valid paths still respect both file-count and argument-byte ceilings.
    # Build paths that each cost ~900 bytes so packing never exceeds 64 KiB.
    long_stem = String.duplicate("p", 860)

    heavy =
      for i <- 1..80 do
        "apps/alpha/test/#{long_stem}#{String.pad_leading(Integer.to_string(i), 3, "0")}_test.exs"
      end

    assert {:ok, heavy_batches} = Core.partition_test_batches(heavy)
    assert length(heavy_batches) == 4
    assert Enum.at(heavy_batches, 0).count == Core.max_test_batch_files()
    assert Enum.at(heavy_batches, 3).count == Core.max_test_batch_files()
    assert Enum.flat_map(heavy_batches, & &1.paths) == heavy

    for b <- heavy_batches do
      arg_bytes = Enum.reduce(b.paths, 0, fn p, acc -> acc + byte_size(p) + 1 end)
      assert length(b.paths) == b.count
      assert length(b.paths) <= Core.max_test_batch_files()
      assert length(b.paths) <= Core.max_test_batch_runtime_files()
      assert arg_bytes <= Core.max_test_batch_arg_bytes()
      assert b.count == length(b.paths)
    end

    # A single normalized path always fits and forms one batch.
    one = ["apps/alpha/test/solo_test.exs"]
    assert {:ok, [solo]} = Core.partition_test_batches(one)
    assert solo.paths == one
    assert solo.total == 1
    assert solo.count == 1
  end

  test "partition_test_batches representative inventories are exact-once and deterministic" do
    assert Core.max_test_batch_runtime_files() == 20
    assert Core.max_test_batch_files() == 20

    for {size, expected_batches} <- [{40, 2}, {511, 26}, {707, 36}] do
      inventory =
        for i <- 1..size do
          "apps/alpha/test/r#{String.pad_leading(Integer.to_string(i), 5, "0")}_test.exs"
        end

      assert length(inventory) == size
      assert {:ok, batches} = Core.partition_test_batches(inventory)
      assert length(batches) == expected_batches
      assert Enum.flat_map(batches, & &1.paths) == inventory
      assert Enum.all?(batches, fn b -> b.paths != [] end)
      assert Enum.sum(Enum.map(batches, & &1.count)) == size

      # Full batches then a final partial when size is not an exact multiple.
      full_batches = div(size, Core.max_test_batch_files())
      remainder = rem(size, Core.max_test_batch_files())

      assert Enum.take(batches, full_batches)
             |> Enum.all?(&(&1.count == Core.max_test_batch_files()))

      if remainder == 0 do
        assert length(batches) == full_batches
      else
        assert length(batches) == full_batches + 1
        assert List.last(batches).count == remainder
        assert List.last(batches).paths != []
      end

      for b <- batches do
        arg_bytes = Enum.reduce(b.paths, 0, fn p, acc -> acc + byte_size(p) + 1 end)
        assert length(b.paths) <= Core.max_test_batch_files()
        assert length(b.paths) <= Core.max_test_batch_runtime_files()
        assert length(["test", "--" | b.paths]) <= Arbor.Shell.spawn_capable_max_command_args()
        assert arg_bytes <= Core.max_test_batch_arg_bytes()
        assert b.total == expected_batches
        assert b.label == "batch-#{b.index}-of-#{b.total}-n#{b.count}-#{b.inventory_sha256}"

        expected_sha =
          :crypto.hash(:sha256, Enum.join(b.paths, <<0>>)) |> Base.encode16(case: :lower)

        assert b.inventory_sha256 == expected_sha
      end

      # Deterministic repeated output for the same ordered inventory.
      assert Core.partition_test_batches(inventory) == {:ok, batches}
      assert Core.partition_test_batches(inventory) == {:ok, batches}
    end
  end

  test "partition_test_batches fails closed on malformed or non-normalized input" do
    assert {:error, :invalid_test_batch_input} = Core.partition_test_batches(:not_a_list)

    assert {:error, :unsorted_or_duplicate_test_files} =
             Core.partition_test_batches([
               "apps/alpha/test/b_test.exs",
               "apps/alpha/test/a_test.exs"
             ])

    assert {:error, :unsorted_or_duplicate_test_files} =
             Core.partition_test_batches([
               "apps/alpha/test/a_test.exs",
               "apps/alpha/test/a_test.exs"
             ])

    assert {:error, :path_escape} =
             Core.partition_test_batches(["apps/alpha/test/../x_test.exs"])

    assert {:error, :absolute_test_file_path} =
             Core.partition_test_batches(["/tmp/apps/alpha/test/a_test.exs"])

    assert {:error, {:not_test_file, "apps/alpha/test/helper.exs"}} =
             Core.partition_test_batches(["apps/alpha/test/helper.exs"])

    # Whitespace-trimmed form differs from raw input → non-normalized.
    assert {:error, {:non_normalized_test_file, " apps/alpha/test/a_test.exs"}} =
             Core.partition_test_batches([" apps/alpha/test/a_test.exs"])

    assert {:ok, []} = Core.partition_test_batches([])
  end

  test "classify_app_test_result preserves tests_failed vs tests_timed_out" do
    pass =
      Core.classify_app_test_result("apps/alpha/test", %{
        "exit_code" => 0,
        "passed" => true,
        "stdout_excerpt" => "ok",
        "stderr_excerpt" => "",
        "stdout_truncated" => false,
        "stderr_truncated" => false,
        "stdout_sha256" => String.duplicate("1", 64),
        "stderr_sha256" => String.duplicate("2", 64)
      })

    assert pass.passed
    assert pass.reason == nil
    refute pass.timed_out

    fail =
      Core.classify_app_test_result("apps/beta/test", %{
        "exit_code" => 1,
        "passed" => false,
        "stdout_excerpt" => "1 failure",
        "stderr_excerpt" => "",
        "stdout_truncated" => false,
        "stderr_truncated" => false,
        "stdout_sha256" => String.duplicate("3", 64),
        "stderr_sha256" => String.duplicate("4", 64)
      })

    refute fail.passed
    assert fail.reason == "tests_failed"

    timed =
      Core.classify_app_test_result(
        "apps/gamma/test",
        %{
          "exit_code" => 137,
          "passed" => false,
          "stdout_excerpt" => "partial",
          "stderr_excerpt" => "",
          "stdout_truncated" => false,
          "stderr_truncated" => false,
          "stdout_sha256" => String.duplicate("5", 64),
          "stderr_sha256" => String.duplicate("6", 64)
        },
        timed_out: true
      )

    refute timed.passed
    assert timed.timed_out
    assert timed.reason == "tests_timed_out"
  end

  test "exact timeout shape vs text-only timeout stays ordinary failure" do
    # Text containing "timeout" must NOT be treated as a stage/process timeout.
    text_only =
      Core.classify_app_test_result("apps/alpha/test", %{
        "exit_code" => 1,
        "passed" => false,
        "stdout_excerpt" => "error: connection timeout waiting for lock",
        "stderr_excerpt" => "timeout in fixture setup",
        "stdout_truncated" => false,
        "stderr_truncated" => false,
        "stdout_sha256" => String.duplicate("7", 64),
        "stderr_sha256" => String.duplicate("8", 64)
      })

    refute text_only.passed
    refute text_only.timed_out
    assert text_only.reason == "tests_failed"

    assert Core.runner_timed_out?(%{
             exit_code: 1,
             stdout: "timeout",
             stderr: "timeout",
             timed_out: false
           }) == false

    assert Core.runner_timed_out?(%{exit_code: 137, timed_out: true}) == true
    assert Core.runner_timed_out?(%{"timed_out" => true, "exit_code" => 1}) == true
    assert Core.runner_timed_out?(%{reason: "timeout"}) == false
    assert Core.runner_timed_out?("timeout") == false

    assert Core.child_timed_out?(false, 1) == false
    assert Core.child_timed_out?(false, 0) == true
    assert Core.child_timed_out?(false, -5) == true
    assert Core.child_timed_out?(true, 100) == true
  end

  test "feedback_from_result hashes raw bytes and produces JSON-safe byte-bounded excerpts" do
    invalid = "hello" <> <<0xFF, 0xFE>> <> "world"
    expected_hash = :crypto.hash(:sha256, invalid) |> Base.encode16(case: :lower)

    feedback =
      Core.feedback_from_result(%{
        exit_code: 0,
        stdout: invalid,
        stderr: ""
      })

    assert feedback["passed"]
    assert feedback["stdout_sha256"] == expected_hash
    assert String.valid?(feedback["stdout_excerpt"])
    assert String.contains?(feedback["stdout_excerpt"], "hello")
    assert String.contains?(feedback["stdout_excerpt"], "world")
    # Invalid bytes replaced; raw hash still deterministic over the original binary.
    refute String.contains?(feedback["stdout_excerpt"], <<0xFF>>)
    assert {:ok, _} = Jason.encode(feedback)
    assert {:ok, _} = Jason.encode!(feedback) |> Jason.decode()

    # Multibyte: bound by bytes without splitting UTF-8 codepoints (é is 2 bytes).
    multibyte = String.duplicate("é", 1_500)
    assert byte_size(multibyte) == 3_000

    {excerpt, truncated} = Core.bound_output_excerpt(multibyte)
    assert truncated
    assert String.valid?(excerpt)
    assert byte_size(excerpt) <= Core.max_output_excerpt_bytes()
    assert String.contains?(excerpt, "...[omitted]...")
    # Every remaining codepoint must be complete "é" or the ASCII marker.
    without_marker = String.replace(excerpt, "\n...[omitted]...\n", "")
    assert String.valid?(without_marker)
    assert rem(byte_size(without_marker), 2) == 0
    assert without_marker == String.duplicate("é", div(byte_size(without_marker), 2))
  end

  @tag timeout: 15_000
  test "security regression: large invalid-byte stream uses bounded window repair" do
    # Regression: quadratic/full-stream invalid UTF-8 repair + whole-stream
    # suffix enumeration for a ~2 KB excerpt must not run over multi-100KB
    # process output. Hash the complete raw stream once; repair only bounded
    # head/tail windows.
    prefix = "HEAD-OK-"
    suffix = "-TAIL-OK"
    invalid_mid = :binary.copy(<<0xFF>>, 1_000_000)
    raw = prefix <> invalid_mid <> suffix
    assert byte_size(raw) >= 1_000_000

    expected_hash = :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)

    task =
      Task.async(fn ->
        Core.feedback_from_result(%{
          exit_code: 1,
          stdout: raw,
          stderr: ""
        })
      end)

    feedback =
      case Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        nil -> flunk("excerpt generation exceeded the bounded-work budget")
        {:exit, reason} -> flunk("excerpt generation exited: #{inspect(reason)}")
      end

    assert feedback["stdout_sha256"] == expected_hash
    assert feedback["stdout_truncated"] == true
    assert String.valid?(feedback["stdout_excerpt"])
    assert byte_size(feedback["stdout_excerpt"]) <= Core.max_output_excerpt_bytes()
    assert String.contains?(feedback["stdout_excerpt"], "HEAD-OK-")
    assert String.contains?(feedback["stdout_excerpt"], "-TAIL-OK")
    assert String.contains?(feedback["stdout_excerpt"], "...[omitted]...")
    refute String.contains?(feedback["stdout_excerpt"], <<0xFF>>)

    assert {:ok, json} = Jason.encode(feedback)
    assert {:ok, decoded} = Jason.decode(json)
    assert decoded["stdout_sha256"] == expected_hash
    assert is_binary(decoded["stdout_excerpt"])
  end

  test "aggregate_test_check bounds excerpts, hashes paths+process digests, and keeps reasons stable" do
    alpha =
      Core.classify_app_test_result("apps/alpha/test", %{
        "exit_code" => 0,
        "passed" => true,
        "stdout_excerpt" => "alpha-ok",
        "stderr_excerpt" => "",
        "stdout_truncated" => false,
        "stderr_truncated" => false,
        "stdout_sha256" => String.duplicate("a", 64),
        "stderr_sha256" => String.duplicate("b", 64)
      })

    beta =
      Core.classify_app_test_result("apps/beta/test", %{
        "exit_code" => 1,
        "passed" => false,
        "stdout_excerpt" => "beta-fail",
        "stderr_excerpt" => "err",
        "stdout_truncated" => false,
        "stderr_truncated" => false,
        "stdout_sha256" => String.duplicate("c", 64),
        "stderr_sha256" => String.duplicate("d", 64)
      })

    aggregated = Core.aggregate_test_check([alpha, beta])

    refute aggregated["passed"]
    assert aggregated["reason"] == "tests_failed"
    assert aggregated["exit_code"] == 1
    assert aggregated["status"] == "completed"
    assert String.contains?(aggregated["stdout_excerpt"], "[apps/alpha/test]")
    assert String.contains?(aggregated["stdout_excerpt"], "[apps/beta/test]")
    assert String.contains?(aggregated["stdout_excerpt"], "beta-fail")
    assert byte_size(aggregated["stdout_excerpt"]) <= Core.max_aggregate_excerpt()
    refute aggregated["stdout_truncated"]

    expected_stdout_hash =
      :crypto.hash(
        :sha256,
        "apps/alpha/test\n" <>
          String.duplicate("a", 64) <>
          "\n" <>
          "apps/beta/test\n" <> String.duplicate("c", 64)
      )
      |> Base.encode16(case: :lower)

    assert aggregated["stdout_sha256"] == expected_stdout_hash

    expected_stderr_hash =
      :crypto.hash(
        :sha256,
        "apps/alpha/test\n" <>
          String.duplicate("b", 64) <>
          "\n" <>
          "apps/beta/test\n" <> String.duplicate("d", 64)
      )
      |> Base.encode16(case: :lower)

    assert aggregated["stderr_sha256"] == expected_stderr_hash

    # Deterministic: same inputs → same aggregate
    assert Core.aggregate_test_check([alpha, beta]) == aggregated

    # Over-budget combined excerpts are re-bounded independent of app count;
    # per-process hashes still cover every completed path.
    huge_alpha = %{alpha | stdout_excerpt: String.duplicate("A", 1_500), stdout_truncated: true}
    huge_beta = %{beta | stdout_excerpt: String.duplicate("B", 1_500)}
    truncated = Core.aggregate_test_check([huge_alpha, huge_beta])
    assert byte_size(truncated["stdout_excerpt"]) <= Core.max_aggregate_excerpt()
    assert truncated["stdout_truncated"] == true
    assert truncated["stdout_sha256"] == expected_stdout_hash
    assert String.contains?(truncated["stdout_excerpt"], "...[omitted]...")
    assert String.valid?(truncated["stdout_excerpt"])
    assert {:ok, _} = Jason.encode(truncated)

    exhausted = Core.budget_exhausted_result("apps/gamma/test")
    timed_out = Core.aggregate_test_check([alpha, exhausted])
    refute timed_out["passed"]
    assert timed_out["reason"] == "tests_timed_out"
    assert String.contains?(timed_out["stdout_excerpt"], "apps/gamma/test")
    assert String.contains?(timed_out["stdout_excerpt"], "budget exhausted")
    # Earlier successful evidence preserved.
    assert String.contains?(timed_out["stdout_excerpt"], "alpha-ok")

    all_pass = Core.aggregate_test_check([alpha])
    assert all_pass["passed"]
    assert all_pass["reason"] == nil
    assert all_pass["exit_code"] == 0

    assert Core.aggregate_test_check([])["reason"] == "no_existing_test_dirs"
    assert Core.aggregate_test_check([])["passed"]
  end

  test "downstream selection is unchanged by per-app test aggregation helpers" do
    assert {:ok, graph} =
             Core.build_graph([
               %{dir: "alpha", app: "alpha", deps: []},
               %{dir: "beta", app: "beta", deps: ["alpha"]},
               %{dir: "gamma", app: "gamma", deps: ["beta"]}
             ])

    assert {:ok, selection} = Core.select(["apps/alpha/lib/alpha.ex"], graph)
    assert selection.affected_apps == ["alpha", "beta", "gamma"]
    assert selection.test_paths == ["apps/alpha/test", "apps/beta/test", "apps/gamma/test"]
  end

  @tag timeout: 15_000
  test "failure-aware excerpt centers the first ExUnit failure block under multi-KB noise" do
    # Regression: under head/tail-only windowing, a multi-KB ExUnit stream
    # whose only failure block sits in the middle discarded the entire
    # diagnostic — the resumed worker saw only seed output and the final
    # "N tests, M failures" count, and had to rerun the suite to find the
    # actual assertion. The failure-aware excerpt centers the byte budget
    # on the first stable diagnostic anchor.
    head_context =
      "Running tests via mix...\n" <>
        "Excluding tags: [:skip]\n" <>
        "Including tags: [:focus]\n" <>
        "Seed: 987654321\n" <>
        "Max cases: 16\n"

    passing_before =
      Enum.map_join(1..300, fn i -> ". test passing line #{i} ok\n" end)

    failure_block =
      "\n\n" <>
        "  1) test important widget computes correct total (MyApp.WidgetsTest)\n" <>
        "     apps/my_app/test/widgets_test.exs:42:1\n" <>
        "     code: assert Widget.total(:a, :b) == 42\n" <>
        "     lhs:  41\n" <>
        "     rhs:  42\n" <>
        "     stacktrace:\n" <>
        "       apps/my_app/lib/widgets.ex:88: MyApp.Widgets.total/2\n" <>
        "       (elixir 1.19) lib/code.ex:430: Code.require_file/2\n"

    passing_after =
      Enum.map_join(1..200, fn i -> ". test trailing pass #{i} ok\n" end)

    summary = "\n\n312 tests, 1 failure, 5 skipped\n"

    raw = head_context <> passing_before <> failure_block <> passing_after <> summary

    # Sanity: stream well over the 2 KB excerpt budget, and the failure
    # anchor sits well outside both the old head and tail halves.
    assert byte_size(raw) > Core.max_output_excerpt_bytes() * 5

    {anchor_offset, _} = :binary.match(raw, "  1) test important widget")

    old_half = div(Core.max_output_excerpt_bytes() - 17, 2)
    assert anchor_offset > old_half
    assert anchor_offset < byte_size(raw) - old_half

    feedback =
      Core.feedback_from_result(%{
        exit_code: 1,
        stdout: raw,
        stderr: ""
      })

    excerpt = feedback["stdout_excerpt"]

    # Exit code remains the sole pass/fail authority.
    assert feedback["exit_code"] == 1
    refute feedback["passed"]
    assert feedback["stdout_truncated"]

    # Raw hash covers the complete original bytes regardless of excerpt choice.
    assert feedback["stdout_sha256"] ==
             :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)

    # Head window preserves ExUnit seed/concurrency context.
    assert String.contains?(excerpt, "Seed: 987654321")
    assert String.contains?(excerpt, "Max cases: 16")

    # Middle window preserves the first numbered failure block and its
    # assertion details — these were the bytes lost under head/tail-only.
    assert String.contains?(excerpt, "1) test important widget computes correct total")
    assert String.contains?(excerpt, "MyApp.WidgetsTest")
    assert String.contains?(excerpt, "Widget.total(:a, :b) == 42")
    assert String.contains?(excerpt, "lhs:  41")
    assert String.contains?(excerpt, "rhs:  42")
    assert String.contains?(excerpt, "apps/my_app/lib/widgets.ex:88")

    # Tail window preserves the final summary line.
    assert String.contains?(excerpt, "312 tests, 1 failure, 5 skipped")

    # Omission markers between non-contiguous segments.
    assert String.contains?(excerpt, "...[omitted]...")

    # Valid UTF-8, JSON-safe, exact byte bound.
    assert String.valid?(excerpt)
    assert byte_size(excerpt) <= Core.max_output_excerpt_bytes()
    assert {:ok, _} = Jason.encode(%{"body" => excerpt})
  end

  test "compilation-error and uncaught-exception anchors are also centered" do
    # Mix compilation banner is a recognized anchor.
    raw_compile =
      "Compiling apps/foo/lib/foo.ex...\n" <>
        String.duplicate("noise compile line\n", 300) <>
        "== Compilation error in file apps/foo/lib/foo.ex ==\n" <>
        "    ** (CompileError) apps/foo/lib/foo.ex:12: undefined function do_thing/0\n" <>
        String.duplicate("trailing noise compile line\n", 200) <>
        "\n\n** (Mix) Compile error\n"

    fb_compile = Core.feedback_from_result(%{exit_code: 1, stdout: raw_compile, stderr: ""})

    assert fb_compile["stdout_truncated"]
    assert String.contains?(fb_compile["stdout_excerpt"], "== Compilation error")
    assert String.contains?(fb_compile["stdout_excerpt"], "CompileError")
    assert String.contains?(fb_compile["stdout_excerpt"], "do_thing/0")

    # Uncaught exception heading is a recognized anchor.
    raw_exc =
      "Starting task...\n" <>
        String.duplicate("noise exc line\n", 300) <>
        "** (RuntimeError) boom widget failed unexpectedly\n" <>
        "    (foo 0.1.0) lib/foo/runtime.ex:7: Foo.Runtime.run/1\n" <>
        String.duplicate("trailing noise exc line\n", 200)

    fb_exc = Core.feedback_from_result(%{exit_code: 1, stdout: raw_exc, stderr: ""})

    assert fb_exc["stdout_truncated"]
    assert String.contains?(fb_exc["stdout_excerpt"], "** (RuntimeError) boom widget failed")
    assert String.contains?(fb_exc["stdout_excerpt"], "Foo.Runtime.run/1")

    for fb <- [fb_compile, fb_exc] do
      assert String.valid?(fb["stdout_excerpt"])
      assert byte_size(fb["stdout_excerpt"]) <= Core.max_output_excerpt_bytes()
    end
  end

  test "no diagnostic anchor falls back to the established head/tail window" do
    # Large failure output without a stable anchor must still be bounded and
    # use the original head/tail behavior; the failure-aware path does not
    # invent diagnostics from localized prose.
    raw =
      "HEAD-LINE-START\n" <>
        String.duplicate("noise line without anchor marker\n", 400) <>
        "TAIL-LINE-END\n"

    assert byte_size(raw) > Core.max_output_excerpt_bytes()

    feedback =
      Core.feedback_from_result(%{
        exit_code: 1,
        stdout: raw,
        stderr: ""
      })

    excerpt = feedback["stdout_excerpt"]

    assert feedback["stdout_truncated"]
    assert String.contains?(excerpt, "HEAD-LINE-START")
    assert String.contains?(excerpt, "TAIL-LINE-END")
    assert String.contains?(excerpt, "...[omitted]...")
    refute String.contains?(excerpt, "1) test")
    assert String.valid?(excerpt)
    assert byte_size(excerpt) <= Core.max_output_excerpt_bytes()
  end

  test "aggregate_test_check preserves a failed child diagnostic under successful sibling noise" do
    # Many large successful siblings before and after a small failed child
    # would crowd the failure out of a uniform head/tail window. The
    # failure-aware aggregate centers the byte budget on the failed child's
    # diagnostic so the resumed worker sees it without rerunning the suite.
    success_body = String.duplicate("pass line ok\n", 200)

    misleading_success_body =
      String.duplicate("expected fixture output\n", 30) <>
        "** (RuntimeError) expected exception fixture from a passing test\n" <>
        String.duplicate("pass line after fixture\n", 120)

    failed_body =
      "  1) test important feature works (MyApp.FeatureTest)\n" <>
        "     apps/my_app/test/feature_test.exs:7:1\n" <>
        "     code: assert Feature.run() == :ok\n" <>
        "     lhs:  :error\n" <>
        "     rhs:  :ok\n" <>
        "     stacktrace:\n" <>
        "       apps/my_app/lib/feature.ex:30: MyApp.Feature.run/0\n"

    success_a =
      Core.classify_app_test_result("apps/alpha/test", %{
        "exit_code" => 0,
        "passed" => true,
        "stdout_excerpt" => misleading_success_body,
        "stderr_excerpt" => "",
        "stdout_truncated" => false,
        "stderr_truncated" => false,
        "stdout_sha256" => String.duplicate("a", 64),
        "stderr_sha256" => String.duplicate("b", 64)
      })

    success_b =
      Core.classify_app_test_result("apps/beta/test", %{
        "exit_code" => 0,
        "passed" => true,
        "stdout_excerpt" => success_body,
        "stderr_excerpt" => "",
        "stdout_truncated" => false,
        "stderr_truncated" => false,
        "stdout_sha256" => String.duplicate("c", 64),
        "stderr_sha256" => String.duplicate("d", 64)
      })

    failed =
      Core.classify_app_test_result("apps/gamma/test", %{
        "exit_code" => 1,
        "passed" => false,
        "stdout_excerpt" => failed_body,
        "stderr_excerpt" => "",
        "stdout_truncated" => false,
        "stderr_truncated" => false,
        "stdout_sha256" => String.duplicate("e", 64),
        "stderr_sha256" => String.duplicate("f", 64)
      })

    aggregated = Core.aggregate_test_check([success_a, failed, success_b])

    refute aggregated["passed"]
    assert aggregated["reason"] == "tests_failed"
    assert aggregated["exit_code"] == 1

    excerpt = aggregated["stdout_excerpt"]

    # Deterministic batch label retained.
    assert String.contains?(excerpt, "[apps/gamma/test]")

    # Failed child's diagnostic survives under successful-sibling noise.
    assert String.contains?(excerpt, "1) test important feature works")
    assert String.contains?(excerpt, "Feature.run() == :ok")
    assert String.contains?(excerpt, "apps/my_app/lib/feature.ex:30")
    refute String.contains?(excerpt, "expected exception fixture from a passing test")

    # Aggregate byte ceiling, UTF-8 safety, and omission markers preserved.
    assert byte_size(excerpt) <= Core.max_aggregate_excerpt()
    assert String.valid?(excerpt)
    assert aggregated["stdout_truncated"]
    assert String.contains?(excerpt, "...[omitted]...")
    assert {:ok, _} = Jason.encode(aggregated)
  end

  test "app root boundary: full 20-slot batch cannot absorb next app's first file" do
    max = Core.max_test_batch_files()

    alpha_files =
      for i <- 1..max,
          do: "apps/alpha/test/f#{String.pad_leading(Integer.to_string(i), 4, "0")}_test.exs"

    all_files = alpha_files ++ ["apps/beta/test/first_test.exs"]

    assert {:ok, batches} = Core.partition_test_batches(all_files)
    assert length(batches) == 2
    alpha_batch = List.first(batches)
    beta_batch = List.last(batches)
    assert alpha_batch.count == max
    assert alpha_batch.paths == alpha_files
    assert alpha_batch.index == 1
    assert alpha_batch.total == 2
    assert beta_batch.count == 1
    assert beta_batch.paths == ["apps/beta/test/first_test.exs"]
    assert beta_batch.index == 2
    assert beta_batch.total == 2
    assert Enum.flat_map(batches, & &1.paths) == all_files
  end

  test "app root boundary: small adjacent app inventories produce separate batches" do
    files = [
      "apps/alpha/test/a_test.exs",
      "apps/beta/test/b_test.exs",
      "apps/gamma/test/c_test.exs"
    ]

    assert {:ok, batches} = Core.partition_test_batches(files)
    assert length(batches) == 3
    assert Enum.map(batches, & &1.count) == [1, 1, 1]

    assert Enum.map(batches, & &1.paths) == [
             ["apps/alpha/test/a_test.exs"],
             ["apps/beta/test/b_test.exs"],
             ["apps/gamma/test/c_test.exs"]
           ]

    for batch <- batches, do: assert(batch.index <= batch.total)
    total = List.first(batches).total
    for batch <- batches, do: assert(batch.total == total)
    assert total == 3
  end

  test "app root boundary: no loss, duplication, or reordering across batches" do
    alpha = for i <- 1..8, do: "apps/alpha/test/a#{i}_test.exs"
    beta = for i <- 1..12, do: "apps/beta/test/b#{i}_test.exs"
    gamma = for i <- 1..3, do: "apps/gamma/test/g#{i}_test.exs"
    all = (alpha ++ beta ++ gamma) |> Enum.sort()

    assert {:ok, batches} = Core.partition_test_batches(all)
    all_paths = Enum.flat_map(batches, & &1.paths)
    assert all_paths == all
    assert length(all_paths) == length(all)
    assert length(Enum.uniq(all_paths)) == length(all_paths)
  end

  test "app root boundary: byte and count packing still works within one root" do
    alpha_heavy =
      for i <- 1..40,
          do: "apps/alpha/test/heavy#{String.pad_leading(Integer.to_string(i), 3, "0")}_test.exs"

    assert {:ok, batches} = Core.partition_test_batches(alpha_heavy)
    assert length(batches) == 2
    all_paths = Enum.flat_map(batches, & &1.paths)
    assert all_paths == alpha_heavy

    for batch <- batches do
      assert batch.count == length(batch.paths)
      assert batch.count <= Core.max_test_batch_files()
      arg_bytes = Enum.reduce(batch.paths, 0, fn p, acc -> acc + byte_size(p) + 1 end)
      assert arg_bytes <= Core.max_test_batch_arg_bytes()
    end
  end

  test "app root boundary: forged cross-root remaining batch is rejected" do
    alpha_files = for i <- 1..3, do: "apps/alpha/test/a#{i}_test.exs"
    assert {:ok, batches} = Core.partition_test_batches(alpha_files)
    assert length(batches) == 1
    [real] = batches

    forged_cross_root = %{
      real
      | paths: real.paths ++ ["apps/beta/test/evil_test.exs"],
        count: length(real.paths) + 1
    }

    material = Enum.join(forged_cross_root.paths, <<0>>)

    forged_cross_root = %{
      forged_cross_root
      | inventory_sha256: :crypto.hash(:sha256, material) |> Base.encode16(case: :lower)
    }

    forged_cross_root = %{
      forged_cross_root
      | label: "batch-1-of-1-n#{forged_cross_root.count}-#{forged_cross_root.inventory_sha256}"
    }

    assert {:error, {:invalid_test_step_input, _}} =
             Core.next_test_step(10_000, [forged_cross_root], 10_000)

    forged_split = [
      signed_batch(["apps/alpha/test/a1_test.exs", "apps/alpha/test/a2_test.exs"], 1, 2),
      signed_batch(["apps/alpha/test/a3_test.exs", "apps/beta/test/evil_test.exs"], 2, 2)
    ]

    assert {:error, {:invalid_test_step_input, _}} =
             Core.next_test_step(10_000, forged_split, 10_000)
  end

  defp signed_batch(paths, index, total) do
    digest =
      paths
      |> Enum.join(<<0>>)
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    count = length(paths)

    %{
      label: "batch-#{index}-of-#{total}-n#{count}-#{digest}",
      paths: paths,
      index: index,
      total: total,
      count: count,
      inventory_sha256: digest
    }
  end
end
