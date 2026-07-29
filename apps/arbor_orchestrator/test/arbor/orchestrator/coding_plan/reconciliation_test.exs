defmodule Arbor.Orchestrator.CodingPlan.ReconciliationTest do
  use ExUnit.Case, async: false

  alias Arbor.Orchestrator.CodingPlan.Reconciliation

  @moduletag :fast
  @observed_at "2026-07-22T17:00:00Z"
  @persisted_at "2026-07-22T17:00:01Z"

  defmodule Security do
    def authorize(caller, uri, action, opts) do
      send(self(), {:authorized, caller, uri, action, opts})
      Process.get({__MODULE__, :result}, {:ok, :authorized})
    end
  end

  defmodule Observer do
    def observe(opts) do
      send(self(), {:observed, opts})
      {:ok, Process.get({__MODULE__, :observations}, %{})}
    end
  end

  defmodule Clock do
    def now do
      case Process.get({__MODULE__, :values}, []) do
        [value | rest] ->
          Process.put({__MODULE__, :values}, rest)
          value

        _ ->
          DateTime.utc_now()
      end
    end
  end

  defmodule TaskFacade do
    def task_inventory(opts) do
      send(self(), {:task_facade_opts, opts})
      {:ok, Process.get({__MODULE__, :inventory})}
    end
  end

  defmodule ResourceFacade do
    def coding_resource_inventory(opts) do
      send(self(), {:resource_facade_opts, opts})
      {:ok, Process.get({__MODULE__, :inventory})}
    end
  end

  defmodule AcpFacade do
    def acp_managed_session_inventory(opts) do
      send(self(), {:acp_facade_opts, opts})
      {:ok, Process.get({__MODULE__, :inventory})}
    end
  end

  defmodule ApprovalFacade do
    def pending_approval_inventory(opts) do
      send(self(), {:approval_facade_opts, opts})
      {:ok, Process.get({__MODULE__, :inventory})}
    end
  end

  defmodule ShellFacade do
    def apple_container_unit_inventory(opts) do
      send(self(), {:shell_facade_opts, opts})
      {:ok, Process.get({__MODULE__, :inventory})}
    end
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "coding_reconciliation_#{System.unique_integer([:positive])}")

    keys = [
      :security_module,
      :coding_pipeline_logs_root,
      :coding_reconciliation_artifact_store,
      :coding_reconciliation_observer_module,
      :coding_reconciliation_clock,
      :coding_reconciliation_task_facade,
      :coding_reconciliation_resource_facade,
      :coding_reconciliation_acp_facade,
      :coding_reconciliation_approval_facade,
      :coding_reconciliation_shell_facade
    ]

    previous = Map.new(keys, &{&1, Application.get_env(:arbor_orchestrator, &1)})

    Application.put_env(:arbor_orchestrator, :security_module, Security)
    Application.put_env(:arbor_orchestrator, :coding_pipeline_logs_root, root)

    Application.put_env(
      :arbor_orchestrator,
      :coding_reconciliation_artifact_store,
      Arbor.Orchestrator.CodingPlan.ArtifactStore
    )

    Application.put_env(:arbor_orchestrator, :coding_reconciliation_observer_module, Observer)
    Application.put_env(:arbor_orchestrator, :coding_reconciliation_clock, Clock)
    Process.put({Clock, :values}, [@observed_at, @persisted_at])

    on_exit(fn ->
      File.rm_rf(root)

      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:arbor_orchestrator, key)
        {key, value} -> Application.put_env(:arbor_orchestrator, key, value)
      end)

      Process.delete({Security, :result})
    end)

    %{root: root}
  end

  test "authorized dry-run is deterministic, persists redacted evidence, and has no mutation path" do
    Process.put({Observer, :observations}, observations())
    opts = [caller_id: "operator-1"]

    assert {:ok, first} = Reconciliation.dry_run(opts)
    Process.put({Observer, :observations}, observations())
    Process.put({Clock, :values}, [@observed_at, @persisted_at])
    assert {:ok, second} = Reconciliation.dry_run(opts)
    assert first == second
    assert first["mode"] == "dry_run"
    assert first["manifest_sha256"] == first["artifact"]["manifest_sha256"]
    assert first["manifest"]["counts"]["remove"] == 0
    assert first["supplementary_evidence"]["acp_sessions"]["counts"]["observed"] == 0
    refute Jason.encode!(first) =~ "/private/worktree"
    refute Jason.encode!(first) =~ "secret"
    refute Map.has_key?(first, "apply")

    assert_receive {:authorized, "operator-1", "arbor://coding/reconciliation/read", :read,
                    verify_identity: false}

    assert_receive {:observed,
                    [
                      caller_id: "operator-1",
                      task_id: nil,
                      principal_id: nil,
                      max_items: 64,
                      pending_approval_principal_scope: :subject
                    ]}

    refute_received {:mutation, _}
  end

  test "task-scoped capability is attempted before the broad capability", %{root: _root} do
    Process.put(
      {Observer, :observations},
      observations()
      |> put_in(["task_inventory", "filters", "task_id"], "task-1")
      |> put_in(["resource_inventory", "filters", "task_id"], "task-1")
      |> put_in(["resource_inventory", "filters", "principal_id"], "principal-1")
      |> put_in(["acp_sessions", "filters", "task_id"], "task-1")
      |> put_in(["acp_sessions", "filters", "principal_id"], "principal-1")
      |> put_in(["pending_approvals", "filters", "task_id"], "task-1")
      |> put_in(["pending_approvals", "filters", "principal_id"], "principal-1")
      |> put_in(["apple_container_units", "filter"], "scoped")
    )

    Process.put({Clock, :values}, [@observed_at, @persisted_at])

    assert {:ok, _result} =
             Reconciliation.dry_run(
               caller_id: "operator-1",
               task_id: "task-1",
               principal_id: "principal-1"
             )

    assert_receive {:authorized, "operator-1", "arbor://coding/reconciliation/read/task-1", :read,
                    verify_identity: false}
  end

  test "authorization denial prevents collection and persistence" do
    Process.put({Security, :result}, {:error, :missing_capability})

    assert {:error, {:unauthorized, :coding_reconciliation_read_required}} =
             Reconciliation.dry_run(caller_id: "operator-1")

    refute File.exists?(
             Path.join(Arbor.Orchestrator.coding_pipeline_logs_root(), "coding-reconciliation")
           )
  end

  test "public dry-run rejects forged observations and injected timestamps" do
    assert {:error, :invalid_reconciliation_options} =
             Reconciliation.dry_run(caller_id: "operator-1", observations: %{})

    assert {:error, :invalid_reconciliation_options} =
             Reconciliation.dry_run(caller_id: "operator-1", persisted_at: @persisted_at)

    assert {:error, :invalid_reconciliation_options} =
             Reconciliation.dry_run(caller_id: "operator-1", observed_at: @observed_at)
  end

  test "public dry-run rejects one-sided task and principal scopes" do
    assert {:error, :invalid_reconciliation_scope} =
             Reconciliation.dry_run(caller_id: "operator-1", task_id: "task-1")

    assert {:error, :invalid_reconciliation_scope} =
             Reconciliation.dry_run(caller_id: "operator-1", principal_id: "principal-1")
  end

  test "public orchestrator facade cannot select observation or clock seams" do
    assert {:error, :invalid_reconciliation_options} =
             Arbor.Orchestrator.reconcile_coding_resources(
               caller_id: "operator-1",
               observations: %{}
             )

    assert {:error, :invalid_reconciliation_options} =
             Arbor.Orchestrator.reconcile_coding_resources(
               caller_id: "operator-1",
               persisted_at: "1970-01-01T00:00:00Z",
               observer_module: __MODULE__,
               clock: __MODULE__
             )
  end

  test "configured public facades receive only their accepted scoped options" do
    scoped_observations =
      observations()
      |> put_in(["task_inventory", "filters", "task_id"], "task-1")
      |> put_in(["resource_inventory", "filters", "task_id"], "task-1")
      |> put_in(["resource_inventory", "filters", "principal_id"], "principal-1")
      |> put_in(["acp_sessions", "filters", "task_id"], "task-1")
      |> put_in(["acp_sessions", "filters", "principal_id"], "principal-1")
      |> put_in(["pending_approvals", "filters", "task_id"], "task-1")
      |> put_in(["pending_approvals", "filters", "principal_id"], "principal-1")
      |> put_in(["apple_container_units", "filter"], "scoped")

    Application.put_env(:arbor_orchestrator, :coding_reconciliation_observer_module, nil)

    Application.put_env(
      :arbor_orchestrator,
      :coding_reconciliation_task_facade,
      TaskFacade
    )

    Application.put_env(
      :arbor_orchestrator,
      :coding_reconciliation_resource_facade,
      ResourceFacade
    )

    Application.put_env(:arbor_orchestrator, :coding_reconciliation_acp_facade, AcpFacade)

    Application.put_env(
      :arbor_orchestrator,
      :coding_reconciliation_approval_facade,
      ApprovalFacade
    )

    Application.put_env(:arbor_orchestrator, :coding_reconciliation_shell_facade, ShellFacade)

    Process.put({TaskFacade, :inventory}, scoped_observations["task_inventory"])
    Process.put({ResourceFacade, :inventory}, scoped_observations["resource_inventory"])
    Process.put({AcpFacade, :inventory}, scoped_observations["acp_sessions"])
    Process.put({ApprovalFacade, :inventory}, scoped_observations["pending_approvals"])
    Process.put({ShellFacade, :inventory}, scoped_observations["apple_container_units"])
    Process.put({Clock, :values}, [@observed_at, @persisted_at])

    assert {:ok, _result} =
             Reconciliation.dry_run(
               caller_id: "operator-1",
               task_id: "task-1",
               principal_id: "principal-1"
             )

    assert_receive {:task_facade_opts,
                    [caller_id: "operator-1", task_id: "task-1", max_items: 64]}

    assert_receive {:resource_facade_opts,
                    [task_id: "task-1", principal_id: "principal-1", max_items: 64]}

    assert_receive {:acp_facade_opts,
                    [
                      caller_id: "operator-1",
                      task_id: "task-1",
                      principal_id: "principal-1",
                      max_items: 64
                    ]}

    assert_receive {:approval_facade_opts,
                    [
                      caller_id: "operator-1",
                      task_id: "task-1",
                      principal_id: "principal-1",
                      max_items: 64,
                      principal_scope: :subject
                    ]}

    assert_receive {:shell_facade_opts,
                    [task_id: "task-1", principal_id: "principal-1", max_items: 64]}
  end

  test "public facade collection fails closed on disabled Apple Container inventory" do
    Application.put_env(:arbor_orchestrator, :coding_reconciliation_observer_module, nil)
    Application.put_env(:arbor_orchestrator, :coding_reconciliation_task_facade, TaskFacade)

    Application.put_env(
      :arbor_orchestrator,
      :coding_reconciliation_resource_facade,
      ResourceFacade
    )

    Application.put_env(:arbor_orchestrator, :coding_reconciliation_acp_facade, AcpFacade)

    Application.put_env(
      :arbor_orchestrator,
      :coding_reconciliation_approval_facade,
      ApprovalFacade
    )

    Application.put_env(:arbor_orchestrator, :coding_reconciliation_shell_facade, ShellFacade)

    observations = observations()
    Process.put({TaskFacade, :inventory}, observations["task_inventory"])
    Process.put({ResourceFacade, :inventory}, observations["resource_inventory"])
    Process.put({AcpFacade, :inventory}, observations["acp_sessions"])
    Process.put({ApprovalFacade, :inventory}, observations["pending_approvals"])

    Process.put(
      {ShellFacade, :inventory},
      observations["apple_container_units"]
      |> Map.put("status", "disabled")
    )

    Process.put({Clock, :values}, [@observed_at, @persisted_at])

    assert {:error, :invalid_or_incomplete_apple_container_unit_inventory} =
             Reconciliation.dry_run(caller_id: "operator-1")
  end

  test "unavailable, truncated, duplicate, or quarantined supplementary evidence fails closed" do
    root = Arbor.Orchestrator.coding_pipeline_logs_root()

    for transform <- [
          &Map.delete(&1, "acp_sessions"),
          &put_in(&1, ["acp_sessions", "truncated"], true),
          &put_in(&1, ["acp_sessions", "counts", "duplicates"], 1),
          &put_in(&1, ["pending_approvals", "counts", "quarantined"], 1),
          &put_in(&1, ["resource_inventory", "journal", "quarantined"], true)
        ] do
      before = artifact_paths(root)
      Process.put({Observer, :observations}, transform.(observations()))
      Process.put({Clock, :values}, [@observed_at, @persisted_at])

      assert {:error, _reason} =
               Reconciliation.dry_run(caller_id: "operator-1")

      assert artifact_paths(root) == before
    end
  end

  test "incomplete ACP inventory fails before manifest persistence" do
    root = Arbor.Orchestrator.coding_pipeline_logs_root()
    before = artifact_paths(root)

    incomplete =
      observations()
      |> put_in(["acp_sessions", "counts", "returned"], 1)
      |> put_in(["acp_sessions", "sessions"], [])

    Process.put({Observer, :observations}, incomplete)
    Process.put({Clock, :values}, [@observed_at, @persisted_at])

    assert {:error, :invalid_or_incomplete_supplementary_inventory} =
             Reconciliation.dry_run(caller_id: "operator-1")

    assert artifact_paths(root) == before
  end

  test "valid ACP sessions produce digest-bound decisions through dry-run" do
    Process.put(
      {Observer, :observations},
      observations()
      |> Map.put(
        "task_inventory",
        task_inventory([
          task("task-1", "running", true),
          task("task-dead", "running", false)
        ])
      )
      |> Map.put(
        "acp_sessions",
        acp_session_inventory([
          acp_session("worker-b", "task-dead", "principal-1",
            owner_present: true,
            owner_alive: false
          ),
          acp_session("worker-a", "task-1", "principal-1", owner_alive: true)
        ])
      )
    )

    Process.put({Clock, :values}, [@observed_at, @persisted_at])

    assert {:ok, result} = Reconciliation.dry_run(caller_id: "operator-1")

    decisions = result["manifest"]["decisions"]
    by_id = Map.new(decisions, &{&1["resource_id"], &1})

    assert by_id["resource-1"]["resource_type"] == "live_workspace_lease"
    assert by_id["resource-1"]["decision"] == "keep"
    assert by_id["worker-a"]["resource_type"] == "acp_managed_session"
    assert by_id["worker-a"]["decision"] == "keep"
    assert by_id["worker-a"]["reason"] == "live_task_owner_alive"
    assert by_id["worker-b"]["decision"] == "retry"
    assert by_id["worker-b"]["reason"] == "live_task_owner_dead"

    assert by_id["worker-a"]["expected_identity"]["owner_present"] == true
    assert by_id["worker-a"]["expected_identity"]["owner_alive"] == true
    assert by_id["worker-a"]["expected_identity"]["session_alive"] == true
    assert by_id["worker-a"]["expected_identity"]["close_cleanup_in_progress"] == false
    assert by_id["worker-a"]["expected_identity"]["worker_session_id"] == "worker-a"

    # Workspace decisions sort before ACP (resource_order 0 then 4).
    assert Enum.map(decisions, & &1["resource_id"]) == [
             "resource-1",
             "worker-a",
             "worker-b"
           ]

    assert result["manifest"]["counts"]["resources"] == 3
    assert result["manifest"]["counts"]["keep"] == 2
    assert result["manifest"]["counts"]["retry"] == 1
    assert result["supplementary_evidence"]["acp_sessions"]["counts"]["returned"] == 2
    assert String.match?(result["manifest_sha256"], ~r/\A[0-9a-f]{64}\z/)
    refute Map.has_key?(result, "apply")
  end

  test "scope mismatch is rejected by the pure core before persistence" do
    Process.put(
      {Observer, :observations},
      observations()
      |> put_in(["task_inventory", "filters", "task_id"], "task-1")
      |> put_in(["resource_inventory", "filters", "task_id"], "task-2")
      |> put_in(["acp_sessions", "filters", "task_id"], "task-2")
      |> put_in(["pending_approvals", "filters", "task_id"], "task-2")
    )

    Process.put({Clock, :values}, [@observed_at, @persisted_at])

    assert {:error, :inconsistent_scope} =
             Reconciliation.dry_run(caller_id: "operator-1")
  end

  test "pending approvals produce decisions and reject narrowed observer filters" do
    {:ok, resource_id} =
      Arbor.Contracts.Coding.PendingApprovalResourceId.resource_id("consensus", "irq-keep")

    approval = %{
      "resource_id" => resource_id,
      "approval_id" => "irq-keep",
      "source" => "consensus",
      "task_id" => "task-1",
      "agent_id" => "agent-1",
      "principal_id" => "principal-1",
      "approver_id" => nil,
      "resource_uri" => "arbor://fs/read/repo/file.ex",
      "action" => "read",
      "status" => "pending",
      "created_at" => "2026-07-22T12:00:00Z"
    }

    Process.put(
      {Observer, :observations},
      observations()
      |> Map.put(
        "task_inventory",
        task_inventory([task("task-1", "running", true)])
      )
      |> Map.put(
        "pending_approvals",
        pending_approval_inventory([approval])
      )
    )

    Process.put({Clock, :values}, [@observed_at, @persisted_at])
    assert {:ok, result} = Reconciliation.dry_run(caller_id: "operator-1")

    by_id = Map.new(result["manifest"]["decisions"], &{&1["resource_id"], &1})
    assert by_id[resource_id]["resource_type"] == "pending_approval"
    assert by_id[resource_id]["decision"] == "keep"
    assert by_id[resource_id]["expected_identity"]["approval_id"] == "irq-keep"
    assert result["supplementary_evidence"]["pending_approvals"]["counts"]["returned"] == 1
    refute Map.has_key?(result["supplementary_evidence"]["pending_approvals"], "approvals")

    narrowed =
      observations()
      |> put_in(["pending_approvals", "filters", "agent_id"], "agent-1")

    Process.put({Observer, :observations}, narrowed)
    Process.put({Clock, :values}, [@observed_at, @persisted_at])

    assert {:error, :invalid_or_incomplete_pending_approval_inventory} =
             Reconciliation.dry_run(caller_id: "operator-1")
  end

  defp observations do
    %{
      "task_inventory" => task_inventory(),
      "resource_inventory" => resource_inventory(),
      "acp_sessions" => acp_session_inventory([]),
      "pending_approvals" => pending_approval_inventory(),
      "apple_container_units" => apple_container_unit_inventory()
    }
  end

  defp task(task_id, state, owner_alive) do
    %{
      "task_id" => task_id,
      "agent_id" => "agent-1",
      "state" => state,
      "current_step" => "coding",
      "waiting_on" => nil,
      "started_at" => "2026-07-22T16:00:00Z",
      "updated_at" => @observed_at,
      "completed_at" => nil,
      "owner_process" => %{"present" => owner_alive, "alive" => owner_alive},
      "control_counts" => %{"closed" => 0, "open" => 0},
      "evidence_present" => false,
      "artifacts_present" => false
    }
  end

  defp task_inventory(tasks \\ nil) do
    tasks = tasks || [task("task-1", "running", true)]

    %{
      "schema_version" => 1,
      "storage" => %{"durability" => "volatile"},
      "filters" => %{"task_id" => nil, "agent_id" => nil, "state" => nil},
      "max_items" => 64,
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

  defp resource_inventory do
    resource = %{
      "resource_type" => "live_workspace_lease",
      "resource_id" => "resource-1",
      "workspace_id" => "workspace-1",
      "task_id" => "task-1",
      "principal_id" => "principal-1",
      "repo_path" => "/private/worktree/secret",
      "worktree_path" => "/private/worktree/secret",
      "branch" => "branch-1",
      "base_commit" => "commit",
      "ownership" => "owned",
      "branch_provenance" => "created",
      "lifecycle" => "active",
      "active" => true,
      "cleanup_armed" => true,
      "dormant" => false,
      "retry_state" => %{"count" => 0, "limit" => 3, "dormant" => false},
      "expires_at" => nil
    }

    %{
      "schema_version" => 1,
      "journal" => %{"status" => "complete", "quarantined" => false},
      "filters" => %{"task_id" => nil, "principal_id" => nil},
      "max_items" => 64,
      "truncated" => false,
      "counts" => %{
        "available" => 1,
        "matching" => 1,
        "returned" => 1,
        "filtered_out" => 0,
        "truncated" => 0,
        "by_type" => %{
          "live_workspace_lease" => 1,
          "retained_workspace_record" => 0,
          "validation_resource" => 0,
          "quarantine" => 0
        }
      },
      "resources" => [resource]
    }
  end

  defp acp_session(worker_session_id, task_id, principal_id, overrides) do
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
      "max_items" => 64,
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

  defp pending_approval_inventory(approvals \\ []) do
    %{
      "schema_version" => 1,
      "storage" => %{
        "durability" => "volatile",
        "authority" => "approval_backends",
        "read_only" => true
      },
      "bounds" => %{"max_items" => 64, "max_backend_entries" => 1_000},
      "filters" => %{
        "task_id" => nil,
        "agent_id" => nil,
        "principal_id" => nil,
        "principal_scope" => "subject",
        "resource_uri" => nil
      },
      "truncated" => false,
      "counts" => %{
        "observed" => length(approvals),
        "matching" => length(approvals),
        "returned" => length(approvals),
        "filtered_out" => 0,
        "ignored" => 0,
        "malformed" => 0,
        "duplicates" => 0,
        "quarantined" => 0,
        "truncated" => 0,
        "backend_omitted" => 0
      },
      "backend_counts" => %{
        "consensus" => %{"observed" => length(approvals), "omitted" => 0, "truncated" => false},
        "interaction" => %{"observed" => 0, "omitted" => 0, "truncated" => false}
      },
      "approvals" => approvals
    }
  end

  defp apple_container_unit_inventory do
    %{
      "status" => "complete",
      "filter" => "global",
      "matched_count" => 0,
      "returned_count" => 0,
      "max_items" => 64,
      "truncated" => false,
      "items" => []
    }
  end

  defp artifact_paths(root) do
    root
    |> Path.join("coding-reconciliation/**/*")
    |> Path.wildcard()
    |> Enum.sort()
  end
end
