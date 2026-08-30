defmodule Arbor.Orchestrator.CodingRunRecoverySecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Contracts.Security.Identity
  alias Arbor.Orchestrator.CodingPlan.{ArtifactStore, CodingRunRecoveryCore}
  alias Arbor.Orchestrator.CodingRunRecovery
  alias Arbor.Orchestrator.Config
  alias Arbor.Orchestrator.RunLifecycle.Record
  alias Arbor.Security
  alias Arbor.Security.SigningAuthorityBroker

  test "task-owned binding skips without opening an authority" do
    logs = Path.join(System.tmp_dir!(), "g3b-skip-#{System.unique_integer([:positive])}")
    File.mkdir_p!(logs)
    on_exit(fn -> File.rm_rf(logs) end)

    previous = Application.get_env(:arbor_orchestrator, :coding_pipeline_logs_root)
    Application.put_env(:arbor_orchestrator, :coding_pipeline_logs_root, logs)

    on_exit(fn ->
      if is_binary(previous) do
        Application.put_env(:arbor_orchestrator, :coding_pipeline_logs_root, previous)
      else
        Application.delete_env(:arbor_orchestrator, :coding_pipeline_logs_root)
      end
    end)

    run_id = "task_owned_1"
    digest = :crypto.hash(:sha256, run_id) |> Base.encode16(case: :lower)
    root = Path.join(Path.expand(logs), "task-" <> digest)
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    hash = String.duplicate("a", 64)

    binding = %{
      "schema_version" => 1,
      "task_id" => run_id,
      "run_id" => run_id,
      "agent_id" => "agent_1",
      "execution_principal" => "agent_1",
      "control_principal_id" => "caller_1",
      "executor_kind" => "coding_change",
      "graph_hash" => hash,
      "compiler_version" => "1",
      "artifact_identity" => String.duplicate("c", 64)
    }

    assert :ok = ArtifactStore.archive_run_binding(root, binding)

    record = %Record{
      run_id: run_id,
      pipeline_id: "p",
      graph_hash: hash,
      execution_principal: "agent_1",
      logs_root: root
    }

    before = broker_authority_count()
    assert {:skip, :task_store_owned} = CodingRunRecovery.resolve_coordinator_options(record)
    assert broker_authority_count() == before
    _ = Config.coding_pipeline_logs_root()
  end

  test "coordinator skip contract never opens an authority for task-owned or unavailable coding roots" do
    suffix = :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)

    record = %Record{
      run_id: "task_missing_#{suffix}",
      pipeline_id: "p",
      graph_hash: String.duplicate("a", 64),
      execution_principal: "agent_x",
      logs_root: "/tmp/not-a-coding-root"
    }

    # An unavailable coding logs root must remain TaskStore-owned. Letting the
    # generic coordinator proceed here could create a second lifecycle writer.
    assert {:skip, :task_store_owned} =
             CodingRunRecovery.resolve_coordinator_options(record)
  end

  test "read_task_terminal returns a matching archive and not_found otherwise" do
    root = Path.join(System.tmp_dir!(), "g3b-term-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    assert {:error, :not_found} = ArtifactStore.read_task_terminal(root, "task_receipt")
  end

  test "duplicate engine-terminal receipt with a different digest is rejected" do
    root = Path.join(System.tmp_dir!(), "g3b-receipt-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    on_exit(fn -> File.rm_rf(root) end)

    receipt = closed_receipt("success")
    assert :ok = ArtifactStore.archive_engine_terminal(root, receipt)

    other = %{
      receipt
      | "canonical_status" => "failed",
        "idempotence_key" => String.duplicate("d", 64)
    }

    assert {:error, :stale_or_duplicate_terminal} =
             ArtifactStore.archive_engine_terminal(root, other)

    assert :ok = ArtifactStore.archive_engine_terminal(root, receipt)
  end

  test "closed receipt rejects extra keys and full context snapshots" do
    receipt = Map.put(closed_receipt("success"), "context", %{"status" => "success"})
    assert {:error, :invalid_receipt} = CodingRunRecoveryCore.closed_receipt?(receipt)
  end

  test "security regression: normal recover close is required and kill still zeros broker handles" do
    {:ok, identity} = Identity.generate(name: "g3b-normal-owner")
    public_identity = Identity.public_only(identity)
    :ok = Security.register_identity(public_identity)
    :ok = Security.store_signing_key(identity.agent_id, identity.private_key)

    on_exit(fn ->
      _ = Security.delete_signing_key(identity.agent_id)
      _ = Security.deregister_identity(identity.agent_id)
    end)

    before = broker_authority_count()

    assert {:ok, authority, security} =
             CodingRunRecovery.acquire_resume_authority(identity.agent_id)

    assert security == Security
    assert broker_authority_count() > before
    assert :ok = CodingRunRecovery.close_authority(Security, authority)
    assert wait_until(fn -> broker_authority_count() <= before end)
  end

  test "security regression: killing the recover owner closes the broker handle" do
    {:ok, identity} = Identity.generate(name: "g3b-kill-owner")
    public_identity = Identity.public_only(identity)
    :ok = Security.register_identity(public_identity)
    :ok = Security.store_signing_key(identity.agent_id, identity.private_key)

    on_exit(fn ->
      _ = Security.delete_signing_key(identity.agent_id)
      _ = Security.deregister_identity(identity.agent_id)
    end)

    parent = self()
    before = broker_authority_count()

    owner =
      spawn(fn ->
        case CodingRunRecovery.acquire_resume_authority(identity.agent_id) do
          {:ok, _authority, _security} ->
            send(parent, :opened)
            Process.sleep(60_000)

          other ->
            send(parent, {:open_failed, other})
        end
      end)

    assert_receive :opened, 5_000
    assert broker_authority_count() > before

    true = Process.exit(owner, :kill)
    refute Process.alive?(owner)

    assert wait_until(fn -> broker_authority_count() <= before end)
  end

  test "authority-close settlement persists only a bounded cause summary" do
    resume_value = %{
      context: %{"status" => "change_committed", "prose" => "model text"},
      final_outcome: %{status: :success}
    }

    assert {:error, {:authority_close_failed, :forced_close, :resume_succeeded}} =
             CodingRunRecoveryCore.combine_close_result(
               {:error, :forced_close},
               {:ok, resume_value}
             )

    inspected =
      inspect(
        {:authority_close_failed, :forced_close, :resume_succeeded},
        limit: :infinity,
        printable_limit: :infinity
      )

    refute inspected =~ "model text"
    refute inspected =~ "final_outcome"
    refute inspected =~ "SigningAuthority"
  end

  defp broker_authority_count do
    case Process.whereis(SigningAuthorityBroker) do
      pid when is_pid(pid) ->
        state = :sys.get_state(pid)
        map_size(Map.get(state, :authorities, %{}))

      _ ->
        0
    end
  end

  defp wait_until(fun, attempts \\ 50) do
    cond do
      fun.() ->
        true

      attempts <= 0 ->
        flunk("timeout waiting for broker handle cleanup")

      true ->
        Process.sleep(20)
        wait_until(fun, attempts - 1)
    end
  end

  defp closed_receipt(status) do
    hash = String.duplicate("a", 64)
    identity = String.duplicate("c", 64)

    %{
      "schema_version" => 1,
      "task_id" => "task_receipt",
      "run_id" => "task_receipt",
      "execution_principal" => "agent_1",
      "control_principal_id" => "caller_1",
      "graph_hash" => hash,
      "artifact_identity" => identity,
      "idempotence_key" =>
        CodingRunRecoveryCore.idempotence_key(
          "task_receipt",
          "task_receipt",
          hash,
          identity,
          status
        ),
      "final_outcome_status" => status,
      "coding_status" => status,
      "canonical_status" => status,
      "error" => "",
      "worker_provider" => "grok",
      "requested_model" => "grok-4.6",
      "confirmed_model" => "grok-4.6",
      "delivery_state" => "delivered",
      "completion_state" => "end_turn",
      "worker_session_id" => "",
      "worker_provider_session_id" => "",
      "workspace_id" => "",
      "branch" => "",
      "base_commit" => "",
      "commit" => "",
      "commit_hash" => "",
      "workspace_release_status" => "",
      "plan_digest" => "",
      "pipeline_digest" => hash,
      "manifest_digest" => "",
      "node_failure_reasons" => %{},
      "adapter_input_digest" => "",
      "decision_digest" => String.duplicate("e", 64)
    }
  end
end
