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
      :coding_reconciliation_approval_facade
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

    refute_received {:mutation, _}
  end

  test "task-scoped capability is attempted before the broad capability", %{root: _root} do
    Process.put(
      {Observer, :observations},
      observations()
      |> put_in(["task_inventory", "filters", "task_id"], "task-1")
      |> put_in(["resource_inventory", "filters", "task_id"], "task-1")
    )

    Process.put({Clock, :values}, [@observed_at, @persisted_at])

    assert {:ok, _result} =
             Reconciliation.dry_run(
               caller_id: "operator-1",
               task_id: "task-1"
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

    Process.put({TaskFacade, :inventory}, scoped_observations["task_inventory"])
    Process.put({ResourceFacade, :inventory}, scoped_observations["resource_inventory"])
    Process.put({AcpFacade, :inventory}, scoped_observations["acp_sessions"])
    Process.put({ApprovalFacade, :inventory}, scoped_observations["pending_approvals"])
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
                      max_items: 64
                    ]}
  end

  test "unavailable, truncated, duplicate, or quarantined supplementary evidence fails closed" do
    for transform <- [
          &Map.delete(&1, "acp_sessions"),
          &put_in(&1, ["acp_sessions", "truncated"], true),
          &put_in(&1, ["acp_sessions", "counts", "duplicates"], 1),
          &put_in(&1, ["pending_approvals", "counts", "quarantined"], 1),
          &put_in(&1, ["resource_inventory", "journal", "quarantined"], true)
        ] do
      Process.put({Observer, :observations}, transform.(observations()))
      Process.put({Clock, :values}, [@observed_at, @persisted_at])

      assert {:error, _reason} =
               Reconciliation.dry_run(caller_id: "operator-1")
    end
  end

  test "scope mismatch is rejected by the pure core before persistence" do
    Process.put(
      {Observer, :observations},
      observations()
      |> put_in(["task_inventory", "filters", "task_id"], "task-1")
      |> put_in(["resource_inventory", "filters", "task_id"], "task-2")
    )

    Process.put({Clock, :values}, [@observed_at, @persisted_at])

    assert {:error, :inconsistent_scope} =
             Reconciliation.dry_run(caller_id: "operator-1")
  end

  defp observations do
    %{
      "task_inventory" => task_inventory(),
      "resource_inventory" => resource_inventory(),
      "acp_sessions" => supplementary_inventory(),
      "pending_approvals" => supplementary_inventory()
    }
  end

  defp task_inventory do
    task = %{
      "task_id" => "task-1",
      "agent_id" => "agent-1",
      "state" => "running",
      "current_step" => "coding",
      "waiting_on" => nil,
      "started_at" => "2026-07-22T16:00:00Z",
      "updated_at" => @observed_at,
      "completed_at" => nil,
      "owner_process" => %{"present" => true, "alive" => true},
      "control_counts" => %{"closed" => 0, "open" => 0},
      "evidence_present" => false,
      "artifacts_present" => false
    }

    %{
      "schema_version" => 1,
      "storage" => %{"durability" => "volatile"},
      "filters" => %{"task_id" => nil, "agent_id" => nil, "state" => nil},
      "max_items" => 64,
      "truncated" => false,
      "counts" => %{
        "observed" => 1,
        "matching" => 1,
        "returned" => 1,
        "filtered_out" => 0,
        "truncated" => 0,
        "malformed" => 0
      },
      "tasks" => [task]
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

  defp supplementary_inventory do
    %{
      "schema_version" => 1,
      "storage" => %{"durability" => "volatile"},
      "filters" => %{"task_id" => nil, "principal_id" => nil},
      "truncated" => false,
      "counts" => %{
        "observed" => 0,
        "matching" => 0,
        "returned" => 0,
        "quarantined" => 0,
        "duplicates" => 0,
        "malformed" => 0,
        "backend_omitted" => 0,
        "quarantine_truncated" => 0
      },
      "sessions" => [],
      "approvals" => []
    }
  end
end
