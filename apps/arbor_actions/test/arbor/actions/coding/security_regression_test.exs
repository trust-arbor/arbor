defmodule Arbor.Actions.Coding.SecurityRegressionTest do
  use Arbor.Actions.ActionCase, async: false

  alias Arbor.Actions.Coding.SecurityRegression.Validate
  alias Arbor.Actions.Council
  alias Arbor.Actions.Coding.Workspace
  alias Arbor.Actions.Coding.WorkspaceLeaseRegistry
  alias Arbor.Common.SafePath

  @moduletag :slow

  setup_all do
    # Production Shell fails closed for spawn_capable until a streaming control
    # plane exists. These behavioral two-revision proofs need a trusted finite
    # Mix fixture executor (TestMixShell), same seam as Mix action tests.
    previous_shell_module = Application.get_env(:arbor_actions, :mix_shell_module)
    Application.put_env(:arbor_actions, :mix_shell_module, Arbor.Actions.TestMixShell)

    on_exit(fn ->
      if is_nil(previous_shell_module) do
        Application.delete_env(:arbor_actions, :mix_shell_module)
      else
        Application.put_env(:arbor_actions, :mix_shell_module, previous_shell_module)
      end
    end)

    :ok
  end

  test "reviewed candidate-pass/base-fail evidence is detached, one-shot, and cleaned", %{
    tmp_dir: tmp_dir
  } do
    fixture =
      leased_project(tmp_dir, "defmodule Tiny.Security do\n  def allow_guest?, do: true\nend\n")

    write_candidate_module(
      fixture,
      "defmodule Tiny.Security do\n  def allow_guest?, do: false\nend\n"
    )

    test_path = "test/security_regression_test.exs"

    write_candidate_test(fixture, test_path, """
    defmodule Tiny.SecurityRegressionTest do
      use ExUnit.Case
      test "guest remains denied", do: refute(Tiny.Security.allow_guest?())
    end
    """)

    params = fixture |> attested_params([test_path]) |> Map.put(:timeout, "600000")
    assert {:ok, result} = Validate.run(params, fixture.context)
    assert result.passed
    assert result.reason == "security_regression_validated"
    assert result.evidence_type == "reviewed_regression_evidence"
    assert result.base.test_failures == 1
    assert {:error, :attestation_already_claimed} = Validate.run(params, fixture.context)

    assert {:ok, []} =
             WorkspaceLeaseRegistry.validation_resources(
               fixture.lease.workspace_id,
               fixture.context
             )
  end

  test "absolute source-internal dependency links are rewritten into private snapshots", %{
    tmp_dir: tmp_dir
  } do
    fixture = leased_project(tmp_dir, valid_module())
    source_deps = Path.join(fixture.repo, "deps")
    internal = Path.join(source_deps, "internal")
    File.mkdir_p!(internal)
    File.write!(Path.join(internal, "source"), "original")
    helper = Path.join(source_deps, "build-helper")
    File.write!(helper, "#!/bin/sh\nexit 0\n")
    File.chmod!(helper, 0o755)
    File.ln_s!(internal, Path.join(source_deps, "linked"))

    assert {:ok, resource} =
             WorkspaceLeaseRegistry.acquire_validation_resource(
               fixture.lease.workspace_id,
               fixture.context
             )

    candidate_link = Path.join(resource.candidate_deps_path, "linked")
    base_link = Path.join(resource.base_deps_path, "linked")

    assert path_inside?(
             Path.expand(File.read_link!(candidate_link), Path.dirname(candidate_link)),
             resource.candidate_deps_path
           )

    assert path_inside?(
             Path.expand(File.read_link!(base_link), Path.dirname(base_link)),
             resource.base_deps_path
           )

    assert Bitwise.band(
             File.stat!(Path.join(resource.candidate_deps_path, "build-helper")).mode,
             0o111
           ) ==
             0o111

    File.write!(Path.join(candidate_link, "candidate-mutation"), "candidate")
    refute File.exists?(Path.join(internal, "candidate-mutation"))
    refute File.exists?(Path.join(base_link, "candidate-mutation"))

    assert {:ok, _} =
             WorkspaceLeaseRegistry.release_validation_resource(
               resource.resource_id,
               fixture.context
             )
  end

  test "validation resource paths canonicalize a symlinked temporary directory", %{
    tmp_dir: tmp_dir
  } do
    fixture = leased_project(tmp_dir, valid_module())
    real_tmp = Path.join(tmp_dir, "real-tmp")
    alias_tmp = Path.join(tmp_dir, "alias-tmp")
    File.mkdir_p!(real_tmp)
    File.ln_s!(real_tmp, alias_tmp)
    previous_tmpdir = System.get_env("TMPDIR")

    System.put_env("TMPDIR", alias_tmp)

    try do
      assert {:ok, resource} =
               WorkspaceLeaseRegistry.acquire_validation_resource(
                 fixture.lease.workspace_id,
                 fixture.context
               )

      try do
        assert {:ok, canonical_tmp} = SafePath.resolve_real(real_tmp)
        assert {:ok, canonical_root} = SafePath.resolve_real(resource.root_path)
        assert resource.root_path == canonical_root
        assert Path.dirname(resource.root_path) == canonical_tmp

        for path <- [
              resource.candidate_build_path,
              resource.candidate_deps_path,
              resource.base_build_path,
              resource.base_deps_path
            ] do
          assert path_inside?(path, resource.root_path)
        end
      after
        assert {:ok, _} =
                 WorkspaceLeaseRegistry.release_validation_resource(
                   resource.resource_id,
                   fixture.context
                 )
      end
    after
      if previous_tmpdir,
        do: System.put_env("TMPDIR", previous_tmpdir),
        else: System.delete_env("TMPDIR")
    end
  end

  test "validator accepts neither workspace_id nor test_paths and failed claim spawns no candidate code",
       %{tmp_dir: tmp_dir} do
    fixture = leased_project(tmp_dir, valid_module())
    marker = Path.join(tmp_dir, "candidate-ran")
    test_path = "test/no_spawn_test.exs"

    write_candidate_test(fixture, test_path, """
    defmodule Tiny.NoSpawnTest do
      use ExUnit.Case
      test "would run", do: File.write!(#{inspect(marker)}, "ran")
    end
    """)

    assert {:error, :unsupported_parameter} =
             Validate.run(
               %{workspace_id: fixture.lease.workspace_id, test_paths: [test_path]},
               fixture.context
             )

    assert {:error, :not_found} =
             Validate.run(%{review_attestation_id: "review_attestation_missing"}, fixture.context)

    for invalid_timeout <- ["600001", "not-an-integer"] do
      assert {:error, :invalid_timeout} =
               Validate.run(
                 %{
                   review_attestation_id: "review_attestation_missing",
                   timeout: invalid_timeout
                 },
                 fixture.context
               )
    end

    refute File.exists?(marker)
  end

  test "base-pass, candidate-failure, and compile failure retain two-revision behavior", %{
    tmp_dir: tmp_dir
  } do
    fixture = leased_project(tmp_dir, valid_module())
    base_pass = "test/base_pass_test.exs"

    write_candidate_test(fixture, base_pass, """
    defmodule Tiny.BasePassTest do
      use ExUnit.Case
      test "denied", do: refute(Tiny.Security.allow_guest?())
    end
    """)

    assert {:ok, base_result} =
             Validate.run(attested_params(fixture, [base_pass]), fixture.context)

    assert base_result.reason == "base_tests_passed"

    fixture =
      leased_project(tmp_dir, "defmodule Tiny.Security do\n  def allow_guest?, do: true\nend\n")

    candidate_failure = "test/candidate_failure_test.exs"

    write_candidate_test(fixture, candidate_failure, """
    defmodule Tiny.CandidateFailureTest do
      use ExUnit.Case
      test "denied", do: refute(Tiny.Security.allow_guest?())
    end
    """)

    assert {:ok, candidate_result} =
             Validate.run(attested_params(fixture, [candidate_failure]), fixture.context)

    assert candidate_result.reason == "candidate_tests_failed"
    assert candidate_result.base.status == "not_run"

    fixture = leased_project(tmp_dir, valid_module())
    compile_failure = "test/compile_failure_test.exs"
    write_candidate_test(fixture, compile_failure, "defmodule Broken do\n  this is not valid\n")

    assert {:ok, compile_result} =
             Validate.run(attested_params(fixture, [compile_failure]), fixture.context)

    assert compile_result.reason == "candidate_suite_incomplete"
    assert compile_result.base.status == "not_run"
  end

  test "setup failures, zero tests, and stale candidate BEAMs remain fail-closed", %{
    tmp_dir: tmp_dir
  } do
    fixture = leased_project(tmp_dir, "defmodule Tiny.Security do\n  def phase, do: :base\nend\n")

    write_candidate_module(
      fixture,
      "defmodule Tiny.Security do\n  def phase, do: :candidate\nend\n"
    )

    setup_path = "test/setup_failure_test.exs"

    write_candidate_test(fixture, setup_path, """
    defmodule Tiny.SetupFailureTest do
      use ExUnit.Case
      setup_all do
        if Tiny.Security.phase() == :base, do: raise("base setup failed")
        :ok
      end
      test "candidate", do: assert(Tiny.Security.phase() == :candidate)
    end
    """)

    assert {:ok, setup_result} =
             Validate.run(attested_params(fixture, [setup_path]), fixture.context)

    assert setup_result.reason == "base_setup_failed"
    assert setup_result.base.test_failures == 0

    fixture = leased_project(tmp_dir, valid_module())
    zero_path = "test/zero_test.exs"

    write_candidate_test(
      fixture,
      zero_path,
      "defmodule Tiny.ZeroTest do\n  use ExUnit.Case\nend\n"
    )

    assert {:ok, zero_result} =
             Validate.run(attested_params(fixture, [zero_path]), fixture.context)

    assert zero_result.reason == "candidate_zero_tests"

    fixture = leased_project(tmp_dir, valid_module())

    File.write!(
      Path.join(fixture.lease.worktree_path, "lib/candidate_only.ex"),
      "defmodule Tiny.CandidateOnly do\n  def fixed?, do: true\nend\n"
    )

    git!(fixture.lease.worktree_path, ["add", "lib/candidate_only.ex"])
    git!(fixture.lease.worktree_path, ["commit", "-m", "candidate-only"])
    beam_path = "test/isolated_beam_test.exs"

    write_candidate_test(fixture, beam_path, """
    defmodule Tiny.IsolatedBeamTest do
      use ExUnit.Case
      test "candidate only", do: assert(Tiny.CandidateOnly.fixed?())
    end
    """)

    assert {:ok, beam_result} =
             Validate.run(attested_params(fixture, [beam_path]), fixture.context)

    assert beam_result.passed
    assert beam_result.base.test_failures == 1
  end

  test "post-review HEAD replacement and selected-test blob replacement are denied before spawn",
       %{tmp_dir: tmp_dir} do
    fixture = leased_project(tmp_dir, valid_module())
    test_path = "test/reviewed_test.exs"

    write_candidate_test(fixture, test_path, """
    defmodule Tiny.ReviewedTest do
      use ExUnit.Case
      test "ok", do: assert(true)
    end
    """)

    params = attested_params(fixture, [test_path])

    File.write!(Path.join(fixture.lease.worktree_path, test_path), "defmodule Replaced do\nend\n")
    git!(fixture.lease.worktree_path, ["add", test_path])
    git!(fixture.lease.worktree_path, ["commit", "-m", "replace reviewed test"])

    assert {:error, :reviewed_material_changed} = Validate.run(params, fixture.context)
  end

  test "wrong task or principal cannot claim an attestation", %{tmp_dir: tmp_dir} do
    fixture = leased_project(tmp_dir, valid_module())
    test_path = "test/authority_test.exs"

    write_candidate_test(fixture, test_path, """
    defmodule Tiny.AuthorityTest do
      use ExUnit.Case
      test "ok", do: assert(true)
    end
    """)

    params = attested_params(fixture, [test_path])

    assert {:error, :not_authorized} =
             Task.async(fn ->
               Validate.run(params, %{
                 task_id: fixture.context.task_id,
                 agent_id: "different-agent"
               })
             end)
             |> Task.await(10_000)

    assert {:error, :not_authorized} =
             Task.async(fn ->
               Validate.run(params, %{
                 task_id: "different-task",
                 agent_id: fixture.context.agent_id
               })
             end)
             |> Task.await(10_000)
  end

  test "concurrent claim allows exactly one caller", %{tmp_dir: tmp_dir} do
    fixture = leased_project(tmp_dir, valid_module())
    test_path = "test/claim_test.exs"

    write_candidate_test(fixture, test_path, """
    defmodule Tiny.ClaimTest do
      use ExUnit.Case
      test "ok", do: assert(true)
    end
    """)

    %{review_attestation_id: id} = attested_params(fixture, [test_path])

    results =
      for _ <- 1..2 do
        Task.async(fn -> WorkspaceLeaseRegistry.claim_review_attestation(id, fixture.context) end)
      end
      |> Enum.map(&Task.await(&1, 10_000))

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, :attestation_already_claimed}, &1)) == 1

    for {:ok, %{resource: resource}} <- results do
      assert {:ok, _} =
               WorkspaceLeaseRegistry.release_validation_resource(
                 resource.resource_id,
                 fixture.context
               )
    end
  end

  test "candidate dependency mutation does not alter base dependency evidence", %{
    tmp_dir: tmp_dir
  } do
    fixture =
      leased_project(tmp_dir, "defmodule Tiny.Security do\n  def allow_guest?, do: true\nend\n")

    write_candidate_module(
      fixture,
      "defmodule Tiny.Security do\n  def allow_guest?, do: false\nend\n"
    )

    test_path = "test/dependency_isolation_test.exs"

    write_candidate_test(fixture, test_path, """
    defmodule Tiny.DependencyIsolationTest do
      use ExUnit.Case
      test "dependency snapshot is revision-private" do
        marker = Path.join(System.fetch_env!("MIX_DEPS_PATH"), "candidate-marker")
        if Tiny.Security.allow_guest?(), do: refute(File.exists?(marker)), else: File.write!(marker, "candidate")
        refute Tiny.Security.allow_guest?()
      end
    end
    """)

    assert {:ok, result} = Validate.run(attested_params(fixture, [test_path]), fixture.context)
    assert result.passed
    assert result.base.test_failures == 1
  end

  test "selected symlink sources and empty selections fail before candidate execution", %{
    tmp_dir: tmp_dir
  } do
    fixture = leased_project(tmp_dir, valid_module())

    File.write!(
      Path.join(fixture.lease.worktree_path, "test/real_source.exs"),
      "defmodule Tiny.RealSource do\nend\n"
    )

    File.ln_s!("real_source.exs", Path.join(fixture.lease.worktree_path, "test/symlink_test.exs"))
    git!(fixture.lease.worktree_path, ["add", "test/real_source.exs", "test/symlink_test.exs"])
    git!(fixture.lease.worktree_path, ["commit", "-m", "symlink source"])

    assert {:error, :test_path_symlink} =
             Validate.run(attested_params(fixture, ["test/symlink_test.exs"]), fixture.context)

    assert {:error, :invalid_selected_test_paths} =
             Workspace.materialize_security_regression_material(
               fixture.lease.worktree_path,
               fixture.lease.workspace_id,
               fixture.lease.base_commit,
               []
             )
  end

  test "normal resource release cleans detached snapshots and action metadata remains process-spawn",
       %{
         tmp_dir: tmp_dir
       } do
    fixture = leased_project(tmp_dir, valid_module())

    assert {:ok, resource} =
             WorkspaceLeaseRegistry.acquire_validation_resource(
               fixture.lease.workspace_id,
               fixture.context
             )

    assert {:ok, snapshot} =
             WorkspaceLeaseRegistry.create_validation_snapshot(
               resource.resource_id,
               fixture.context
             )

    assert {:ok, %{status: "removed"}} =
             WorkspaceLeaseRegistry.release_validation_resource(
               resource.resource_id,
               fixture.context
             )

    refute File.exists?(snapshot.root_path)
    refute File.exists?(snapshot.base_worktree_path)
    assert Validate.name() == "coding_security_regression_validate"
    assert Validate.category() == "coding"
    assert Validate.effect_class() == :process_spawn
  end

  test "lease release and owner death discard private attestations", %{tmp_dir: tmp_dir} do
    fixture = leased_project(tmp_dir, valid_module())
    test_path = "test/cleanup_test.exs"

    write_candidate_test(fixture, test_path, """
    defmodule Tiny.CleanupTest do
      use ExUnit.Case
      test "ok", do: assert(true)
    end
    """)

    %{review_attestation_id: id} = attested_params(fixture, [test_path])

    assert {:ok, _} =
             WorkspaceLeaseRegistry.release(fixture.lease.workspace_id, :retain, fixture.context)

    assert {:error, :not_found} =
             WorkspaceLeaseRegistry.claim_review_attestation(id, fixture.context)
  end

  test "forced dependency snapshot failure cleans the actual private root", %{tmp_dir: tmp_dir} do
    fixture = leased_project(tmp_dir, valid_module())
    before = validation_roots()

    assert {:error, :dependency_snapshot_failed} =
             WorkspaceLeaseRegistry.acquire_validation_resource(
               fixture.lease.workspace_id,
               Map.put(fixture.context, :force_dependency_snapshot_failure, true)
             )

    assert validation_roots() == before

    assert {:ok, []} =
             WorkspaceLeaseRegistry.validation_resources(
               fixture.lease.workspace_id,
               fixture.context
             )
  end

  test "cleanup failure retains attestation, resource, and parent lease until explicit retry", %{
    tmp_dir: tmp_dir
  } do
    fixture = leased_project(tmp_dir, valid_module())
    test_path = "test/cleanup_retry_test.exs"

    write_candidate_test(fixture, test_path, """
    defmodule Tiny.CleanupRetryTest do
      use ExUnit.Case
      test "ok", do: assert(true)
    end
    """)

    %{review_attestation_id: id} = attested_params(fixture, [test_path])

    assert {:ok, %{resource: resource}} =
             WorkspaceLeaseRegistry.claim_review_attestation(
               id,
               Map.put(fixture.context, :cleanup_failures, 2)
             )

    assert {:error, :validation_resource_cleanup_failed} =
             WorkspaceLeaseRegistry.release_validation_resource(
               resource.resource_id,
               fixture.context
             )

    assert {:ok, [retained]} =
             WorkspaceLeaseRegistry.validation_resources(
               fixture.lease.workspace_id,
               fixture.context
             )

    assert retained.resource_id == resource.resource_id
    assert File.dir?(retained.root_path)

    assert {:ok, _material} =
             WorkspaceLeaseRegistry.finalize_review_attestation(id, fixture.context)

    assert {:error, :validation_resource_cleanup_failed} =
             WorkspaceLeaseRegistry.release(
               fixture.lease.workspace_id,
               :retain,
               fixture.context
             )

    assert {:ok, _lease} =
             WorkspaceLeaseRegistry.inspect_lease(
               fixture.lease.workspace_id,
               fixture.context
             )

    assert {:ok, %{status: "removed"}} =
             WorkspaceLeaseRegistry.release_validation_resource(
               resource.resource_id,
               fixture.context
             )

    refute File.exists?(retained.root_path)

    assert {:ok, _released} =
             WorkspaceLeaseRegistry.release(
               fixture.lease.workspace_id,
               :retain,
               fixture.context
             )

    assert {:error, :not_found} =
             WorkspaceLeaseRegistry.finalize_review_attestation(id, fixture.context)
  end

  test "partial setup plus rollback failure retains the candidate root for retry", %{
    tmp_dir: tmp_dir
  } do
    fixture = leased_project(tmp_dir, valid_module())
    test_path = "test/partial_cleanup_test.exs"

    write_candidate_test(fixture, test_path, """
    defmodule Tiny.PartialCleanupTest do
      use ExUnit.Case
      test "ok", do: assert(true)
    end
    """)

    %{review_attestation_id: id} = attested_params(fixture, [test_path])

    assert {:error, :validation_resource_setup_failed_cleanup_retained} =
             WorkspaceLeaseRegistry.claim_review_attestation(
               id,
               fixture.context
               |> Map.put(:force_dependency_snapshot_failure, true)
               |> Map.put(:force_partial_cleanup_failure_once, true)
             )

    assert {:ok, [resource]} =
             WorkspaceLeaseRegistry.validation_resources(
               fixture.lease.workspace_id,
               fixture.context
             )

    assert resource.setup_status == "setup_failed"
    assert File.dir?(resource.root_path)
    assert File.dir?(resource.candidate_path)

    assert {:ok, _material} =
             WorkspaceLeaseRegistry.finalize_review_attestation(id, fixture.context)

    assert {:ok, %{status: "removed"}} =
             WorkspaceLeaseRegistry.release_validation_resource(
               resource.resource_id,
               fixture.context
             )

    refute File.exists?(resource.root_path)
    refute File.exists?(resource.candidate_path)
  end

  test "workspace owner death retains failed child and task-principal recovery authority", %{
    tmp_dir: tmp_dir
  } do
    repo = create_base_project(Path.join(tmp_dir, "owner-cleanup-repo"), valid_module())
    server = :"cleanup_owner_death_#{System.unique_integer([:positive])}"
    start_supervised!({WorkspaceLeaseRegistry, name: server})
    task_id = "task-cleanup-owner-death"
    principal_id = "agent-cleanup-owner-death"
    recovery = %{server: server, task_id: task_id, principal_id: principal_id}
    parent = self()

    owner =
      spawn(fn ->
        result =
          WorkspaceLeaseRegistry.acquire(
            %{
              repo_path: repo,
              branch: "test/cleanup-owner-death",
              task_id: task_id,
              principal_id: principal_id,
              worktree_base_dir: Path.join(tmp_dir, "cleanup-owner-worktrees")
            },
            server: server
          )

        send(parent, {:owner_lease, result})
        Process.sleep(:infinity)
      end)

    assert_receive {:owner_lease, {:ok, lease}}, 5_000

    assert {:ok, resource} =
             WorkspaceLeaseRegistry.acquire_validation_resource(
               lease.workspace_id,
               Map.put(recovery, :force_cleanup_failure_once, true)
             )

    Process.exit(owner, :kill)

    assert_eventually(fn ->
      state = :sys.get_state(server)

      case Map.get(state.leases, lease.workspace_id) do
        nil -> false
        retained_lease -> not Map.has_key?(state.by_ref, retained_lease.owner_ref)
      end
    end)

    assert {:ok, _lease} =
             WorkspaceLeaseRegistry.inspect_lease(lease.workspace_id, recovery)

    assert {:ok, [retained]} =
             WorkspaceLeaseRegistry.validation_resources(lease.workspace_id, recovery)

    assert retained.resource_id == resource.resource_id
    assert File.dir?(retained.root_path)

    assert {:ok, %{status: "removed"}} =
             WorkspaceLeaseRegistry.release_validation_resource(resource.resource_id, recovery)

    assert {:ok, _released} =
             WorkspaceLeaseRegistry.release(lease.workspace_id, :remove, recovery)
  end

  test "council issues only after approved quorum routing and compares the reviewed full diff", %{
    tmp_dir: tmp_dir
  } do
    fixture = leased_project(tmp_dir, valid_module())
    test_path = "test/council_bound_test.exs"

    write_candidate_test(fixture, test_path, """
    defmodule Tiny.CouncilBoundTest do
      use ExUnit.Case
      test "ok", do: assert(true)
    end
    """)

    {:ok, material} =
      Workspace.materialize_security_regression_material(
        fixture.lease.worktree_path,
        fixture.lease.workspace_id,
        fixture.lease.base_commit,
        [test_path]
      )

    params = %{
      diff: material.diff,
      files: [test_path],
      branch: fixture.lease.branch,
      base_ref: fixture.lease.base_commit,
      intent: "prove reviewed tree",
      agent_id: fixture.context.agent_id,
      workspace_id: fixture.lease.workspace_id,
      commit_hash: material.candidate_commit,
      test_paths: [test_path],
      validation_profile: "security_regression"
    }

    approved = %{
      decision: "approved",
      approve_count: 3,
      reject_count: 0,
      abstain_count: 0,
      quorum_met: true
    }

    context =
      Map.merge(fixture.context, %{
        persist_verdict: false,
        review_runner: fn _request, _params, _context -> {:ok, approved} end
      })

    assert {:ok, %{review_attestation_id: id, tier_decision: "auto_proceed"}} =
             Council.ReviewChange.run(params, context)

    assert {:ok, _} = WorkspaceLeaseRegistry.claim_review_attestation(id, fixture.context)

    assert {:ok, %{review_attestation_id: _id, tier_decision: "human_review"}} =
             Council.ReviewChange.run(
               params,
               Map.put(context, :authority_widening?, true)
             )

    for decision <- [
          %{approved | decision: "rejected", approve_count: 0, reject_count: 3},
          %{approved | decision: "deadlock", approve_count: 1, reject_count: 1, quorum_met: false}
        ] do
      assert {:ok, result} =
               Council.ReviewChange.run(
                 params,
                 %{context | review_runner: fn _, _, _ -> {:ok, decision} end}
               )

      refute Map.has_key?(result, :review_attestation_id)
    end
  end

  test "security regression: council attestation binds completed ledger findings, not the incoming ledger",
       %{
         tmp_dir: tmp_dir
       } do
    fixture = leased_project(tmp_dir, valid_module())
    test_path = "test/council_completed_ledger_test.exs"

    write_candidate_test(fixture, test_path, """
    defmodule Tiny.CouncilCompletedLedgerTest do
      use ExUnit.Case
      test "ok", do: assert(true)
    end
    """)

    {:ok, material} =
      Workspace.materialize_security_regression_material(
        fixture.lease.worktree_path,
        fixture.lease.workspace_id,
        fixture.lease.base_commit,
        [test_path]
      )

    incoming_ledger = %{"findings" => %{}}

    params = %{
      diff: material.diff,
      files: [test_path],
      branch: fixture.lease.branch,
      base_ref: fixture.lease.base_commit,
      intent: "bind completed review ledger",
      agent_id: fixture.context.agent_id,
      workspace_id: fixture.lease.workspace_id,
      commit_hash: material.candidate_commit,
      test_paths: [test_path],
      validation_profile: "security_regression",
      review_cycle: 1,
      finding_ledger: incoming_ledger
    }

    completed_ledger = completed_review_ledger("New contract finding")

    decision = %{
      decision: "approved",
      approve_count: 3,
      reject_count: 0,
      abstain_count: 0,
      quorum_met: true,
      review_cycle: 1,
      finding_ledger: completed_ledger,
      review_disposition: "accept",
      blocking_ids: [],
      blocking_reasons: [],
      human_required: false
    }

    context =
      Map.merge(fixture.context, %{
        persist_verdict: false,
        review_runner: fn _request, _params, _context -> {:ok, decision} end
      })

    assert {:ok, %{review_attestation_id: first_id} = result} =
             Council.ReviewChange.run(params, context)

    assert result.finding_ledger == completed_ledger
    assert [%{"id" => "completed-finding"}] = result.feedback["review"]["active_findings"]

    assert {:ok, %{council_decision_digest: first_digest}} =
             WorkspaceLeaseRegistry.claim_review_attestation(first_id, fixture.context)

    changed_ledger = completed_review_ledger("Changed completed finding")

    changed_decision = %{
      decision
      | finding_ledger: changed_ledger
    }

    changed_context = %{
      context
      | review_runner: fn _request, _params, _context -> {:ok, changed_decision} end
    }

    assert {:ok, %{review_attestation_id: second_id}} =
             Council.ReviewChange.run(params, changed_context)

    assert {:ok, %{council_decision_digest: second_digest}} =
             WorkspaceLeaseRegistry.claim_review_attestation(second_id, fixture.context)

    refute first_digest == second_digest
  end

  test "owner death removes its private attestation records", %{tmp_dir: tmp_dir} do
    repo = create_base_project(Path.join(tmp_dir, "owner-death-repo"), valid_module())
    server = :"attestation_owner_death_#{System.unique_integer([:positive])}"
    start_supervised!({WorkspaceLeaseRegistry, name: server})
    task_id = "task-owner-death"
    principal_id = "agent-owner-death"
    parent = self()

    owner =
      spawn(fn ->
        {:ok, lease} =
          WorkspaceLeaseRegistry.acquire(
            %{
              repo_path: repo,
              branch: "test/attestation-owner-death",
              task_id: task_id,
              principal_id: principal_id,
              worktree_base_dir: Path.join(tmp_dir, "owner-death-worktrees")
            },
            server: server
          )

        test_path = "test/owner_death_test.exs"
        path = Path.join(lease.worktree_path, test_path)

        File.write!(path, """
        defmodule Tiny.OwnerDeathTest do
          use ExUnit.Case
          test "ok", do: assert(true)
        end
        """)

        git!(lease.worktree_path, ["add", test_path])
        git!(lease.worktree_path, ["commit", "-m", "owner death test"])

        {:ok, material} =
          Workspace.materialize_security_regression_material(
            lease.worktree_path,
            lease.workspace_id,
            lease.base_commit,
            [test_path]
          )

        {:ok, %{review_attestation_id: id}} =
          WorkspaceLeaseRegistry.issue_review_attestation(
            lease.workspace_id,
            material,
            String.duplicate("a", 64),
            server: server
          )

        send(parent, {:attested_owner, id})
        Process.sleep(:infinity)
      end)

    assert_receive {:attested_owner, id}, 5_000
    Process.exit(owner, :kill)

    assert_eventually(fn ->
      WorkspaceLeaseRegistry.claim_review_attestation(id,
        server: server,
        task_id: task_id,
        principal_id: principal_id
      ) == {:error, :not_found}
    end)
  end

  defp attested_params(fixture, test_paths) do
    {:ok, material} =
      Workspace.materialize_security_regression_material(
        fixture.lease.worktree_path,
        fixture.lease.workspace_id,
        fixture.lease.base_commit,
        test_paths
      )

    digest = :crypto.hash(:sha256, "council-approved") |> Base.encode16(case: :lower)

    {:ok, %{review_attestation_id: id}} =
      WorkspaceLeaseRegistry.issue_review_attestation(
        fixture.lease.workspace_id,
        material,
        digest,
        fixture.context
      )

    %{review_attestation_id: id}
  end

  defp completed_review_ledger(title) do
    %{
      "findings" => %{
        "completed-finding" => %{
          "id" => "completed-finding",
          "owner" => "correctness",
          "severity" => "minor",
          "state" => "new_regression",
          "title" => title,
          "required_action" => "Resolve the completed finding",
          "anchor" => %{
            "path" => "test/council_completed_ledger_test.exs",
            "side" => "new",
            "line" => 3
          },
          "evidence" => "The completed council pass introduced this finding."
        }
      }
    }
  end

  defp leased_project(tmp_dir, base_module) do
    repo =
      create_base_project(
        Path.join(tmp_dir, "repo-#{System.unique_integer([:positive])}"),
        base_module
      )

    task_id = "task_security_regression_#{System.unique_integer([:positive])}"
    principal_id = "agent_security_regression_#{System.unique_integer([:positive])}"
    context = %{task_id: task_id, agent_id: principal_id}

    {:ok, lease} =
      Workspace.Acquire.run(
        %{
          repo_path: repo,
          branch_name: "test/security-#{System.unique_integer([:positive])}",
          worktree_base_dir: Path.join(tmp_dir, "worktrees")
        },
        context
      )

    on_exit(fn -> _ = WorkspaceLeaseRegistry.release(lease.workspace_id, :remove, context) end)
    %{repo: repo, lease: lease, context: context}
  end

  defp create_base_project(path, base_module) do
    create_git_repo(path)
    File.mkdir_p!(Path.join(path, "lib"))
    File.mkdir_p!(Path.join(path, "test"))

    File.write!(Path.join(path, "mix.exs"), """
    defmodule Tiny.MixProject do
      use Mix.Project
      def project, do: [app: :tiny, version: "0.1.0", elixir: "~> 1.14"]
    end
    """)

    File.write!(Path.join(path, "lib/security.ex"), base_module)
    File.write!(Path.join(path, "test/test_helper.exs"), "ExUnit.start()\n")
    git!(path, ["add", "mix.exs", "lib/security.ex", "test/test_helper.exs"])
    git!(path, ["commit", "-m", "base"])
    path
  end

  defp write_candidate_module(fixture, source) do
    File.write!(Path.join(fixture.lease.worktree_path, "lib/security.ex"), source)
    git!(fixture.lease.worktree_path, ["add", "lib/security.ex"])
    git!(fixture.lease.worktree_path, ["commit", "-m", "candidate module"])
  end

  defp write_candidate_test(fixture, relative_path, source) do
    path = Path.join(fixture.lease.worktree_path, relative_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, source)
    git!(fixture.lease.worktree_path, ["add", relative_path])
    git!(fixture.lease.worktree_path, ["commit", "-m", "candidate test"])
  end

  defp valid_module, do: "defmodule Tiny.Security do\n  def allow_guest?, do: false\nend\n"

  defp git!(path, args) do
    {output, 0} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
    String.trim(output)
  end

  defp validation_roots do
    System.tmp_dir!()
    |> File.ls!()
    |> Enum.filter(
      &(String.starts_with?(&1, "arbor-validation-") or
          String.starts_with?(&1, "arbor-security-regression-"))
    )
    |> Enum.sort()
  end

  defp path_inside?(path, root) do
    relative = Path.relative_to(path, root)
    relative != ".." and not String.starts_with?(relative, "../")
  end

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
end
