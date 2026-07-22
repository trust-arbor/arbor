defmodule Arbor.Orchestrator.CodingPlan.ReconciliationCoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.CodingPlan.ReconciliationCore

  @moduletag :fast
  @observed_at "2026-07-22T17:00:00Z"

  test "applies every conservative first-slice rule and never emits remove" do
    tasks = [
      task("task-live", "running", true),
      task("task-dead", "running", false),
      task("task-terminal", "done", false)
    ]

    resources = [
      resource("live_workspace_lease", "keep-live", "task-live", "principal-1"),
      resource("live_workspace_lease", "retry-dead", "task-dead", "principal-1"),
      resource("live_workspace_lease", "settle-live", "task-terminal", "principal-1"),
      resource("validation_resource", "settle-validation", "task-terminal", "principal-1"),
      resource("retained_workspace_record", "keep-retained", "task-terminal", "principal-1",
        expires_at: "2026-07-22T18:00:00Z"
      ),
      resource("retained_workspace_record", "settle-retained", "task-terminal", "principal-1",
        expires_at: "2026-07-22T16:00:00Z"
      ),
      resource("retained_workspace_record", "quarantine-dormant", "task-terminal", "principal-1",
        dormant: true
      ),
      resource(
        "retained_workspace_record",
        "quarantine-exhausted",
        "task-terminal",
        "principal-1",
        retry_state: %{"count" => 3, "limit" => 3, "dormant" => false}
      ),
      resource("live_workspace_lease", "quarantine-missing-task", "task-missing", "principal-1"),
      resource("live_workspace_lease", "quarantine-missing-principal", "task-live", nil),
      resource("live_workspace_lease", "quarantine-ambiguous", "task-live", "principal-1",
        branch_provenance: "unknown"
      ),
      resource("quarantine", "already-quarantined", nil, nil)
    ]

    assert {:ok, manifest, digest} =
             ReconciliationCore.reconcile(
               task_inventory(tasks),
               resource_inventory(resources),
               @observed_at
             )

    decisions = Map.new(manifest["decisions"], &{&1["resource_id"], &1})

    assert decisions["keep-live"]["decision"] == "keep"
    assert decisions["keep-live"]["reason"] == "live_task_owner_alive"
    assert decisions["retry-dead"]["decision"] == "retry"
    assert decisions["settle-live"]["decision"] == "settle"
    assert decisions["settle-validation"]["decision"] == "settle"
    assert decisions["keep-retained"]["decision"] == "keep"
    assert decisions["settle-retained"]["decision"] == "settle"
    assert decisions["quarantine-dormant"]["reason"] == "dormant_resource"
    assert decisions["quarantine-exhausted"]["reason"] == "retry_exhausted"
    assert decisions["quarantine-missing-task"]["reason"] == "missing_task"

    assert decisions["quarantine-missing-principal"]["reason"] ==
             "missing_task_or_principal_provenance"

    assert decisions["quarantine-ambiguous"]["reason"] == "ambiguous_provenance"
    assert decisions["already-quarantined"]["reason"] == "existing_quarantine"
    assert manifest["counts"]["remove"] == 0
    refute Enum.any?(manifest["decisions"], &(&1["decision"] == "remove"))
    assert String.match?(digest, ~r/\A[0-9a-f]{64}\z/)
  end

  test "keeps a retained resource while retention is active and settles at expiry" do
    resources = [
      resource("retained_workspace_record", "retained", "terminal", "principal",
        expires_at: @observed_at
      )
    ]

    assert {:ok, manifest, _digest} =
             ReconciliationCore.reconcile(
               task_inventory([task("terminal", "done", false)]),
               resource_inventory(resources),
               @observed_at
             )

    assert hd(manifest["decisions"])["decision"] == "settle"
    assert hd(manifest["decisions"])["reason"] == "retained_expired"
  end

  test "quarantines every resource when the journal is degraded" do
    resources = [resource("live_workspace_lease", "degraded", "task-live", "principal")]

    inventory =
      resource_inventory(resources)
      |> put_in(["journal", "status"], "degraded")
      |> put_in(["journal", "quarantined"], true)
      |> put_in(["journal", "failure_category"], "retention_journal_poisoned")

    assert {:ok, manifest, _digest} =
             ReconciliationCore.reconcile(
               task_inventory([task("task-live", "running", true)]),
               inventory,
               @observed_at
             )

    assert hd(manifest["decisions"])["decision"] == "quarantine"
    assert hd(manifest["decisions"])["reason"] == "journal_degraded"
  end

  test "rejects inconsistent projection counts and journal status evidence" do
    tasks = task_inventory([task("task-1", "running", true)])

    resources =
      resource_inventory([resource("live_workspace_lease", "resource-1", "task-1", "principal")])

    assert {:error, :inconsistent_task_counts} =
             ReconciliationCore.reconcile(
               put_in(tasks, ["counts", "observed"], 2),
               resources,
               @observed_at
             )

    assert {:error, :inconsistent_resource_counts} =
             ReconciliationCore.reconcile(
               tasks,
               put_in(resources, ["counts", "by_type", "quarantine"], 1),
               @observed_at
             )

    assert {:error, :inconsistent_journal} =
             ReconciliationCore.reconcile(
               tasks,
               put_in(resources, ["journal", "quarantined"], true),
               @observed_at
             )

    assert {:error, :inconsistent_journal} =
             ReconciliationCore.reconcile(
               tasks,
               resources |> put_in(["journal", "status"], "degraded"),
               @observed_at
             )

    assert {:error, :inconsistent_journal} =
             ReconciliationCore.reconcile(
               tasks,
               Map.put(resources, "journal", %{
                 "status" => "complete",
                 "quarantined" => false,
                 "failure_category" => "unexpected"
               }),
               @observed_at
             )
  end

  test "accepts exact task_id scopes and rejects unmatched or broad task scopes" do
    task_inventory = task_inventory([task("task-1", "running", true)])

    resource_inventory =
      resource_inventory([resource("live_workspace_lease", "resource-1", "task-1", "principal")])

    scoped_tasks = put_in(task_inventory, ["filters", "task_id"], "task-1")
    scoped_resources = put_in(resource_inventory, ["filters", "task_id"], "task-1")

    assert {:ok, manifest, _digest} =
             ReconciliationCore.reconcile(scoped_tasks, scoped_resources, @observed_at)

    assert manifest["scope"]["task_id"] == "task-1"

    assert {:error, :inconsistent_scope} =
             ReconciliationCore.reconcile(
               scoped_tasks,
               put_in(resource_inventory, ["filters", "task_id"], "task-2"),
               @observed_at
             )

    assert {:error, :unsupported_task_scope} =
             ReconciliationCore.reconcile(
               put_in(task_inventory, ["filters", "agent_id"], "agent-1"),
               resource_inventory,
               @observed_at
             )

    assert {:error, :unsupported_task_scope} =
             ReconciliationCore.reconcile(
               put_in(task_inventory, ["filters", "state"], "running"),
               resource_inventory,
               @observed_at
             )
  end

  test "rejects malformed, truncated, oversized, and duplicate observations" do
    valid_tasks = task_inventory([task("task-1", "running", true)])

    valid_resources =
      resource_inventory([resource("live_workspace_lease", "resource-1", "task-1", "principal")])

    assert {:error, :truncated_observation} =
             ReconciliationCore.reconcile(
               valid_tasks |> Map.put("truncated", true),
               valid_resources,
               @observed_at
             )

    assert {:error, :truncated_observation} =
             ReconciliationCore.reconcile(
               valid_tasks |> put_in(["counts", "truncated"], 1),
               valid_resources,
               @observed_at
             )

    assert {:error, _} =
             ReconciliationCore.reconcile(
               Map.put(valid_tasks, "unknown", true),
               valid_resources,
               @observed_at
             )

    too_many = Enum.map(1..1_001, &task("task-#{&1}", "running", true))
    oversized_tasks = task_inventory(too_many) |> put_in(["counts", "returned"], 1_001)

    assert {:error, _} =
             ReconciliationCore.reconcile(oversized_tasks, valid_resources, @observed_at)

    duplicate_tasks = task_inventory([task("same", "running", true), task("same", "done", false)])

    assert {:error, {:duplicate, "task_id"}} =
             ReconciliationCore.reconcile(duplicate_tasks, valid_resources, @observed_at)

    duplicate_resources =
      resource_inventory([
        resource("live_workspace_lease", "same", "task-1", "principal"),
        resource("live_workspace_lease", "same", "task-1", "principal")
      ])

    assert {:error, :duplicate_resource_identity} =
             ReconciliationCore.reconcile(valid_tasks, duplicate_resources, @observed_at)
  end

  test "is stable across source ordering and omits paths, PIDs, and secrets" do
    secret = "/private/worktree/path-and-secret"
    tasks = [task("task-a", "running", true, outcome: %{"secret" => secret})]

    resources = [
      resource("live_workspace_lease", "resource-a", "task-a", "principal",
        repo_path: secret,
        worktree_path: secret
      )
    ]

    first =
      ReconciliationCore.reconcile(
        task_inventory(tasks),
        resource_inventory(resources),
        @observed_at
      )

    second =
      ReconciliationCore.reconcile(
        task_inventory(Enum.reverse(tasks)),
        resource_inventory(Enum.reverse(resources)),
        @observed_at
      )

    assert first == second
    {:ok, manifest, _digest} = first
    encoded = Jason.encode!(manifest)
    refute String.contains?(encoded, secret)
    refute String.contains?(encoded, "pid")
    refute String.contains?(encoded, "secret")
    assert String.match?(manifest["observation_digest"]["source_sha256"], ~r/\A[0-9a-f]{64}\z/)
  end

  defp task(task_id, state, owner_alive, overrides \\ []) do
    %{
      "task_id" => task_id,
      "agent_id" => "agent-1",
      "state" => state,
      "current_step" => "coding",
      "waiting_on" => nil,
      "started_at" => "2026-07-22T16:00:00Z",
      "updated_at" => @observed_at,
      "completed_at" => if(state == "done", do: @observed_at, else: nil),
      "owner_process" => %{"present" => owner_alive, "alive" => owner_alive},
      "control_counts" => %{"closed" => 0, "open" => 0},
      "evidence_present" => false,
      "artifacts_present" => false
    }
    |> Map.merge(Map.new(overrides, fn {key, value} -> {to_string(key), value} end))
  end

  defp task_inventory(tasks) do
    %{
      "schema_version" => 1,
      "storage" => %{"durability" => "volatile"},
      "filters" => %{"task_id" => nil, "agent_id" => nil, "state" => nil},
      "max_items" => 1_000,
      "truncated" => false,
      "counts" => %{
        "observed" => length(tasks),
        "matching" => length(tasks),
        "returned" => length(tasks),
        "filtered_out" => 0,
        "truncated" => 0,
        "malformed" => 0
      },
      "tasks" => tasks
    }
  end

  defp resource(type, resource_id, task_id, principal_id, overrides \\ []) do
    %{
      "resource_type" => type,
      "resource_id" => resource_id,
      "workspace_id" => "workspace-#{resource_id}",
      "task_id" => task_id,
      "principal_id" => principal_id,
      "repo_path" => "/repo",
      "worktree_path" => "/worktree",
      "branch" => "branch-#{resource_id}",
      "base_commit" => "commit",
      "ownership" => "owned",
      "branch_provenance" => "created",
      "lifecycle" => if(type == "retained_workspace_record", do: "retained", else: "active"),
      "active" => type != "retained_workspace_record" and type != "quarantine",
      "cleanup_armed" => type == "live_workspace_lease",
      "dormant" => false,
      "retry_state" => %{"count" => 0, "limit" => 3, "dormant" => false},
      "expires_at" =>
        if(type == "retained_workspace_record", do: "2026-07-22T18:00:00Z", else: nil)
    }
    |> Map.merge(Map.new(overrides, fn {key, value} -> {to_string(key), value} end))
  end

  defp resource_inventory(resources) do
    by_type =
      Map.new(
        [
          "live_workspace_lease",
          "retained_workspace_record",
          "validation_resource",
          "quarantine"
        ],
        &{&1, Enum.count(resources, fn resource -> resource["resource_type"] == &1 end)}
      )

    %{
      "schema_version" => 1,
      "journal" => %{"status" => "complete", "quarantined" => false},
      "filters" => %{"task_id" => nil, "principal_id" => nil},
      "max_items" => 1_000,
      "truncated" => false,
      "counts" => %{
        "available" => length(resources),
        "matching" => length(resources),
        "returned" => length(resources),
        "filtered_out" => 0,
        "truncated" => 0,
        "by_type" => by_type
      },
      "resources" => resources
    }
  end
end
