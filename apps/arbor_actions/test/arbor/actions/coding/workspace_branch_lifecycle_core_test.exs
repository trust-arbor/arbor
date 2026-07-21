defmodule Arbor.Actions.Coding.WorkspaceBranchLifecycleCoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Actions.Coding.WorkspaceBranchLifecycleCore, as: Core

  @moduletag :fast
  @moduletag :security_regression

  @base "0123456789abcdef0123456789abcdef01234567"
  @other "fedcba9876543210fedcba9876543210fedcba98"

  describe "normalize_provenance/1" do
    test "accepts the closed set in atom and string form, defaults unknown" do
      assert Core.normalize_provenance(:created) == :created
      assert Core.normalize_provenance("created") == :created
      assert Core.normalize_provenance(:reused) == :reused
      assert Core.normalize_provenance("reused") == :reused
      assert Core.normalize_provenance(:unknown) == :unknown
      assert Core.normalize_provenance(nil) == :unknown
      assert Core.normalize_provenance("bogus") == :unknown
    end
  end

  describe "normalize_phase/1" do
    test "accepts worktree and branch in atom and string form" do
      assert Core.normalize_phase(:worktree) == {:ok, :worktree}
      assert Core.normalize_phase("branch") == {:ok, :branch}
      assert Core.normalize_phase(nil) == :invalid
      assert Core.normalize_phase("bogus") == :invalid
    end
  end

  describe "branch_phase_decision/3 decision matrix" do
    test "reused provenance never selects delete" do
      assert Core.branch_phase_decision(:reused, {:present, @base}, @base) ==
               {:settle_preserve_branch, :branch_provenance_not_created}

      assert Core.branch_phase_decision(:reused, :absent, @base) ==
               {:settle_preserve_branch, :branch_provenance_not_created}
    end

    test "unknown provenance never selects delete" do
      assert Core.branch_phase_decision(:unknown, {:present, @base}, @base) ==
               {:settle_preserve_branch, :branch_provenance_not_created}
    end

    test "created + absent is idempotent settle with branch retired" do
      assert Core.branch_phase_decision(:created, :absent, @base) ==
               {:settle_complete, branch_retired: true, branch_preserved_reason: nil}
    end

    test "created + matching OID authorizes a destructive delete attempt" do
      assert Core.branch_phase_decision(:created, {:present, @base}, @base) ==
               {:attempt_delete, @base}
    end

    test "created + divergent tip selects dormant preserve (non-retryable)" do
      assert Core.branch_phase_decision(:created, {:present, @other}, @base) ==
               {:dormant_preserve_branch, :branch_tip_diverged}
    end

    test "created + observation error selects retryable retry" do
      assert Core.branch_phase_decision(:created, {:error, :git_rev_parse_ref_failed}, @base) ==
               {:retry_branch_phase, {:observation_failed, :git_rev_parse_ref_failed}}
    end

    test "base_commit is normalized case-insensitively for the CAS compare" do
      upper = String.upcase(@base)

      assert Core.branch_phase_decision(:created, {:present, @base}, upper) ==
               {:attempt_delete, @base}
    end
  end

  describe "classify_delete_outcome/1" do
    test "success settles with branch retired" do
      assert Core.classify_delete_outcome(:ok) ==
               {:settle_complete, branch_retired: true, branch_preserved_reason: nil}
    end

    test "CAS mismatch is non-retryable dormant preserve" do
      assert Core.classify_delete_outcome({:error, :branch_ref_oid_mismatch}) ==
               {:dormant_preserve_branch, :branch_ref_oid_mismatch}
    end

    test "checked-out is retryable" do
      assert Core.classify_delete_outcome({:error, :branch_checked_out}) ==
               {:retry_branch_phase, :branch_checked_out}
    end

    test "operational errors are retryable and wrapped" do
      assert Core.classify_delete_outcome({:error, :enoent}) ==
               {:retry_branch_phase, {:branch_retire_failed, :enoent}}
    end
  end

  describe "resolve_retry/3" do
    test "retryable decision retries while budget remains" do
      assert Core.resolve_retry({:retry_branch_phase, :branch_checked_out}, 1, 8) ==
               {:retry, :branch_checked_out}
    end

    test "retryable decision goes dormant when budget is exhausted" do
      assert Core.resolve_retry({:retry_branch_phase, :branch_checked_out}, 8, 8) ==
               {:dormant, :branch_checked_out}
    end

    test "non-retryable decisions pass through as terminal" do
      assert Core.resolve_retry({:dormant_preserve_branch, :branch_tip_diverged}, 0, 8) ==
               {:terminal, {:dormant_preserve_branch, :branch_tip_diverged}}

      assert Core.resolve_retry({:settle_complete, branch_retired: true}, 3, 8) ==
               {:terminal, {:settle_complete, branch_retired: true}}
    end
  end

  describe "dormant_on_hydrate?/3" do
    test "branch phase is dormant once budget is exhausted so restart cannot retry" do
      assert Core.dormant_on_hydrate?(:branch, 8, 8) == true
      assert Core.dormant_on_hydrate?(:branch, 9, 8) == true
      assert Core.dormant_on_hydrate?(:branch, 7, 8) == false
    end

    test "worktree phase is dormant once budget is exhausted" do
      assert Core.dormant_on_hydrate?(:worktree, 8, 8) == true
      assert Core.dormant_on_hydrate?(:worktree, 0, 8) == false
    end

    test "worktree phase exhaustion preserves worktree identity on restart" do
      # When worktree-phase retries are exhausted, dormancy must be reported
      # so the shell keeps the dormant marker in worktree phase with identity
      # evidence — it must not silently advance to branch or claim settlement.
      assert Core.dormant_on_hydrate?(:worktree, 3, 3) == true
      assert Core.dormant_on_hydrate?(:worktree, 5, 3) == true
      assert Core.dormant_on_hydrate?(:worktree, 2, 3) == false
    end

    test "unknown phase fails closed to dormant" do
      assert Core.dormant_on_hydrate?(:invalid, 0, 8) == true
    end
  end

  describe "force_exhausted/2" do
    test "lifts retry_count to the configured limit without lowering it" do
      assert Core.force_exhausted(0, 8) == 8
      assert Core.force_exhausted(3, 8) == 8
      assert Core.force_exhausted(10, 8) == 10
    end
  end

  describe "advance_to_branch_phase/1" do
    test "drops identity and clears cleanup failure for the branch phase" do
      marker = %{
        lifecycle: :discarding,
        discard_phase: :worktree,
        lstat_identity: %{inode: 1},
        worktree_registration: %{path: "p"},
        cleanup_failure: :old,
        dormant: true,
        keep: 1
      }

      advanced = Core.advance_to_branch_phase(marker)

      assert advanced.lifecycle == :discarding
      assert advanced.discard_phase == :branch
      assert advanced.lstat_identity == nil
      assert advanced.worktree_registration == nil
      assert advanced.cleanup_failure == nil
      assert advanced.dormant == false
      assert advanced.keep == 1
    end
  end

  describe "discarding?/1" do
    test "detects discarding markers in atom and string form" do
      assert Core.discarding?(%{lifecycle: :discarding})
      assert Core.discarding?(%{lifecycle: "discarding"})
      refute Core.discarding?(%{lifecycle: :retained})
      refute Core.discarding?(%{})
    end
  end

  describe "security regression: full created+divergent decision chain" do
    test "never authorizes delete and lands on dormant preserve across retries" do
      decision = Core.branch_phase_decision(:created, {:present, @other}, @base)

      # Divergent tip is terminal-dormant; resolve_retry must not reclassify it.
      assert decision == {:dormant_preserve_branch, :branch_tip_diverged}
      assert Core.resolve_retry(decision, 0, 8) == {:terminal, decision}
    end
  end
end
