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
               resources
               |> put_in(["counts", "by_type", "live_workspace_lease"], 0)
               |> put_in(["counts", "by_type", "quarantine"], 1),
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

  test "rejects incomplete non-truncated inventories and overlapping malformed counts" do
    tasks = task_inventory([task("task-1", "running", true)])

    resources =
      resource_inventory([resource("live_workspace_lease", "resource-1", "task-1", "principal")])

    incomplete_tasks =
      task_inventory([])
      |> put_in(["counts", "observed"], 1)
      |> put_in(["counts", "matching"], 1)
      |> put_in(["counts", "returned"], 0)

    assert {:error, :inconsistent_task_counts} =
             ReconciliationCore.reconcile(incomplete_tasks, resources, @observed_at)

    overlapping_malformed_tasks =
      put_in(tasks, ["counts", "malformed"], 1)

    assert {:error, :inconsistent_task_counts} =
             ReconciliationCore.reconcile(overlapping_malformed_tasks, resources, @observed_at)

    incomplete_resources =
      resource_inventory([])
      |> put_in(["counts", "available"], 1)
      |> put_in(["counts", "matching"], 1)
      |> put_in(["counts", "returned"], 0)
      |> put_in(["counts", "by_type", "live_workspace_lease"], 1)

    assert {:error, :inconsistent_resource_counts} =
             ReconciliationCore.reconcile(tasks, incomplete_resources, @observed_at)
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
               scoped_resources,
               @observed_at,
               %{},
               ReconciliationCore.empty_acp_inventory()
             )

    assert {:ok, _manifest, _digest} =
             ReconciliationCore.reconcile(task_inventory, scoped_resources, @observed_at)

    assert {:error, :inconsistent_scope} =
             ReconciliationCore.reconcile(scoped_tasks, resource_inventory, @observed_at)

    principal_scoped_resources =
      put_in(resource_inventory, ["filters", "principal_id"], "principal")

    assert {:error, :inconsistent_scope} =
             ReconciliationCore.reconcile(scoped_tasks, principal_scoped_resources, @observed_at)

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

  test "accepts producer-sized collections beyond the old 256-item JSON cap" do
    tasks = Enum.map(1..257, &task("task-#{&1}", "running", true))
    resources = [resource("live_workspace_lease", "resource-1", "task-1", "principal")]

    assert {:ok, _manifest, _digest} =
             ReconciliationCore.reconcile(
               task_inventory(tasks),
               resource_inventory(resources),
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
               valid_tasks
               |> put_in(["counts", "observed"], 2)
               |> put_in(["counts", "matching"], 2)
               |> put_in(["counts", "truncated"], 1),
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

  test "classifies ACP managed sessions fail-closed with exact identity binding" do
    tasks = [
      task("task-live", "running", true),
      task("task-dead", "running", false),
      task("task-terminal", "done", false)
    ]

    sessions = [
      acp_session("acp-keep", "task-live", "principal-1", owner_present: true, owner_alive: true),
      acp_session("acp-retry", "task-dead", "principal-1"),
      acp_session("acp-owner-dead", "task-live", "principal-1",
        owner_present: true,
        owner_alive: false
      ),
      acp_session("acp-session-dead", "task-live", "principal-1", session_alive: false),
      acp_session("acp-closing", "task-live", "principal-1",
        status: "closing",
        close_cleanup_in_progress: true
      ),
      acp_session("acp-settle", "task-terminal", "principal-1",
        owner_present: false,
        owner_alive: false
      ),
      acp_session("acp-missing-task", "task-missing", "principal-1"),
      acp_session("acp-missing-principal", "task-live", nil),
      acp_session("acp-missing-task-id", nil, "principal-1")
    ]

    assert {:ok, manifest, digest} =
             ReconciliationCore.reconcile(
               task_inventory(tasks),
               resource_inventory([]),
               @observed_at,
               %{},
               acp_session_inventory(sessions)
             )

    decisions = Map.new(manifest["decisions"], &{&1["resource_id"], &1})

    assert decisions["acp-keep"]["decision"] == "keep"
    assert decisions["acp-keep"]["reason"] == "live_task_owner_alive"
    assert decisions["acp-retry"]["decision"] == "retry"
    assert decisions["acp-retry"]["reason"] == "live_task_owner_dead"
    assert decisions["acp-owner-dead"]["decision"] == "retry"
    assert decisions["acp-owner-dead"]["reason"] == "live_task_owner_dead"
    assert decisions["acp-session-dead"]["decision"] == "retry"
    assert decisions["acp-session-dead"]["reason"] == "live_task_owner_dead"
    assert decisions["acp-closing"]["decision"] == "retry"
    assert decisions["acp-closing"]["reason"] == "live_task_owner_dead"
    assert decisions["acp-settle"]["decision"] == "settle"
    assert decisions["acp-settle"]["reason"] == "terminal_active_resource"
    assert decisions["acp-missing-task"]["reason"] == "missing_task"

    assert decisions["acp-missing-principal"]["reason"] ==
             "missing_task_or_principal_provenance"

    assert decisions["acp-missing-task-id"]["reason"] == "missing_task_or_principal_provenance"
    assert manifest["counts"]["remove"] == 0
    refute Enum.any?(manifest["decisions"], &(&1["decision"] == "remove"))

    identity = decisions["acp-keep"]["expected_identity"]

    assert identity == %{
             "resource_type" => "acp_managed_session",
             "resource_id" => "acp-keep",
             "worker_session_id" => "acp-keep",
             "provider_session_id" => "provider-acp-keep",
             "provider" => "test",
             "model" => "model-1",
             "status" => "ready",
             "pooled" => false,
             "return_to_pool" => false,
             "task_id" => "task-live",
             "principal_id" => "principal-1",
             "owner_present" => true,
             "owner_alive" => true,
             "session_alive" => true,
             "close_cleanup_in_progress" => false
           }

    assert String.match?(digest, ~r/\A[0-9a-f]{64}\z/)
  end

  test "accepts every bounded text value emitted by the ACP inventory producer" do
    session =
      acp_session("worker-1", "task-1", "principal-1",
        provider_session_id: "",
        provider: "",
        model: "\n",
        status: "\t"
      )

    assert {:ok, manifest, _digest} =
             ReconciliationCore.reconcile(
               task_inventory([task("task-1", "running", true)]),
               resource_inventory([]),
               @observed_at,
               %{},
               acp_session_inventory([session])
             )

    identity = hd(manifest["decisions"])["expected_identity"]
    assert identity["provider_session_id"] == ""
    assert identity["provider"] == ""
    assert identity["model"] == "\n"
    assert identity["status"] == "\t"
  end

  test "ACP session decisions are deterministic across input order" do
    tasks = [task("task-live", "running", true), task("task-dead", "running", false)]

    sessions = [
      acp_session("worker-b", "task-dead", "principal-1", owner_alive: false),
      acp_session("worker-a", "task-live", "principal-1", owner_alive: true)
    ]

    first =
      ReconciliationCore.reconcile(
        task_inventory(tasks),
        resource_inventory([]),
        @observed_at,
        %{},
        acp_session_inventory(sessions)
      )

    second =
      ReconciliationCore.reconcile(
        task_inventory(tasks),
        resource_inventory([]),
        @observed_at,
        %{},
        acp_session_inventory(Enum.reverse(sessions))
      )

    assert first == second
    {:ok, manifest, _digest} = first

    assert Enum.map(manifest["decisions"], & &1["resource_id"]) == [
             "worker-a",
             "worker-b"
           ]
  end

  test "ACP identity field drift changes source and manifest digests" do
    tasks = [task("task-live", "running", true)]
    resources = resource_inventory([])
    base_session = acp_session("worker-1", "task-live", "principal-1")
    drifted_session = Map.put(base_session, "owner_alive", false)

    assert {:ok, base_manifest, base_digest} =
             ReconciliationCore.reconcile(
               task_inventory(tasks),
               resources,
               @observed_at,
               %{},
               acp_session_inventory([base_session])
             )

    assert {:ok, drifted_manifest, drifted_digest} =
             ReconciliationCore.reconcile(
               task_inventory(tasks),
               resources,
               @observed_at,
               %{},
               acp_session_inventory([drifted_session])
             )

    assert base_manifest["observation_digest"]["task_inventory_sha256"] ==
             drifted_manifest["observation_digest"]["task_inventory_sha256"]

    assert base_manifest["observation_digest"]["resource_inventory_sha256"] ==
             drifted_manifest["observation_digest"]["resource_inventory_sha256"]

    assert base_manifest["observation_digest"]["source_sha256"] !=
             drifted_manifest["observation_digest"]["source_sha256"]

    assert base_digest != drifted_digest

    assert hd(base_manifest["decisions"])["expected_identity"]["owner_alive"] == true
    assert hd(drifted_manifest["decisions"])["expected_identity"]["owner_alive"] == false
    assert hd(base_manifest["decisions"])["decision"] == "keep"
    assert hd(drifted_manifest["decisions"])["decision"] == "retry"
  end

  test "rejects truncated, malformed, duplicate, and quarantined ACP inventories" do
    tasks = task_inventory([task("task-1", "running", true)])
    resources = resource_inventory([])
    valid = acp_session_inventory([acp_session("worker-1", "task-1", "principal-1")])

    assert {:error, :truncated_observation} =
             ReconciliationCore.reconcile(
               tasks,
               resources,
               @observed_at,
               %{},
               Map.put(valid, "truncated", true)
             )

    assert {:error, :inconsistent_acp_counts} =
             ReconciliationCore.reconcile(
               tasks,
               resources,
               @observed_at,
               %{},
               valid
               |> put_in(["counts", "observed"], 2)
               |> put_in(["counts", "matching"], 2)
               |> put_in(["counts", "truncated"], 1)
             )

    assert {:error, :inconsistent_acp_counts} =
             ReconciliationCore.reconcile(
               tasks,
               resources,
               @observed_at,
               %{},
               valid
               |> put_in(["counts", "observed"], 2)
               |> put_in(["counts", "malformed"], 1)
               |> put_in(["counts", "matching"], 1)
             )

    assert {:error, :malformed_acp_quarantine} =
             ReconciliationCore.reconcile(
               tasks,
               resources,
               @observed_at,
               %{},
               valid
               |> put_in(["counts", "observed"], 2)
               |> put_in(["counts", "duplicates"], 1)
               |> put_in(["counts", "quarantined"], 1)
               |> put_in(["counts", "matching"], 1)
             )

    assert {:error, :malformed_acp_sessions} =
             ReconciliationCore.reconcile(
               tasks,
               resources,
               @observed_at,
               %{},
               valid
               |> put_in(["counts", "returned"], 0)
               |> put_in(["counts", "matching"], 0)
               |> put_in(["counts", "observed"], 0)
             )

    assert {:error, {:duplicate, "worker_session_id"}} =
             ReconciliationCore.reconcile(
               tasks,
               resources,
               @observed_at,
               %{},
               acp_session_inventory([
                 acp_session("same", "task-1", "principal-1"),
                 acp_session("same", "task-1", "principal-1")
               ])
             )

    assert {:error, {:duplicate, "provider_session_id"}} =
             ReconciliationCore.reconcile(
               tasks,
               resources,
               @observed_at,
               %{},
               acp_session_inventory([
                 acp_session("worker-1", "task-1", "principal-1",
                   provider_session_id: "provider-shared"
                 ),
                 acp_session("worker-2", "task-1", "principal-1",
                   provider_session_id: "provider-shared"
                 )
               ])
             )

    assert {:error, :closed_object} =
             ReconciliationCore.reconcile(
               tasks,
               resources,
               @observed_at,
               %{},
               Map.put(valid, "opaque", true)
             )

    assert {:error, :field_set} =
             ReconciliationCore.reconcile(
               tasks,
               resources,
               @observed_at,
               %{},
               acp_session_inventory([
                 acp_session("worker-1", "task-1", "principal-1")
                 |> Map.delete("owner_alive")
               ])
             )

    assert {:error, :inconsistent_acp_filters} =
             ReconciliationCore.reconcile(
               tasks,
               resources,
               @observed_at,
               %{},
               put_in(valid, ["filters", "task_id"], "other-task")
             )

    assert {:error, :invalid_acp_id} =
             ReconciliationCore.reconcile(
               tasks,
               resources,
               @observed_at,
               %{},
               acp_session_inventory([
                 acp_session(" worker-1", "task-1", "principal-1")
               ])
             )

    assert {:error, :inconsistent_acp_liveness} =
             ReconciliationCore.reconcile(
               tasks,
               resources,
               @observed_at,
               %{},
               acp_session_inventory([
                 acp_session("worker-1", "task-1", "principal-1",
                   owner_present: false,
                   owner_alive: true
                 )
               ])
             )

    assert {:error, :inconsistent_acp_close_state} =
             ReconciliationCore.reconcile(
               tasks,
               resources,
               @observed_at,
               %{},
               acp_session_inventory([
                 acp_session("worker-1", "task-1", "principal-1", close_cleanup_in_progress: true)
               ])
             )
  end

  test "empty ACP inventory participates in source digest without decisions" do
    tasks = task_inventory([task("task-1", "running", true)])

    resources =
      resource_inventory([resource("live_workspace_lease", "resource-1", "task-1", "principal")])

    assert {:ok, with_default, default_digest} =
             ReconciliationCore.reconcile(tasks, resources, @observed_at)

    assert {:ok, with_empty, empty_digest} =
             ReconciliationCore.reconcile(
               tasks,
               resources,
               @observed_at,
               %{},
               ReconciliationCore.empty_acp_inventory()
             )

    assert with_default == with_empty
    assert default_digest == empty_digest
    assert length(with_empty["decisions"]) == 1
    assert hd(with_empty["decisions"])["resource_type"] == "live_workspace_lease"
    assert String.match?(with_empty["observation_digest"]["source_sha256"], ~r/\A[0-9a-f]{64}\z/)
  end

  defp acp_session(worker_session_id, task_id, principal_id, overrides \\ []) do
    %{
      "worker_session_id" => worker_session_id,
      "provider_session_id" => "provider-#{worker_session_id}",
      "provider" => "test",
      "model" => "model-1",
      "status" => "ready",
      "pooled" => false,
      "return_to_pool" => false,
      "task_id" => task_id,
      "principal_id" => principal_id,
      "owner_present" => true,
      "owner_alive" => true,
      "session_alive" => true,
      "close_cleanup_in_progress" => false
    }
    |> Map.merge(Map.new(overrides, fn {key, value} -> {to_string(key), value} end))
  end

  defp acp_session_inventory(sessions) do
    %{
      "schema_version" => 1,
      "storage" => %{"durability" => "volatile"},
      "filters" => %{"task_id" => nil, "principal_id" => nil},
      "max_items" => 1_000,
      "truncated" => false,
      "counts" => %{
        "observed" => length(sessions),
        "matching" => length(sessions),
        "returned" => length(sessions),
        "filtered_out" => 0,
        "truncated" => 0,
        "malformed" => 0,
        "duplicates" => 0,
        "quarantined" => 0,
        "quarantine_returned" => 0,
        "quarantine_truncated" => 0
      },
      "sessions" => sessions,
      "quarantine" => []
    }
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
