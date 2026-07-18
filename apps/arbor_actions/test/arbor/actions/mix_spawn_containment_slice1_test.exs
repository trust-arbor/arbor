defmodule Arbor.Actions.MixSpawnContainmentSlice1Test do
  @moduledoc """
  Focused Slice 1 tests: closed Mix wrapper, mandatory owner-issued workspace
  boundary, revision-isolated projections, private modes, enforcing cleanup,
  dependency isolation, total cleanup diagnostics, and tree-binding against
  validation-time mutation. Does not claim process-tree or platform containment
  (Slice 2).

  Contained Mix uses Shell `execute_spawn_capable/3` (Apple Container). These
  Slice 1 tests keep TestMixShell as a fixture double for lease/projection
  construction and do not require a provisioned host container.
  """

  use Arbor.Actions.ActionCase, async: false

  alias Arbor.Actions.Coding.WorkspaceLeaseRegistry
  alias Arbor.Actions.Mix, as: MixAction
  alias Arbor.Common.SafePath

  @moduletag :fast

  setup_all do
    case Process.whereis(Arbor.Shell.ExecutionRegistry) do
      nil -> {:ok, _} = Application.ensure_all_started(:arbor_shell)
      _pid -> :ok
    end

    previous_shell_module = Application.get_env(:arbor_actions, :mix_shell_module)
    Application.put_env(:arbor_actions, :mix_shell_module, Arbor.Actions.TestMixShell)

    on_exit(fn ->
      restore_env(:arbor_actions, :mix_shell_module, previous_shell_module)
    end)

    :ok
  end

  setup do
    Arbor.Actions.TestLinuxBaselineMaterializer.reset_seams()
    :ok
  end

  # ── Metadata construction (test-double shell; no platform claims) ──

  test "resolve_mix_wrapper returns exact executable identity from code roots" do
    assert {:ok, wrapper} = MixAction.resolve_mix_wrapper()
    assert Path.type(wrapper) == :absolute
    assert Path.basename(wrapper) == "mix"
    assert File.regular?(wrapper)
    assert executable?(wrapper)

    previous = Application.get_env(:arbor_actions, :mix_wrapper_path)

    try do
      Application.put_env(:arbor_actions, :mix_wrapper_path, "/usr/bin/mix")
      assert {:ok, ^wrapper} = MixAction.resolve_mix_wrapper()
    after
      restore_env(:arbor_actions, :mix_wrapper_path, previous)
    end
  end

  test "resolve_mix_wrapper fails closed for umbrella root without executable wrapper" do
    root =
      Path.join(System.tmp_dir!(), "fake-umbrella-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "apps"))
    File.write!(Path.join(root, "mix.exs"), "defmodule Fake.MixProject do\nend\n")
    File.mkdir_p!(Path.join(root, "bin"))
    File.write!(Path.join(root, "bin/mix"), "#!/bin/sh\necho fake\n")
    File.chmod!(Path.join(root, "bin/mix"), 0o644)
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:error, :mix_wrapper_unavailable} =
             MixAction.resolve_mix_wrapper_from_anchors([root])
  end

  test "runtime_roots derive from loaded BEAM, not caller opts" do
    assert {:ok, roots} = MixAction.runtime_roots()
    assert File.exists?(Path.join(roots.erlang_root, "bin/erl"))
    assert executable?(Path.join(roots.elixir_root, "bin/mix"))
  end

  test "contained_mix_env requires a live validation resource" do
    assert {:error, :validation_resource_required} =
             MixAction.contained_mix_env(env: %{"MIX_ENV" => "test"})
  end

  test "production Mix path fails closed without workspace_id / validation resource", %{
    tmp_dir: tmp_dir
  } do
    project = create_tiny_project(Path.join(tmp_dir, "no-ws"))

    assert {:error, :validation_resource_required} = MixAction.run_mix(project, ["compile"])

    assert {:error, :workspace_id_required} =
             MixAction.run_with_required_workspace(
               project,
               ["compile"],
               %{path: project},
               %{},
               []
             )

    assert {:error, reason} =
             MixAction.Compile.run(%{path: project, warnings_as_errors: true}, %{})

    assert reason =~ "workspace_id_required"
  end

  test "contained_mix_env scrubs path-bearing caller keys against live resource paths", %{
    tmp_dir: tmp_dir
  } do
    fixture = leased_fixture(tmp_dir)

    MixAction.with_validation_resource(fixture.lease.workspace_id, fixture.context, fn resource ->
      assert {:ok, env} =
               MixAction.contained_mix_env(
                 validation_resource: resource,
                 validation_revision: :candidate,
                 env: %{
                   "MIX_ENV" => "test",
                   "MIX_BUILD_PATH" => "/evil/build",
                   "MIX_DEPS_PATH" => "/evil/deps",
                   "HOME" => "/evil/home",
                   "TMPDIR" => "/evil/tmp",
                   "HEX_HOME" => "/evil/hex",
                   "ERL_LIBS" => "/evil/libs",
                   "ARBOR_ELIXIR_ROOT" => "/evil/elixir",
                   "PATH" => "/evil/bin"
                 }
               )

      assert env["MIX_ENV"] == "test"
      assert env["ARBOR_MIX_CONTAINED"] == "1"
      assert env["HOME"] == resource.candidate_home_path
      assert env["TMPDIR"] == resource.candidate_tmp_path
      assert env["MIX_BUILD_PATH"] == resource.candidate_build_path
      assert env["MIX_DEPS_PATH"] == resource.candidate_deps_path
      assert env["MIX_ARCHIVES"] == Path.join(env["ARBOR_ELIXIR_ROOT"], ".mix/archives")
      refute String.starts_with?(env["MIX_ARCHIVES"], env["HOME"])
      assert File.dir?(env["HOME"])
      assert File.dir?(env["MIX_BUILD_PATH"])
      assert File.dir?(env["MIX_ARCHIVES"])
      assert env["ERL_LIBS"] == false
      assert String.starts_with?(env["PATH"], env["ARBOR_ERLANG_ROOT"] <> "/bin")
      {:ok, :ok}
    end)
  end

  test "resolve_mix_wrapper fails closed when anchors lack a reviewed wrapper" do
    release_like =
      Path.join(System.tmp_dir!(), "release-layout-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(release_like, "lib/arbor_actions-0.1.0/ebin"))
    on_exit(fn -> File.rm_rf!(release_like) end)

    assert {:error, :mix_wrapper_unavailable} =
             MixAction.resolve_mix_wrapper_from_anchors([
               Path.join(release_like, "lib/arbor_actions-0.1.0"),
               Path.join(release_like, "lib/arbor_actions-0.1.0/ebin")
             ])
  end

  test "scrub_caller_env only keeps MIX_ENV" do
    scrubbed =
      MixAction.scrub_caller_env(%{
        "MIX_ENV" => "prod",
        "FOO" => "bar",
        "MIX_BUILD_PATH" => "/x",
        :MIX_ENV => "dev"
      })

    assert scrubbed == %{"MIX_ENV" => "prod"}
  end

  test "cleanup diagnostic is total and byte-bounded for hostile terms" do
    improper = [1, 2 | :tail]
    huge_int = 2 ** 10_000
    invalid_utf8 = <<0xFF, 0xFE, "ok", 0x80>>
    deep = Enum.reduce(1..30, "leaf", fn _, acc -> [acc, acc] end)
    wide = Enum.to_list(1..5_000)

    for term <- [improper, huge_int, invalid_utf8, deep, wide, %{a: deep, b: wide}] do
      out = MixAction.bound_cleanup_diagnostic(term)
      assert is_binary(out)
      assert byte_size(out) <= MixAction.cleanup_diagnostic_byte_limit()
    end
  end

  test "validation resource private dirs are 0700; baseline deps private and distinct; stage child absent",
       %{tmp_dir: tmp_dir} do
    fixture = leased_fixture(tmp_dir)
    host_secret = Arbor.Actions.TestLinuxBaselineMaterializer.host_secret_marker()
    File.mkdir_p!(Path.join(fixture.repo, "deps/internal"))
    File.write!(Path.join(fixture.repo, "deps/internal/x"), "x")
    File.write!(Path.join(fixture.repo, "deps/HOST_SECRET"), host_secret)

    Arbor.Actions.TestLinuxBaselineMaterializer.reset_seams()

    assert {:ok, resource} =
             WorkspaceLeaseRegistry.acquire_validation_resource(
               fixture.lease.workspace_id,
               fixture.context
             )

    try do
      assert File.dir?(resource.stage_parent_path)
      assert private_dir?(resource.stage_parent_path)
      # Exact stage child must not be pre-created — stage_sources creates it exclusively.
      refute File.exists?(resource.stage_path)

      for path <- [
            resource.root_path,
            resource.stage_parent_path,
            resource.candidate_runtime_path,
            resource.candidate_home_path,
            resource.candidate_tmp_path,
            resource.candidate_build_path,
            resource.candidate_runner_dir_path,
            resource.candidate_result_dir_path,
            resource.base_runtime_path,
            resource.base_home_path,
            resource.base_tmp_path,
            resource.base_build_path,
            resource.base_runner_dir_path,
            resource.base_result_dir_path
          ] do
        assert File.dir?(path), "missing private dir #{path}"
        assert private_dir?(path), "expected 0700 for #{path}"
      end

      # Shell baseline deps: private, distinct, baseline marker present, host secret absent.
      assert private_dir?(resource.candidate_deps_path)
      assert private_dir?(resource.base_deps_path)
      assert resource.candidate_deps_path != resource.base_deps_path

      assert File.read!(Path.join(resource.candidate_deps_path, "MARKER")) ==
               Arbor.Actions.TestLinuxBaselineMaterializer.baseline_marker()

      refute File.exists?(Path.join(resource.candidate_deps_path, "HOST_SECRET"))
      refute File.exists?(Path.join(resource.base_deps_path, "HOST_SECRET"))
    after
      assert {:ok, _} =
               WorkspaceLeaseRegistry.release_validation_resource(
                 resource.resource_id,
                 fixture.context
               )
    end
  end

  test "security regression stage_path exclusive create no longer fails as pre-existing",
       %{tmp_dir: tmp_dir} do
    fixture = leased_fixture(tmp_dir)

    assert {:ok, resource} =
             WorkspaceLeaseRegistry.acquire_validation_resource(
               fixture.lease.workspace_id,
               fixture.context
             )

    try do
      assert File.dir?(resource.stage_parent_path)
      refute File.exists?(resource.stage_path)

      # Mirrors SecurityRegression.Shell.create_private_directory/1 exclusive mkdir.
      assert :ok = File.mkdir(resource.stage_path)
      assert :ok = File.chmod(resource.stage_path, 0o700)
      assert private_dir?(resource.stage_path)

      # Pre-existing would have failed stage_sources with :resource_directory_create_failed.
      assert {:error, :eexist} = File.mkdir(resource.stage_path)
    after
      assert {:ok, _} =
               WorkspaceLeaseRegistry.release_validation_resource(
                 resource.resource_id,
                 fixture.context
               )
    end
  end

  test "revision projections never cross candidate/base/staged boundaries", %{tmp_dir: tmp_dir} do
    fixture = leased_fixture(tmp_dir)

    assert {:ok, resource} =
             WorkspaceLeaseRegistry.acquire_validation_resource(
               fixture.lease.workspace_id,
               fixture.context
             )

    try do
      assert {:ok, candidate} = MixAction.projections_for_resource(resource, :candidate)
      assert {:ok, base} = MixAction.projections_for_resource(resource, :base)

      cand_rw = Enum.map(candidate.read_write, & &1["path"])
      base_rw = Enum.map(base.read_write, & &1["path"])

      refute resource.root_path in cand_rw
      refute resource.root_path in base_rw
      refute resource.stage_path in cand_rw
      refute resource.stage_path in base_rw
      refute resource.stage_parent_path in cand_rw
      refute resource.stage_parent_path in base_rw
      refute resource.base_worktree_path in cand_rw
      refute resource.candidate_path in base_rw

      # No RW path or ancestor may grant both candidate and base/staging authority.
      for c <- cand_rw, b <- base_rw do
        refute path_equals_or_contains?(c, b)
        refute path_equals_or_contains?(b, c)
      end

      for c <- cand_rw do
        # Staging and the shared validation root are never granted RW.
        refute c == resource.root_path
        refute c == resource.stage_path
        refute c == resource.stage_parent_path
        refute String.starts_with?(resource.stage_path, c <> "/")
        refute String.starts_with?(resource.stage_parent_path, c <> "/")
        # Candidate RW must not cover base runtime or base worktree.
        refute String.starts_with?(c, resource.base_runtime_path <> "/")
        refute c == resource.base_runtime_path
        refute String.starts_with?(c, resource.base_worktree_path <> "/")
        refute c == resource.base_worktree_path
      end

      for b <- base_rw do
        refute b == resource.root_path
        refute b == resource.stage_path
        refute b == resource.stage_parent_path
        refute String.starts_with?(resource.stage_path, b <> "/")
        refute String.starts_with?(resource.stage_parent_path, b <> "/")
        refute String.starts_with?(b, resource.candidate_runtime_path <> "/")
        refute b == resource.candidate_runtime_path
        refute String.starts_with?(b, resource.candidate_path <> "/")
        refute b == resource.candidate_path
      end

      # Shared read-only runtime roots may appear in both projections.
      cand_ro = Enum.map(candidate.read_only, & &1["path"])
      base_ro = Enum.map(base.read_only, & &1["path"])
      shared_ro = MapSet.intersection(MapSet.new(cand_ro), MapSet.new(base_ro))
      assert MapSet.size(shared_ro) >= 2
      # Shared RO must not include any revision-private RW path.
      refute Enum.any?(cand_rw ++ base_rw, &MapSet.member?(shared_ro, &1))

      assert resource.candidate_home_path != resource.base_home_path
      assert resource.candidate_tmp_path != resource.base_tmp_path
    after
      assert {:ok, _} =
               WorkspaceLeaseRegistry.release_validation_resource(
                 resource.resource_id,
                 fixture.context
               )
    end
  end

  @tag :security_regression
  test "security regression: revision runtime parents are never projected", %{tmp_dir: tmp_dir} do
    fixture = leased_fixture(tmp_dir)

    assert {:ok, resource} =
             WorkspaceLeaseRegistry.acquire_validation_resource(
               fixture.lease.workspace_id,
               fixture.context
             )

    try do
      # Runtime parents remain lifecycle-owned directories with sibling typed children.
      assert File.dir?(resource.candidate_runtime_path)
      assert File.dir?(resource.base_runtime_path)
      assert File.dir?(resource.candidate_runner_dir_path)
      assert File.dir?(resource.candidate_result_dir_path)
      assert File.dir?(resource.base_runner_dir_path)
      assert File.dir?(resource.base_result_dir_path)

      assert resource.candidate_runner_path ==
               Path.join(resource.candidate_runner_dir_path, "runner.exs")

      assert resource.candidate_result_path ==
               Path.join(resource.candidate_result_dir_path, "result.etf")

      assert resource.base_runner_path == Path.join(resource.base_runner_dir_path, "runner.exs")
      assert resource.base_result_path == Path.join(resource.base_result_dir_path, "result.etf")

      assert {:ok, candidate} = MixAction.projections_for_resource(resource, :candidate)
      assert {:ok, base} = MixAction.projections_for_resource(resource, :base)

      for {projections, revision, runtime, home, tmp, build, deps, worktree, runner_dir,
           result_dir, runner, result} <- [
            {candidate, "candidate", resource.candidate_runtime_path,
             resource.candidate_home_path, resource.candidate_tmp_path,
             resource.candidate_build_path, resource.candidate_deps_path, resource.candidate_path,
             resource.candidate_runner_dir_path, resource.candidate_result_dir_path,
             resource.candidate_runner_path, resource.candidate_result_path},
            {base, "base", resource.base_runtime_path, resource.base_home_path,
             resource.base_tmp_path, resource.base_build_path, resource.base_deps_path,
             resource.base_worktree_path, resource.base_runner_dir_path,
             resource.base_result_dir_path, resource.base_runner_path, resource.base_result_path}
          ] do
        assert projections.revision == revision

        # Runtime parent must not appear as any projected path (RW or RO).
        all_paths =
          Enum.map(projections.read_write ++ projections.read_only, & &1["path"])

        refute runtime in all_paths
        refute Enum.any?(projections.read_write, &(&1["purpose"] == "runtime"))
        refute Enum.any?(projections.read_only, &(&1["purpose"] == "runtime"))

        by_rw =
          Map.new(projections.read_write, fn entry ->
            {entry["purpose"], entry}
          end)

        by_ro =
          Map.new(projections.read_only, fn entry ->
            {entry["purpose"], entry}
          end)

        assert by_rw["worktree"] == %{
                 "path" => worktree,
                 "mode" => "read_write",
                 "purpose" => "worktree"
               }

        assert by_rw["home"] == %{
                 "path" => home,
                 "mode" => "read_write",
                 "purpose" => "home"
               }

        assert by_rw["tmp"] == %{
                 "path" => tmp,
                 "mode" => "read_write",
                 "purpose" => "tmp"
               }

        assert by_rw["build"] == %{
                 "path" => build,
                 "mode" => "read_write",
                 "purpose" => "build"
               }

        assert by_rw["deps"] == %{
                 "path" => deps,
                 "mode" => "read_write",
                 "purpose" => "deps"
               }

        assert by_rw["validation_result"] == %{
                 "path" => result_dir,
                 "mode" => "read_write",
                 "purpose" => "validation_result"
               }

        assert by_ro["validation_runner"] == %{
                 "path" => runner_dir,
                 "mode" => "read_only",
                 "purpose" => "validation_runner"
               }

        # Typed children live under the runtime parent; parent itself is not projected.
        assert String.starts_with?(home, runtime <> "/")
        assert String.starts_with?(tmp, runtime <> "/")
        assert String.starts_with?(build, runtime <> "/")
        assert String.starts_with?(runner_dir, runtime <> "/")
        assert String.starts_with?(result_dir, runtime <> "/")
        assert String.starts_with?(runner, runner_dir <> "/")
        assert String.starts_with?(result, result_dir <> "/")

        # Only the dedicated result directory is writable among runner/result.
        # No unrelated projected ancestor may cover runner/result files.
        for entry <- projections.read_write do
          path = entry["path"]
          purpose = entry["purpose"]
          refute path == runtime

          if purpose == "validation_result" do
            assert path == result_dir
            assert path_equals_or_contains?(path, result)
          else
            refute path_equals_or_contains?(path, runner)
            refute path_equals_or_contains?(path, result)
            refute path_equals_or_contains?(path, runner_dir)
            refute path_equals_or_contains?(path, result_dir)
          end
        end

        for entry <- projections.read_only do
          path = entry["path"]
          purpose = entry["purpose"]

          if purpose == "validation_runner" do
            assert path == runner_dir
            assert path_equals_or_contains?(path, runner)
          else
            refute path_equals_or_contains?(path, runner)
            refute path_equals_or_contains?(path, result)
          end
        end

        # RW purposes include validation_result; RO includes validation_runner.
        assert MapSet.new(Map.keys(by_rw)) ==
                 MapSet.new([
                   "worktree",
                   "home",
                   "tmp",
                   "build",
                   "deps",
                   "validation_result"
                 ])

        assert MapSet.member?(MapSet.new(Map.keys(by_ro)), "validation_runner")
      end

      # Candidate/base isolation: no RW path grants both revisions.
      cand_rw = Enum.map(candidate.read_write, & &1["path"])
      base_rw = Enum.map(base.read_write, & &1["path"])
      cand_ro = Enum.map(candidate.read_only, & &1["path"])
      base_ro = Enum.map(base.read_only, & &1["path"])

      for c <- cand_rw, b <- base_rw do
        refute path_equals_or_contains?(c, b)
        refute path_equals_or_contains?(b, c)
      end

      # No projection covers the opposite revision's runner/result dirs.
      refute resource.candidate_runner_dir_path in base_ro
      refute resource.candidate_result_dir_path in base_rw
      refute resource.base_runner_dir_path in cand_ro
      refute resource.base_result_dir_path in cand_rw

      refute resource.candidate_runtime_path in cand_rw
      refute resource.base_runtime_path in base_rw
      refute resource.candidate_runtime_path in base_rw
      refute resource.base_runtime_path in cand_rw
    after
      assert {:ok, _} =
               WorkspaceLeaseRegistry.release_validation_resource(
                 resource.resource_id,
                 fixture.context
               )
    end
  end

  test "run_mix binds cwd to validation revision worktree", %{tmp_dir: tmp_dir} do
    fixture = leased_fixture(tmp_dir)
    foreign = create_tiny_project(Path.join(tmp_dir, "foreign"))

    MixAction.with_validation_resource(fixture.lease.workspace_id, fixture.context, fn resource ->
      assert {:error, reason} =
               MixAction.run_mix(foreign, ["compile"], validation_resource: resource)

      assert reason =~ "cwd_not_bound_to_validation_revision"
      {:ok, :ok}
    end)
  end

  test "with_validation_resource reuses one resource and releases after success", %{
    tmp_dir: tmp_dir
  } do
    fixture = leased_fixture(tmp_dir)
    parent = self()

    assert {:ok, :done} =
             MixAction.with_validation_resource(fixture.lease.workspace_id, fixture.context, fn
               resource ->
                 send(parent, {:resource, resource.resource_id, resource.root_path})

                 assert {:ok, [only]} =
                          WorkspaceLeaseRegistry.validation_resources(
                            fixture.lease.workspace_id,
                            fixture.context
                          )

                 assert only.resource_id == resource.resource_id
                 {:ok, :done}
             end)

    assert_receive {:resource, _resource_id, root_path}
    refute File.exists?(root_path)
  end

  test "with_validation_resource cleanup failure on success is enforcing", %{tmp_dir: tmp_dir} do
    fixture = leased_fixture(tmp_dir)

    assert {:error, {:validation_resource_cleanup_failed, detail}} =
             MixAction.with_validation_resource(
               fixture.lease.workspace_id,
               Map.put(fixture.context, :cleanup_failures, 1),
               fn resource ->
                 send(self(), {:kept, resource.root_path, resource.resource_id})
                 {:ok, %{passed: true, evidence: "validated"}}
               end
             )

    assert detail.operation_outcome =~ "passed"
    assert byte_size(detail.operation_outcome) <= 2_048
    assert_receive {:kept, root_path, resource_id}
    assert File.dir?(root_path)

    assert {:ok, _} =
             WorkspaceLeaseRegistry.release_validation_resource(resource_id, fixture.context)

    refute File.exists?(root_path)
  end

  test "operation_outcome cleanup diagnostic is byte-bounded for huge nested terms", %{
    tmp_dir: tmp_dir
  } do
    fixture = leased_fixture(tmp_dir)
    huge = String.duplicate("x", 50_000)
    nested = Enum.reduce(1..20, huge, fn _, acc -> %{data: acc, list: [acc, acc, acc]} end)

    assert {:error, {:validation_resource_cleanup_failed, detail}} =
             MixAction.with_validation_resource(
               fixture.lease.workspace_id,
               Map.put(fixture.context, :cleanup_failures, 1),
               fn resource ->
                 send(self(), {:kept, resource.resource_id})
                 {:ok, nested}
               end
             )

    assert is_binary(detail.operation_outcome)
    assert byte_size(detail.operation_outcome) <= 2_048
    assert_receive {:kept, resource_id}

    assert {:ok, _} =
             WorkspaceLeaseRegistry.release_validation_resource(resource_id, fixture.context)
  end

  test "with_validation_resource releases after raise and throw; cleanup failure discoverable",
       %{tmp_dir: tmp_dir} do
    fixture = leased_fixture(tmp_dir)

    assert_raise RuntimeError, fn ->
      MixAction.with_validation_resource(
        fixture.lease.workspace_id,
        fixture.context,
        fn resource ->
          send(self(), {:raised_root, resource.root_path})
          raise "boom"
        end
      )
    end

    assert_receive {:raised_root, raised_root}
    refute File.exists?(raised_root)

    catch_throw(
      MixAction.with_validation_resource(
        fixture.lease.workspace_id,
        fixture.context,
        fn resource ->
          send(self(), {:thrown_root, resource.root_path})
          throw(:stop)
        end
      )
    )

    assert_receive {:thrown_root, thrown_root}
    refute File.exists?(thrown_root)

    assert_raise RuntimeError, fn ->
      MixAction.with_validation_resource(
        fixture.lease.workspace_id,
        Map.put(fixture.context, :cleanup_failures, 1),
        fn resource ->
          send(self(), {:raised_retained, resource.root_path, resource.resource_id})
          raise "boom"
        end
      )
    end

    failure = MixAction.last_validation_cleanup_failure()
    assert failure.during == :raise
    assert_receive {:raised_retained, retained_root, retained_id}
    assert File.dir?(retained_root)

    assert {:ok, _} =
             WorkspaceLeaseRegistry.release_validation_resource(retained_id, fixture.context)
  end

  test "owner death cleans validation resource paths", %{tmp_dir: tmp_dir} do
    fixture = leased_fixture(tmp_dir)
    test_pid = self()

    owner =
      spawn(fn ->
        assert {:ok, resource} =
                 WorkspaceLeaseRegistry.acquire_validation_resource(
                   fixture.lease.workspace_id,
                   fixture.context
                 )

        send(test_pid, {:owned, resource.resource_id, resource.root_path})
        Process.sleep(:infinity)
      end)

    assert_receive {:owned, _resource_id, root_path}, 5_000
    assert File.dir?(root_path)
    Process.exit(owner, :kill)
    assert_eventually(fn -> not File.exists?(root_path) end)
  end

  test "run_mix passes revision projections and absolute wrapper; cwd is worktree", %{
    tmp_dir: tmp_dir
  } do
    fixture = leased_fixture(tmp_dir)
    create_tiny_project(fixture.lease.worktree_path)
    git!(fixture.lease.worktree_path, ["add", "-A"])
    git!(fixture.lease.worktree_path, ["commit", "-m", "project"])

    MixAction.with_validation_resource(fixture.lease.workspace_id, fixture.context, fn resource ->
      assert {:ok, _} =
               MixAction.run_mix(resource.candidate_path, ["compile"],
                 validation_resource: resource,
                 validation_revision: :candidate
               )

      invocation = Arbor.Actions.TestMixShell.last_invocation()
      assert {:ok, wrapper} = MixAction.resolve_mix_wrapper()
      assert invocation.tool == wrapper
      projections = Keyword.get(invocation.opts, :filesystem_projections)
      assert projections.revision == "candidate"
      rw = Enum.map(projections.read_write, & &1["path"])
      refute resource.root_path in rw
      refute resource.stage_path in rw
      refute resource.base_home_path in rw

      {:ok, expected_cwd} = SafePath.resolve_real(resource.candidate_path)
      assert Keyword.get(invocation.opts, :cwd) == expected_cwd
      # Ordinary Mix calls do not synthesize an Actions-owned profile default.
      refute Keyword.has_key?(invocation.opts, :resource_profile)

      env_map = Map.new(invocation.env)
      assert env_map["HOME"] == resource.candidate_home_path
      assert env_map["TMPDIR"] == resource.candidate_tmp_path
      assert env_map["MIX_BUILD_PATH"] == resource.candidate_build_path
      assert env_map["MIX_DEPS_PATH"] == resource.candidate_deps_path
      {:ok, :ok}
    end)
  end

  test "run_mix forwards explicit resource_profile unchanged to Shell facade", %{
    tmp_dir: tmp_dir
  } do
    fixture = leased_fixture(tmp_dir)
    create_tiny_project(fixture.lease.worktree_path)
    git!(fixture.lease.worktree_path, ["add", "-A"])
    git!(fixture.lease.worktree_path, ["commit", "-m", "project"])

    MixAction.with_validation_resource(fixture.lease.workspace_id, fixture.context, fn resource ->
      assert {:ok, _} =
               MixAction.run_mix(resource.candidate_path, ["compile"],
                 validation_resource: resource,
                 resource_profile: :intensive
               )

      intensive = Arbor.Actions.TestMixShell.last_invocation()
      assert Keyword.fetch!(intensive.opts, :resource_profile) == :intensive

      # Invalid values are not normalized or dropped — Shell owns validation.
      assert {:ok, _} =
               MixAction.run_mix(resource.candidate_path, ["compile"],
                 validation_resource: resource,
                 resource_profile: :not_a_real_profile
               )

      invalid = Arbor.Actions.TestMixShell.last_invocation()
      assert Keyword.fetch!(invalid.opts, :resource_profile) == :not_a_real_profile
      {:ok, :ok}
    end)
  end

  test "workspace-backed baseline deps are private Shell materializations before spawn", %{
    tmp_dir: tmp_dir
  } do
    fixture = leased_fixture(tmp_dir)
    create_tiny_project(fixture.lease.worktree_path)
    host_secret = Arbor.Actions.TestLinuxBaselineMaterializer.host_secret_marker()
    File.mkdir_p!(Path.join(fixture.lease.worktree_path, "deps/hex_pkg"))
    File.write!(Path.join(fixture.lease.worktree_path, "deps/hex_pkg/file"), "content")
    File.write!(Path.join(fixture.lease.worktree_path, "deps/HOST_SECRET"), host_secret)
    File.write!(Path.join(fixture.lease.worktree_path, "mix.lock"), "%{}\n")
    git!(fixture.lease.worktree_path, ["add", "-A"])
    git!(fixture.lease.worktree_path, ["commit", "-m", "with-deps"])

    # Host repo deps must not be copied into the baseline materialization.
    File.mkdir_p!(Path.join(fixture.repo, "deps/hex_pkg"))
    File.write!(Path.join(fixture.repo, "deps/hex_pkg/file"), "content")
    File.write!(Path.join(fixture.repo, "deps/HOST_SECRET"), host_secret)

    Arbor.Actions.TestLinuxBaselineMaterializer.reset_seams()

    MixAction.with_validation_resource(fixture.lease.workspace_id, fixture.context, fn resource ->
      assert private_dir?(resource.candidate_deps_path)
      assert private_dir?(resource.base_deps_path)
      assert resource.candidate_deps_path != resource.base_deps_path

      assert File.read!(Path.join(resource.candidate_deps_path, "MARKER")) ==
               Arbor.Actions.TestLinuxBaselineMaterializer.baseline_marker()

      refute "hex_pkg" in File.ls!(resource.candidate_deps_path)
      refute File.exists?(Path.join(resource.candidate_deps_path, "HOST_SECRET"))

      assert {:ok, result} =
               MixAction.run_mix(resource.candidate_path, ["compile"],
                 validation_resource: resource
               )

      assert result.exit_code == 0
      invocation = Arbor.Actions.TestMixShell.last_invocation()
      env_map = Map.new(invocation.env)
      assert env_map["MIX_DEPS_PATH"] == resource.candidate_deps_path
      refute is_nil(Keyword.get(invocation.opts, :filesystem_projections))
      {:ok, :ok}
    end)
  end

  test "security regression: no caller-selected host snapshot or materializer destination API", %{
    tmp_dir: tmp_dir
  } do
    source = Path.join(tmp_dir, "unleased-source")
    destination = Path.join(tmp_dir, "attacker-selected-destination")
    File.mkdir_p!(Path.join(source, "deps/private_pkg"))
    File.write!(Path.join(source, "deps/private_pkg/secret"), "host-only material\n")

    for fun <- [
          :snapshot_dependency_tree,
          :acquire_linux_dependency_baseline_lease,
          :release_linux_dependency_baseline_lease
        ] do
      result =
        try do
          apply(WorkspaceLeaseRegistry, fun, [source, destination, []])
        rescue
          UndefinedFunctionError -> :not_exported
        end

      assert result == :not_exported
    end

    refute File.exists?(destination)
  end

  test "security regression: TestMixShell mutation during execute returns validation_tree_mutated",
       %{tmp_dir: tmp_dir} do
    fixture = leased_fixture(tmp_dir)
    create_tiny_project(fixture.lease.worktree_path)
    git!(fixture.lease.worktree_path, ["add", "-A"])
    git!(fixture.lease.worktree_path, ["commit", "-m", "base project"])

    MixAction.with_validation_resource(fixture.lease.workspace_id, fixture.context, fn resource ->
      Arbor.Actions.TestMixShell.force_worktree_mutation(
        "lib/tiny.ex",
        "defmodule Tiny do\n  def hi, do: :mutated_during_validation\nend\n"
      )

      assert {:error, reason} =
               MixAction.run_mix(resource.candidate_path, ["compile"],
                 validation_resource: resource,
                 bind_committable_tree: true
               )

      assert reason == ":validation_tree_mutated" or reason =~ "validation_tree_mutated"
      Arbor.Actions.TestMixShell.clear_worktree_mutation()
      {:ok, :ok}
    end)
  end

  test "security regression: clean filter never runs during tree binding", %{tmp_dir: tmp_dir} do
    fixture = leased_fixture(tmp_dir)
    wt = fixture.lease.worktree_path
    create_tiny_project(wt)
    marker = Path.join(tmp_dir, "clean-filter-host-marker")

    # Install a malicious clean filter in the worktree repo config. Binding must
    # not invoke it (no host marker).
    git!(wt, ["config", "filter.evil.clean", "touch #{marker} && cat"])
    File.write!(Path.join(wt, ".gitattributes"), "*.ex filter=evil\n")
    git!(wt, ["add", "-A"])
    git!(wt, ["commit", "-m", "with evil filter"])
    # Setup add may invoke the clean filter once; clear residue so the assertion
    # only covers the tree-binding path.
    _ = File.rm(marker)
    refute File.exists?(marker)

    assert {:ok, binding} = MixAction.committable_tree_binding(wt)
    assert is_binary(binding.tree_oid)
    refute File.exists?(marker)
  end

  test "large repository tree binding batches Git processes and preserves the exact tree", %{
    tmp_dir: tmp_dir
  } do
    fixture = leased_fixture(tmp_dir)
    wt = fixture.lease.worktree_path
    create_tiny_project(wt)

    for index <- 1..128 do
      path = Path.join([wt, "lib", "batch", "file_#{index}.txt"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "entry #{index}\n")
    end

    git!(wt, ["add", "-A"])
    git!(wt, ["commit", "-m", "large binding fixture"])
    File.write!(Path.join(wt, "untracked.txt"), "included in committable tree\n")

    test_pid = self()

    MixAction.__test_set_tree_binding_git_observer__(fn operation ->
      send(test_pid, {:tree_binding_git, operation})
    end)

    binding =
      try do
        assert {:ok, binding} = MixAction.committable_tree_binding(wt, timeout: 30_000)
        binding
      after
        MixAction.__test_set_tree_binding_git_observer__(nil)
      end

    operations = drain_tree_binding_git_operations([])

    assert Enum.frequencies(operations) == %{
             init: 1,
             rev_parse: 3,
             ls_files: 2,
             hash_object: 1,
             update_index: 1,
             write_tree: 1
           }

    git!(wt, ["add", "-A"])
    git!(wt, ["commit", "-m", "materialize expected tree"])
    head = git!(wt, ["rev-parse", "HEAD"])
    assert {:ok, expected_tree} = MixAction.commit_tree_oid(wt, head)
    assert binding.tree_oid == expected_tree
  end

  test "security regression: leading/trailing-space, foo..bar, and tab paths bind exactly",
       %{tmp_dir: tmp_dir} do
    fixture = leased_fixture(tmp_dir)
    wt = fixture.lease.worktree_path
    create_tiny_project(wt)

    spaced = " spaced name "
    dotted = "foo..bar"
    # Valid Git path may contain a tab; binding must preserve exact bytes.
    tabbed = "tab\tname"
    File.mkdir_p!(Path.join(wt, "lib"))
    File.write!(Path.join([wt, "lib", spaced]), "space-bytes\n")
    File.write!(Path.join([wt, "lib", dotted]), "dotdot-bytes\n")
    File.write!(Path.join([wt, "lib", tabbed]), "tab-bytes\n")
    # Use pathspec from worktree so git records exact names (including spaces/tabs).
    git!(wt, ["add", "-A"])
    git!(wt, ["commit", "-m", "exact path names"])

    ls =
      git_raw!(wt, ["ls-files", "-z"])
      |> :binary.split(<<0>>, [:global])
      |> Enum.reject(&(&1 == ""))

    assert "lib/#{spaced}" in ls
    assert "lib/#{dotted}" in ls
    assert "lib/#{tabbed}" in ls

    assert {:ok, binding} = MixAction.committable_tree_binding(wt)
    assert is_binary(binding.tree_oid)

    # Clean binding must equal the immutable commit tree OID (not merely
    # binder-twice equality).
    head = git!(wt, ["rev-parse", "HEAD"])
    assert {:ok, commit_tree} = MixAction.commit_tree_oid(wt, head)
    assert binding.tree_oid == commit_tree

    # Mutating only the spaced file changes the bound tree.
    File.write!(Path.join([wt, "lib", spaced]), "space-bytes-mutated\n")
    assert {:ok, mutated} = MixAction.committable_tree_binding(wt)
    refute mutated.tree_oid == binding.tree_oid
  end

  test "security regression: stage entry splits at first tab only; path tabs preserved", %{
    tmp_dir: _tmp_dir
  } do
    # mode oid stage \t path-with-tab
    entry = "100644 " <> String.duplicate("a", 40) <> " 0\tlib/has\ttab.txt"
    assert {:ok, "100644", oid, path} = MixAction.__test_parse_stage_entry__(entry)
    assert oid == String.duplicate("a", 40)
    assert path == "lib/has\ttab.txt"
    assert :binary.match(path, <<"\t">>) != :nomatch

    # Multiple tabs in path — only first tab separates meta from path.
    entry2 = "100644 " <> String.duplicate("b", 40) <> " 0\ta\tb\tc"
    assert {:ok, "100644", _, path2} = MixAction.__test_parse_stage_entry__(entry2)
    assert path2 == "a\tb\tc"

    # Malformed: no tab
    assert {:error, :invalid_stage_entry} =
             MixAction.__test_parse_stage_entry__("100644 abc 0 no-tab")

    # Malformed: empty path after tab
    assert {:error, :invalid_stage_entry} =
             MixAction.__test_parse_stage_entry__("100644 abc 0\t")

    # Non-UTF-8 path bytes must not crash — either parse or fail closed.
    binary_path = "100644 " <> String.duplicate("c", 40) <> " 0\t" <> <<0xFF, 0xFE, "x">>
    result = MixAction.__test_parse_stage_entry__(binary_path)
    assert match?({:ok, _, _, _}, result) or match?({:error, :invalid_stage_entry}, result)
  end

  test "security regression: tree binding enforces cumulative entry/byte/depth limits", %{
    tmp_dir: tmp_dir
  } do
    fixture = leased_fixture(tmp_dir)
    wt = fixture.lease.worktree_path
    create_tiny_project(wt)
    git!(wt, ["add", "-A"])
    git!(wt, ["commit", "-m", "base"])

    # Depth limit: nested path deeper than max_depth fails closed before hashing.
    deep = Path.join(Enum.map(1..5, fn i -> "d#{i}" end))
    File.mkdir_p!(Path.join(wt, deep))
    File.write!(Path.join([wt, deep, "leaf.txt"]), "deep\n")
    git!(wt, ["add", "-A"])
    git!(wt, ["commit", "-m", "deep"])

    assert {:error, :tree_binding_bounds_exceeded} =
             MixAction.committable_tree_binding(wt, max_depth: 3)

    # Entry limit: tiny budget fails closed.
    assert {:error, :tree_binding_bounds_exceeded} =
             MixAction.committable_tree_binding(wt, max_entries: 1)

    # Byte limit: file larger than max_bytes fails closed before full hash load.
    File.write!(Path.join(wt, "big.bin"), :binary.copy(<<"x">>, 200))
    git!(wt, ["add", "big.bin"])
    git!(wt, ["commit", "-m", "big"])

    assert {:error, :tree_binding_bounds_exceeded} =
             MixAction.committable_tree_binding(wt,
               max_bytes: 50,
               max_depth: 48,
               max_entries: 1000
             )
  end

  test "security regression: traversal and unsupported paths fail closed", %{tmp_dir: tmp_dir} do
    fixture = leased_fixture(tmp_dir)
    wt = fixture.lease.worktree_path
    create_tiny_project(wt)
    git!(wt, ["add", "-A"])
    git!(wt, ["commit", "-m", "base"])

    # Git never emits absolute / ".." segment paths from ls-files; the binding
    # gate still fail-closes if such a path appears (segment-aware, not substring).
    assert {:error, {:unsafe_index_path, _}} = MixAction.__test_reject_index_path__("../escape")
    assert {:error, {:unsafe_index_path, _}} = MixAction.__test_reject_index_path__("a/../b")
    assert {:error, {:unsafe_index_path, _}} = MixAction.__test_reject_index_path__("a/./b")
    assert {:error, {:unsafe_index_path, _}} = MixAction.__test_reject_index_path__("/abs/path")
    assert {:error, {:unsafe_index_path, _}} = MixAction.__test_reject_index_path__("")
    assert {:error, {:unsafe_index_path, _}} = MixAction.__test_reject_index_path__("foo/\nbar")

    # Substring ".." and leading/trailing spaces are accepted by the gate.
    assert :ok = MixAction.__test_reject_index_path__("foo..bar")
    assert :ok = MixAction.__test_reject_index_path__(" spaced ")
    assert :ok = MixAction.__test_reject_index_path__("lib/foo..bar")

    # Component-internal ".." remains bindable end-to-end.
    File.write!(Path.join(wt, "ok..file"), "ok\n")
    assert {:ok, _} = MixAction.committable_tree_binding(wt)
  end

  test "security regression: tracked gitlink fails closed rather than silent omit", %{
    tmp_dir: tmp_dir
  } do
    fixture = leased_fixture(tmp_dir)
    wt = fixture.lease.worktree_path
    create_tiny_project(wt)
    git!(wt, ["add", "-A"])
    git!(wt, ["commit", "-m", "base"])

    # Create a minimal second repo and register it as a gitlink without checkout.
    sub = Path.join(tmp_dir, "subrepo")
    File.mkdir_p!(sub)
    git!(sub, ["init"])
    git!(sub, ["config", "user.email", "test@example.com"])
    git!(sub, ["config", "user.name", "Test"])
    File.write!(Path.join(sub, "s"), "s\n")
    git!(sub, ["add", "s"])
    git!(sub, ["commit", "-m", "sub"])
    sub_head = git!(sub, ["rev-parse", "HEAD"])

    git!(wt, [
      "update-index",
      "--add",
      "--cacheinfo",
      "160000",
      sub_head,
      "vendor/sub"
    ])

    git!(wt, ["commit", "-m", "add gitlink"])

    stage =
      git_raw!(wt, ["ls-files", "-z", "--stage"])
      |> :binary.split(<<0>>, [:global])
      |> Enum.reject(&(&1 == ""))

    assert Enum.any?(stage, &String.starts_with?(&1, "160000 ")),
           "expected gitlink in worktree index stage listing, got: #{inspect(stage)}"

    assert {:error, {:unsupported_tracked_gitlink, _}} =
             MixAction.committable_tree_binding(wt)
  end

  test "security regression: exclusive tree-binding root cleans up its invocation-owned root",
       %{tmp_dir: tmp_dir} do
    fixture = leased_fixture(tmp_dir)
    wt = fixture.lease.worktree_path
    create_tiny_project(wt)
    git!(wt, ["add", "-A"])
    git!(wt, ["commit", "-m", "base"])

    observed = :ets.new(:tree_bind_roots, [:set, :public])

    MixAction.__test_set_binding_root_observer__(fn root ->
      :ets.insert(observed, {root, true})
    end)

    try do
      assert {:ok, binding} = MixAction.committable_tree_binding(wt)
      assert is_binary(binding.tree_oid)

      roots = :ets.tab2list(observed) |> Enum.map(&elem(&1, 0))
      assert roots != []

      # Assert only this invocation's private roots are gone — never that a
      # global temp glob is empty (concurrent tasks may leave their own roots).
      for root <- roots do
        refute File.exists?(root), "invocation-owned root still present: #{root}"
      end
    after
      MixAction.__test_set_binding_root_observer__(nil)
      :ets.delete(observed)
    end
  end

  test "security regression: pre-existing tree-binding root is not deleted on exclusive-create failure",
       %{tmp_dir: tmp_dir} do
    fixture = leased_fixture(tmp_dir)
    wt = fixture.lease.worktree_path
    create_tiny_project(wt)
    git!(wt, ["add", "-A"])
    git!(wt, ["commit", "-m", "base"])

    owned = :ets.new(:tree_bind_preexist, [:set, :public])

    # Observer pre-creates the proposed private root with an unowned marker.
    # Binding must fail closed without cleaning up that foreign path.
    MixAction.__test_set_binding_root_observer__(fn root ->
      File.mkdir_p!(root)
      marker = Path.join(root, "unowned-marker")
      File.write!(marker, "do-not-delete\n")
      :ets.insert(owned, {:root, root})
      :ets.insert(owned, {:marker, marker})
    end)

    try do
      assert {:error, :tree_binding_root_exists} = MixAction.committable_tree_binding(wt)

      assert [{:root, root}] = :ets.lookup(owned, :root)
      assert [{:marker, marker}] = :ets.lookup(owned, :marker)
      assert File.dir?(root), "pre-existing root must remain after exclusive-create failure"
      assert File.exists?(marker), "unowned marker must not be deleted by binding cleanup"
      assert File.read!(marker) == "do-not-delete\n"
    after
      MixAction.__test_set_binding_root_observer__(nil)

      # Test-owned path only — never leave residue from this regression fixture.
      case :ets.lookup(owned, :root) do
        [{:root, root}] -> _ = File.rm_rf(root)
        _ -> :ok
      end

      :ets.delete(owned)
    end
  end

  test "security regression: cleanup never substitutes a late identity for the created root",
       %{tmp_dir: tmp_dir} do
    fixture = leased_fixture(tmp_dir)
    wt = fixture.lease.worktree_path
    create_tiny_project(wt)
    git!(wt, ["add", "-A"])
    git!(wt, ["commit", "-m", "base"])

    observed = :ets.new(:tree_bind_identity_failure, [:set, :public])

    MixAction.__test_set_binding_root_identity_hook__(fn root ->
      if :ets.insert_new(observed, {:root, root}) do
        {:error, :simulated_initial_lstat_failure}
      else
        :continue
      end
    end)

    try do
      assert {:error, {:tree_binding_root_identity_unproven, _}} =
               MixAction.committable_tree_binding(wt)

      assert [{:root, root}] = :ets.lookup(observed, :root)
      assert File.dir?(root), "root without an initial identity proof must not be deleted"
    after
      MixAction.__test_set_binding_root_identity_hook__(nil)

      case :ets.lookup(observed, :root) do
        [{:root, root}] -> _ = File.rm_rf(root)
        _ -> :ok
      end

      :ets.delete(observed)
    end
  end

  test "security regression: linked-worktree binding.head equals git -C worktree rev-parse HEAD",
       %{tmp_dir: tmp_dir} do
    main = Path.join(tmp_dir, "main-repo")
    File.mkdir_p!(main)
    git!(main, ["init"])
    git!(main, ["config", "user.email", "test@example.com"])
    git!(main, ["config", "user.name", "Test"])
    git!(main, ["checkout", "-b", "main"])
    File.write!(Path.join(main, "README"), "main-a\n")
    git!(main, ["add", "README"])
    git!(main, ["commit", "-m", "A"])
    commit_a = git!(main, ["rev-parse", "HEAD"])

    # Feature stays at A while main advances to B so common-dir HEAD != worktree HEAD.
    git!(main, ["branch", "feature"])
    File.write!(Path.join(main, "README"), "main-b\n")
    git!(main, ["add", "README"])
    git!(main, ["commit", "-m", "B"])
    commit_b = git!(main, ["rev-parse", "HEAD"])
    assert commit_a != commit_b
    assert git!(main, ["rev-parse", "HEAD"]) == commit_b

    linked = Path.join(tmp_dir, "linked-wt")
    git!(main, ["worktree", "add", linked, "feature"])
    assert git!(linked, ["rev-parse", "HEAD"]) == commit_a

    create_tiny_project(linked)
    git!(linked, ["add", "-A"])
    git!(linked, ["commit", "-m", "project on feature"])
    worktree_head = git!(linked, ["rev-parse", "HEAD"])
    refute worktree_head == commit_b
    # Common-dir / main worktree HEAD remains B.
    assert git!(main, ["rev-parse", "HEAD"]) == commit_b

    assert {:ok, binding} = MixAction.committable_tree_binding(linked)
    assert binding.head == worktree_head
    assert binding.head == git!(linked, ["rev-parse", "HEAD"])
    refute binding.head == git!(main, ["rev-parse", "HEAD"])
  end

  test "security regression: symlink swap during capture fails closed deterministically", %{
    tmp_dir: tmp_dir
  } do
    fixture = leased_fixture(tmp_dir)
    wt = fixture.lease.worktree_path
    create_tiny_project(wt)

    link_rel = "lib/link.txt"
    # Deliberately different *byte lengths* so size alone cannot make a swap
    # look identical; names/content also differ for clarity.
    target_a_name = "target_a_short.txt"
    target_b_name = "target_b_much_longer_deliberately_different_length.txt"
    refute byte_size(target_a_name) == byte_size(target_b_name)

    File.write!(Path.join(wt, "lib/" <> target_a_name), "content-A\n")
    File.write!(Path.join(wt, "lib/" <> target_b_name), "content-B-longer\n")
    # worktree_join preserves exact relative path; mirror for the hook match.
    # Binding canonicalizes the worktree, so resolve for the hook path.
    {:ok, canonical_wt} = SafePath.resolve_real(wt)
    link_abs = canonical_wt <> "/" <> link_rel
    File.rm(link_abs)
    File.ln_s!(target_a_name, link_abs)
    {:ok, link_before} = File.lstat(link_abs, time: :posix)
    git!(wt, ["add", "-A"])
    git!(wt, ["commit", "-m", "with symlink"])

    # Inject a deterministic swap between the first target observation and the
    # second (process-local hook only — no Application env).
    MixAction.__test_set_symlink_capture_hook__(fn path ->
      if path == link_abs do
        File.rm!(path)
        File.ln_s!(target_b_name, path)
      end
    end)

    try do
      assert {:error, :worktree_symlink_changed} = MixAction.committable_tree_binding(wt)
    after
      MixAction.__test_set_symlink_capture_hook__(nil)
    end

    # Without the hook, binding succeeds; assert target identity is distinguishable.
    File.rm!(link_abs)
    File.ln_s!(target_a_name, link_abs)
    {:ok, target} = File.read_link(link_abs)
    assert target == target_a_name
    refute target == target_b_name
    {:ok, link_after} = File.lstat(link_abs, time: :posix)
    # Same path may get a new inode after recreate; identity tuple still valid type.
    assert link_after.type == :symlink
    assert link_before.type == :symlink

    assert {:ok, binding} = MixAction.committable_tree_binding(wt)
    assert is_binary(binding.tree_oid)
  end

  test "security regression: commit object tree OID must match pre-validation binding", %{
    tmp_dir: tmp_dir
  } do
    fixture = leased_fixture(tmp_dir)
    wt = fixture.lease.worktree_path
    create_tiny_project(wt)
    git!(wt, ["add", "-A"])
    git!(wt, ["commit", "-m", "base"])

    assert {:ok, before} = MixAction.committable_tree_binding(wt)

    # Create a different tree in a commit while restoring the worktree so a
    # worktree-only check would pass but the commit object would not.
    File.write!(Path.join(wt, "lib/tiny.ex"), "defmodule Tiny do\n  def hi, do: :other\nend\n")
    git!(wt, ["add", "-A"])
    _evil = git!(wt, ["commit", "-m", "evil tree"])
    evil_commit = git!(wt, ["rev-parse", "HEAD"])
    assert {:ok, evil_tree} = MixAction.commit_tree_oid(wt, evil_commit)
    refute evil_tree == before.tree_oid

    # Restore worktree content to pre-validation bytes without amending the evil commit.
    git!(wt, ["checkout", before.head, "--", "lib/tiny.ex"])

    # Worktree binding may now match before, but commit object still differs.
    assert {:ok, restored} = MixAction.committable_tree_binding(wt)
    assert restored.tree_oid == before.tree_oid
    assert {:ok, still_evil} = MixAction.commit_tree_oid(wt, evil_commit)
    assert still_evil == evil_tree
    refute still_evil == before.tree_oid
  end

  defp leased_fixture(tmp_dir) do
    repo = Path.join(tmp_dir, "repo-#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)
    git!(repo, ["init"])
    git!(repo, ["config", "user.email", "test@example.com"])
    git!(repo, ["config", "user.name", "Test"])
    File.write!(Path.join(repo, "README"), "hi\n")
    git!(repo, ["add", "README"])
    git!(repo, ["commit", "-m", "init"])
    base = git!(repo, ["rev-parse", "HEAD"])

    task_id = "task_mix_slice1_#{System.unique_integer([:positive])}"
    principal_id = "agent_mix_slice1_#{System.unique_integer([:positive])}"

    assert {:ok, lease} =
             WorkspaceLeaseRegistry.acquire(%{
               repo_path: repo,
               branch: "slice1-#{System.unique_integer([:positive])}",
               task_id: task_id,
               principal_id: principal_id,
               base_ref: base,
               worktree_base_dir: Path.join(tmp_dir, "worktrees")
             })

    context = %{task_id: task_id, principal_id: principal_id, agent_id: principal_id}

    on_exit(fn ->
      _ = WorkspaceLeaseRegistry.release(lease.workspace_id, :remove, context)
    end)

    %{lease: lease, context: context, repo: repo}
  end

  defp create_tiny_project(path) do
    File.mkdir_p!(Path.join(path, "lib"))
    File.mkdir_p!(Path.join(path, "test"))

    File.write!(Path.join(path, "mix.exs"), """
    defmodule Tiny.MixProject do
      use Mix.Project
      def project, do: [app: :tiny, version: "0.0.1", elixir: "~> 1.14"]
    end
    """)

    File.write!(
      Path.join([path, "lib", "tiny.ex"]),
      "defmodule Tiny do\n  def hi, do: :hi\nend\n"
    )

    File.write!(Path.join([path, "test", "test_helper.exs"]), "ExUnit.start()\n")
    path
  end

  defp git!(path, args) do
    {output, 0} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
    String.trim(output)
  end

  defp git_raw!(path, args) do
    {output, 0} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
    output
  end

  defp private_dir?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :directory, mode: mode}} ->
        Bitwise.band(mode, 0o777) == 0o700

      _ ->
        false
    end
  end

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  defp path_equals_or_contains?(a, b)
       when is_binary(a) and is_binary(b) and a != "" and b != "" do
    a == b or String.starts_with?(a, b <> "/") or String.starts_with?(b, a <> "/")
  end

  defp path_equals_or_contains?(_, _), do: false

  defp assert_eventually(fun, attempts \\ 100)
  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(25)
          assert_eventually(fun, attempts - 1)
        )
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp drain_tree_binding_git_operations(acc) do
    receive do
      {:tree_binding_git, operation} ->
        drain_tree_binding_git_operations([operation | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
