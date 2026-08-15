defmodule Arbor.Contracts.Coding.BranchLifecycleDescriptorTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Coding.BranchLifecycleDescriptor

  @moduletag :fast
  @commit String.duplicate("a", 40)

  test "normalizes complete retired evidence and optional publication proof" do
    assert {:ok, descriptor} =
             BranchLifecycleDescriptor.normalize(%{
               "branch_status" => "retired",
               "cleanup_status" => "complete",
               "evidence_ref" => "refs/arbor/evidence/task/workspace",
               "published_commit" => @commit
             })

    assert descriptor["branch_status"] == "retired"
    assert descriptor["cleanup_status"] == "complete"
    assert descriptor["published_commit"] == @commit
  end

  test "requires phase, failure, and bounded retry evidence for retrying and dormant states" do
    valid = %{
      "branch_status" => "pending",
      "cleanup_status" => "retrying",
      "cleanup_retry_count" => 0,
      "cleanup_retry_limit" => 3,
      "cleanup_failure_category" => "worktree_remove_failed",
      "discard_phase" => "worktree"
    }

    assert BranchLifecycleDescriptor.valid?(valid)

    assert BranchLifecycleDescriptor.valid?(
             Map.merge(valid, %{"cleanup_status" => "dormant", "cleanup_retry_count" => 3})
           )

    for bad <- [
          Map.put(valid, "cleanup_retry_limit", 0),
          Map.delete(valid, "cleanup_failure_category"),
          Map.delete(valid, "discard_phase"),
          Map.delete(valid, "cleanup_retry_count"),
          Map.put(valid, "cleanup_retry_count", 3),
          Map.merge(valid, %{"cleanup_status" => "dormant", "cleanup_retry_count" => 2})
        ] do
      refute BranchLifecycleDescriptor.valid?(bad)
    end
  end

  test "complete descriptors reject retry counters and cleanup phase" do
    base = %{"branch_status" => "preserved", "cleanup_status" => "complete"}

    for bad <- [
          Map.put(base, "cleanup_retry_count", 0),
          Map.put(base, "cleanup_retry_limit", 3),
          Map.put(base, "discard_phase", "branch"),
          Map.put(base, "cleanup_failure_category", "cleanup_failed"),
          Map.merge(base, %{"branch_status" => "retired", "branch_preserved_reason" => "manual"})
        ] do
      refute BranchLifecycleDescriptor.valid?(bad)
    end
  end

  test "security regression: authority-bearing and malformed fields fail closed" do
    for bad <- [
          %{"branch_status" => "retired", "cleanup_status" => "complete", "workspace_id" => "ws"},
          %{"branch_status" => "retired", "cleanup_status" => "complete", "task_id" => "task"},
          %{"branch_status" => "retired", "cleanup_status" => "complete", "command" => "git rm"},
          %{
            "branch_status" => "retired",
            "cleanup_status" => "complete",
            "evidence_ref" => "/tmp/proof"
          },
          %{
            "branch_status" => "retired",
            "cleanup_status" => "complete",
            "published_commit" => "not-an-oid"
          }
        ] do
      assert {:error, _reason} = BranchLifecycleDescriptor.new(bad)
      refute BranchLifecycleDescriptor.valid?(bad)
    end
  end
end
