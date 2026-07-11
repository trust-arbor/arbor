defmodule Arbor.Agent.OrchestrationTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Agent.Orchestration
  alias Arbor.Agent.Orchestration.PendingApproval

  defmodule FakeSecurity do
    def authorize(actor, resource_uri, action, opts) do
      send(self(), {:authorize, actor, resource_uri, action, opts})
      Process.get({__MODULE__, :result}, {:ok, :authorized})
    end

    def grant(opts) do
      send(self(), {:grant, opts})
      Process.get({__MODULE__, :grant_result}, {:ok, %{id: "cap_task_answer"}})
    end

    def revoke(capability_id) do
      send(self(), {:revoke, capability_id})
      Process.get({__MODULE__, :revoke_result}, :ok)
    end
  end

  defmodule FakeScopedSecurity do
    def authorize(actor, resource_uri, action, opts) do
      send(self(), {:authorize, actor, resource_uri, action, opts})

      case resource_uri do
        "arbor://approval/answer/agent_1" -> {:ok, :authorized}
        "arbor://approval/read" -> {:ok, :authorized}
        _ -> {:error, :no_capability}
      end
    end
  end

  defmodule FakeTaskScopedSecurity do
    def authorize(actor, resource_uri, action, opts) do
      send(self(), {:authorize, actor, resource_uri, action, opts})

      case resource_uri do
        "arbor://approval/answer/task/task_1" -> {:ok, :authorized}
        "arbor://approval/read" -> {:ok, :authorized}
        _ -> {:error, :no_capability}
      end
    end
  end

  defmodule FakeTaskSteerSecurity do
    def authorize(actor, resource_uri, action, opts) do
      send(self(), {:authorize, actor, resource_uri, action, opts})

      case {actor, resource_uri} do
        {"dispatch_owner", "arbor://agent/dispatch/agent_1"} -> {:ok, :authorized}
        {"dispatch_owner", "arbor://agent/task/steer/task_1"} -> {:ok, :authorized}
        _ -> {:error, :no_capability}
      end
    end
  end

  defmodule DispatchScopedSecurity do
    def authorize(actor, resource_uri, _action, _opts) do
      send(self(), {:scoped_authorize, actor, resource_uri})

      cond do
        resource_uri == "arbor://agent/dispatch/agent_1" and actor == "dispatch_owner" ->
          {:ok, :authorized}

        Process.get({__MODULE__, :capabilities}, %{})[resource_uri] == actor ->
          {:ok, :authorized}

        true ->
          {:error, :no_capability}
      end
    end

    def grant(opts) do
      cap_id = "cap_" <> Integer.to_string(System.unique_integer([:positive]))
      capabilities = Process.get({__MODULE__, :capabilities}, %{})

      Process.put(
        {__MODULE__, :capabilities},
        Map.put(capabilities, opts[:resource], opts[:principal])
      )

      Process.put({__MODULE__, :capability_resources}, %{cap_id => opts[:resource]})
      {:ok, %{id: cap_id}}
    end

    def revoke(cap_id) do
      resources = Process.get({__MODULE__, :capability_resources}, %{})
      resource = Map.get(resources, cap_id)
      capabilities = Process.get({__MODULE__, :capabilities}, %{})
      Process.put({__MODULE__, :capabilities}, Map.delete(capabilities, resource))
      send(self(), {:scoped_revoke, cap_id, resource})
      :ok
    end
  end

  defmodule FakeConsensus do
    def list_pending do
      Process.get({__MODULE__, :pending}, [])
    end

    def cancel(id) do
      send(self(), {:consensus_cancel, id})
      result = Process.get({__MODULE__, :cancel_result}, :ok)

      if result == :ok do
        pending = Process.get({__MODULE__, :pending}, [])
        Process.put({__MODULE__, :pending}, Enum.reject(pending, &(Map.get(&1, :id) == id)))
      end

      result
    end

    def answer_authorization_request(id, decision, caller_id, opts) do
      send(self(), {:consensus_answer, id, decision, caller_id, opts})
      Process.get({__MODULE__, :answer_result}, :ok)
    end

    def force_approve(id, caller_id) do
      send(self(), {:consensus_force_approve, id, caller_id})
      Process.get({__MODULE__, :answer_result}, :ok)
    end

    def force_reject(id, caller_id) do
      send(self(), {:consensus_force_reject, id, caller_id})
      Process.get({__MODULE__, :answer_result}, :ok)
    end
  end

  defmodule FakeInteractionRouter do
    def pending do
      Process.get({__MODULE__, :pending}, [])
    end

    def respond(id, response, metadata) do
      send(self(), {:interaction_respond, id, response, metadata})
      result = Process.get({__MODULE__, :answer_result}, :ok)

      if result == :ok do
        pending = Process.get({__MODULE__, :pending}, [])

        Process.put(
          {__MODULE__, :pending},
          Enum.reject(pending, &(Map.get(&1, :request_id) == id))
        )
      end

      result
    end
  end

  defmodule FakeTaskStore do
    def dispatch(agent_id, task, opts) do
      send(self(), {:task_dispatch, agent_id, task, opts})
      Process.get({__MODULE__, :dispatch_result}, {:ok, opts[:task_id] || "task_1"})
    end

    def status(task_id, opts) do
      send(self(), {:task_status, task_id, opts})

      Process.get(
        {__MODULE__, :status_result},
        {:ok,
         %{
           task_id: task_id,
           agent_id: "agent_1",
           state: :running,
           current_step: "running",
           waiting_on: nil,
           started_at: DateTime.utc_now(),
           updated_at: DateTime.utc_now(),
           completed_at: nil,
           metadata: %{}
         }}
      )
    end

    def result(task_id, opts) do
      send(self(), {:task_result, task_id, opts})

      Process.get(
        {__MODULE__, :result_result},
        {:ok, %{result_type: :chat, payload: %{text: "done"}, raw: "done"}}
      )
    end

    def cancel(task_id, opts) do
      send(self(), {:task_cancel, task_id, opts})

      Process.get(
        {__MODULE__, :cancel_result},
        {:ok,
         %{
           task_id: task_id,
           agent_id: "agent_1",
           state: :cancelled,
           current_step: "cancelled",
           waiting_on: nil,
           started_at: DateTime.utc_now(),
           updated_at: DateTime.utc_now(),
           completed_at: DateTime.utc_now(),
           metadata: %{}
         }}
      )
    end

    def steer(task_id, message, opts) do
      send(self(), {:task_steer, task_id, message, opts})

      {:ok,
       %{
         "control_id" => "control_1",
         "task_id" => task_id,
         "sequence" => 1,
         "status" => "delivered",
         "sender_id" => opts[:sender_id],
         "message" => message,
         "queued_at" => "2026-07-10T12:00:00Z",
         "delivered_at" => "2026-07-10T12:00:01Z",
         "target_stage" => opts[:target_stage],
         "delivery_mode" => "native_tool_loop",
         "error" => nil
       }}
    end
  end

  defmodule TerminalTaskStore do
    def dispatch(_agent_id, _task, opts) do
      Process.put({__MODULE__, :dispatch_opts}, opts)
      {:ok, opts[:task_id]}
    end

    def status(task_id, _opts) do
      {:ok,
       %{
         task_id: task_id,
         agent_id: "agent_1",
         state: :running,
         current_step: "running",
         waiting_on: nil,
         started_at: DateTime.utc_now(),
         updated_at: DateTime.utc_now(),
         completed_at: nil,
         metadata: %{}
       }}
    end

    def steer(task_id, message, opts) do
      send(self(), {:terminal_store_steer, task_id, message, opts})
      {:ok, %{"control_id" => "control_1", "status" => "delivered"}}
    end

    def cancel(task_id, _opts) do
      dispatch_opts = Process.get({__MODULE__, :dispatch_opts}, [])
      dispatch_opts[:steer_security_module].revoke(dispatch_opts[:steer_cap_id])

      {:ok,
       %{
         task_id: task_id,
         agent_id: "agent_1",
         state: :cancelled,
         current_step: "cancelled",
         waiting_on: nil,
         started_at: DateTime.utc_now(),
         updated_at: DateTime.utc_now(),
         completed_at: DateTime.utc_now(),
         metadata: %{}
       }}
    end
  end

  defmodule FakeAudit do
    def record_approval_answered(actor_id, approval_id, source, decision, opts) do
      send(self(), {:audit_answered, actor_id, approval_id, source, decision, opts})
      :ok
    end

    def record_orchestration_task_dispatched(actor_id, task_id, agent_id, opts) do
      send(self(), {:audit_dispatched, actor_id, task_id, agent_id, opts})
      :ok
    end
  end

  # Process-safe backends for multi-process lifecycle cleanup (TaskStore async child).
  defmodule SharedApprovalState do
    @table __MODULE__.Table

    def ensure_table do
      case :ets.whereis(@table) do
        :undefined ->
          try do
            :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
          rescue
            ArgumentError -> :ok
          end

        _ ->
          :ok
      end
    end

    def install(owner, opts) do
      ensure_table()
      token = System.unique_integer([:positive])
      consensus_pending = Keyword.get(opts, :consensus_pending, [])
      interaction_pending = Keyword.get(opts, :interaction_pending, [])

      tracked_ids =
        Enum.map(consensus_pending, &Map.fetch!(&1, :id)) ++
          Enum.map(interaction_pending, &Map.fetch!(&1, :request_id))

      :ets.insert(
        @table,
        {token,
         %{
           owner: owner,
           consensus_pending: consensus_pending,
           interaction_pending: interaction_pending,
           tracked_ids: tracked_ids,
           cancel_result: Keyword.get(opts, :cancel_result, :ok),
           answer_result: Keyword.get(opts, :answer_result, :ok)
         }}
      )

      for proposal <- consensus_pending do
        id = Map.fetch!(proposal, :id)
        :ets.insert(@table, {{:consensus_id, id}, token})
        :ets.insert(@table, {{:owner_for, id}, owner})
      end

      for request <- interaction_pending do
        id = Map.fetch!(request, :request_id)
        :ets.insert(@table, {{:interaction_id, id}, token})
        :ets.insert(@table, {{:owner_for, id}, owner})
      end

      token
    end

    def uninstall(token) do
      ensure_table()

      case :ets.lookup(@table, token) do
        [{^token, state}] ->
          for id <- state.tracked_ids do
            :ets.delete(@table, {:consensus_id, id})
            :ets.delete(@table, {:interaction_id, id})
            :ets.delete(@table, {:owner_for, id})
          end

          :ets.delete(@table, token)

        _ ->
          :ok
      end
    end

    def consensus_pending do
      ensure_table()

      @table
      |> :ets.match_object({:_, :_})
      |> Enum.flat_map(fn
        {token, %{consensus_pending: pending}} when is_integer(token) -> pending
        _ -> []
      end)
    end

    def interaction_pending do
      ensure_table()

      @table
      |> :ets.match_object({:_, :_})
      |> Enum.flat_map(fn
        {token, %{interaction_pending: pending}} when is_integer(token) -> pending
        _ -> []
      end)
    end

    def cancel_consensus(id) do
      ensure_table()

      case :ets.lookup(@table, {:consensus_id, id}) do
        [{{:consensus_id, ^id}, token}] ->
          case :ets.lookup(@table, token) do
            [{^token, state}] ->
              send(state.owner, {:consensus_cancel, id})

              if state.cancel_result == :ok do
                pending = Enum.reject(state.consensus_pending, &(Map.get(&1, :id) == id))
                :ets.insert(@table, {token, %{state | consensus_pending: pending}})
                :ets.delete(@table, {:consensus_id, id})
              end

              state.cancel_result

            _ ->
              :ok
          end

        _ ->
          :ok
      end
    end

    def respond_interaction(id, response, metadata) do
      ensure_table()

      case :ets.lookup(@table, {:interaction_id, id}) do
        [{{:interaction_id, ^id}, token}] ->
          case :ets.lookup(@table, token) do
            [{^token, state}] ->
              send(state.owner, {:interaction_respond, id, response, metadata})

              if state.answer_result == :ok do
                pending =
                  Enum.reject(state.interaction_pending, &(Map.get(&1, :request_id) == id))

                :ets.insert(@table, {token, %{state | interaction_pending: pending}})
                :ets.delete(@table, {:interaction_id, id})
              end

              state.answer_result

            _ ->
              :ok
          end

        _ ->
          :ok
      end
    end

    def audit(actor_id, approval_id, source, decision, opts) do
      ensure_table()

      owner =
        case :ets.lookup(@table, {:owner_for, approval_id}) do
          [{{:owner_for, ^approval_id}, owner_pid}] when is_pid(owner_pid) -> owner_pid
          _ -> self()
        end

      send(owner, {:audit_answered, actor_id, approval_id, source, decision, opts})
      :ok
    end
  end

  defmodule SharedConsensus do
    def list_pending, do: SharedApprovalState.consensus_pending()
    def cancel(id), do: SharedApprovalState.cancel_consensus(id)

    def answer_authorization_request(id, decision, caller_id, opts) do
      send(self(), {:consensus_answer, id, decision, caller_id, opts})
      :ok
    end
  end

  defmodule SharedInteractionRouter do
    def pending, do: SharedApprovalState.interaction_pending()

    def respond(id, response, metadata),
      do: SharedApprovalState.respond_interaction(id, response, metadata)
  end

  defmodule SharedAudit do
    def record_approval_answered(actor_id, approval_id, source, decision, opts) do
      SharedApprovalState.audit(actor_id, approval_id, source, decision, opts)
    end

    def record_orchestration_task_dispatched(actor_id, task_id, agent_id, opts) do
      # Best-effort: message may land on cleanup owner or test process.
      send(self(), {:audit_dispatched, actor_id, task_id, agent_id, opts})
      :ok
    end
  end

  defmodule ControlledTaskRunner do
    def run(agent_id, task, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, {:runner_started, self(), agent_id, task, opts})

      receive do
        {:finish, result} -> result
      after
        2_000 -> {:error, :test_timeout}
      end
    end
  end

  setup do
    for key <- [
          {FakeSecurity, :result},
          {FakeSecurity, :grant_result},
          {FakeSecurity, :revoke_result},
          {FakeConsensus, :pending},
          {FakeConsensus, :answer_result},
          {FakeConsensus, :cancel_result},
          {FakeInteractionRouter, :pending},
          {FakeInteractionRouter, :answer_result},
          {FakeTaskStore, :dispatch_result},
          {FakeTaskStore, :status_result},
          {FakeTaskStore, :result_result},
          {FakeTaskStore, :cancel_result},
          {DispatchScopedSecurity, :capabilities},
          {DispatchScopedSecurity, :capability_resources},
          {TerminalTaskStore, :dispatch_opts}
        ] do
      Process.delete(key)
    end

    :ok
  end

  describe "dispatch/3" do
    test "dispatches a task asynchronously and records an audit event" do
      assert {:ok, "task_1"} =
               Orchestration.dispatch("agent_1", "write a patch",
                 caller_id: "human_1",
                 task_id: "task_1",
                 metadata: %{ticket: "A-1"},
                 task_store: FakeTaskStore,
                 security_module: FakeSecurity,
                 audit_module: FakeAudit
               )

      assert_received {:authorize, "human_1", "arbor://agent/dispatch/agent_1", :execute,
                       [verify_identity: false]}

      assert_received {:grant, grant_opts}
      assert grant_opts[:principal] == "human_1"
      assert grant_opts[:resource] == "arbor://approval/answer/task/task_1"
      assert grant_opts[:constraints] == %{}
      assert grant_opts[:metadata] == %{source: :orchestration_task_dispatch, task_id: "task_1"}

      assert_received {:grant, steer_grant_opts}
      assert steer_grant_opts[:resource] == "arbor://agent/task/steer/task_1"

      assert_received {:task_dispatch, "agent_1", "write a patch", opts}
      assert opts[:task_id] == "task_1"
      assert opts[:metadata] == %{ticket: "A-1"}
      assert opts[:approval_answer_cap_id] == "cap_task_answer"
      assert opts[:approval_answer_security_module] == FakeSecurity
      assert opts[:steer_cap_id] == "cap_task_answer"
      assert opts[:steer_security_module] == FakeSecurity

      descriptor = opts[:approval_cleanup_descriptor]
      assert is_map(descriptor)
      # Closed scalar authority boundary: caller_id + optional trace only.
      # Executable selectors (MFA/modules/functions/PIDs) are never present.
      assert descriptor == %{caller_id: "human_1"}
      refute Map.has_key?(descriptor, :mfa)
      refute Map.has_key?(descriptor, :module)
      refute Map.has_key?(descriptor, :function)
      refute Map.has_key?(descriptor, :fun)
      refute Map.has_key?(descriptor, :consensus_module)
      refute Map.has_key?(descriptor, :interaction_router)
      refute Map.has_key?(descriptor, :audit_module)
      refute Map.has_key?(descriptor, :notify_pid)
      refute Enum.any?(Map.values(descriptor), &(is_function(&1) or is_pid(&1) or is_tuple(&1)))

      assert_received {:audit_dispatched, "human_1", "task_1", "agent_1", audit_opts}
      assert audit_opts[:metadata] == %{ticket: "A-1"}
      assert audit_opts[:task_preview] == "write a patch"
    end

    test "denies dispatch before starting the task when caller lacks capability" do
      Process.put({FakeSecurity, :result}, {:error, :no_capability})

      assert {:error, {:unauthorized, :agent_dispatch_required}} =
               Orchestration.dispatch("agent_1", "write a patch",
                 caller_id: "human_1",
                 task_store: FakeTaskStore,
                 security_module: FakeSecurity,
                 audit_module: FakeAudit
               )

      refute_received {:task_dispatch, _, _, _}
      refute_received {:audit_dispatched, _, _, _, _}
    end

    test "fails before starting the task when the task approval-answer grant fails" do
      Process.put({FakeSecurity, :grant_result}, {:error, :store_down})

      assert {:error, {:approval_answer_grant_failed, :store_down}} =
               Orchestration.dispatch("agent_1", "write a patch",
                 caller_id: "human_1",
                 task_id: "task_1",
                 task_store: FakeTaskStore,
                 security_module: FakeSecurity,
                 audit_module: FakeAudit
               )

      assert_received {:grant, grant_opts}
      assert grant_opts[:resource] == "arbor://approval/answer/task/task_1"
      refute_received {:task_dispatch, _, _, _}
      refute_received {:audit_dispatched, _, _, _, _}
    end

    test "revokes the task approval-answer grant when task dispatch fails" do
      Process.put({FakeTaskStore, :dispatch_result}, {:error, :store_down})

      assert {:error, :store_down} =
               Orchestration.dispatch("agent_1", "write a patch",
                 caller_id: "human_1",
                 task_id: "task_1",
                 task_store: FakeTaskStore,
                 security_module: FakeSecurity,
                 audit_module: FakeAudit
               )

      assert_received {:grant, grant_opts}
      assert grant_opts[:resource] == "arbor://approval/answer/task/task_1"
      assert_received {:revoke, "cap_task_answer"}
      assert_received {:revoke, "cap_task_answer"}
      refute_received {:audit_dispatched, _, _, _, _}
    end
  end

  describe "task_status/2 and task_result/2" do
    test "returns status and result through the task store with read authorization" do
      assert {:ok, status} =
               Orchestration.task_status("task_1",
                 caller_id: "human_1",
                 task_store: FakeTaskStore,
                 security_module: FakeSecurity
               )

      assert status.task_id == "task_1"
      assert status.agent_id == "agent_1"
      assert status.state == :running

      assert_received {:authorize, "human_1", "arbor://agent/task/read/task_1", :read,
                       [verify_identity: false]}

      assert_received {:task_status, "task_1", _opts}

      assert {:ok, result} =
               Orchestration.task_result("task_1",
                 caller_id: "human_1",
                 task_store: FakeTaskStore,
                 security_module: FakeSecurity
               )

      assert result.result_type == :chat
      assert result.payload.text == "done"
      assert_received {:task_result, "task_1", _opts}
    end

    test "adapts raw coding action results into branch diff file report artifacts" do
      Process.put(
        {FakeTaskStore, :result_result},
        {:ok,
         %{
           status: "change_committed",
           branch: "agent/change",
           commit: "abc123",
           diff: "diff --git a/lib/a.ex b/lib/a.ex\n+ok\n",
           files: ["lib/a.ex"],
           validation: [%{command: "./bin/mix test", passed: true}],
           response_text: "STATUS: implemented",
           review_recommendation: :keep,
           tier_decision: :auto_proceed,
           human_required: false,
           security_veto: false
         }}
      )

      assert {:ok, result} =
               Orchestration.task_result("task_1",
                 caller_id: "human_1",
                 task_store: FakeTaskStore,
                 security_module: FakeSecurity
               )

      assert result.result_type == :coding_change
      assert result.payload.branch == "agent/change"
      assert result.payload.diff =~ "diff --git"
      assert result.payload.files == ["lib/a.ex"]
      assert result.payload.report.validation == [%{command: "./bin/mix test", passed: true}]
      assert result.payload.verdict.recommendation == :keep
      assert result.raw.status == "change_committed"
    end

    test "reports running tasks as waiting_approval when the shared queue has a pending item" do
      Process.put(
        {FakeConsensus, :pending},
        [
          consensus_proposal("prop_approval", "agent_1", "arbor://fs/write/repo/lib.ex",
            metadata: %{task_id: "task_1"}
          )
        ]
      )

      assert {:ok, status} =
               Orchestration.task_status("task_1",
                 caller_id: "human_1",
                 task_store: FakeTaskStore,
                 consensus_module: FakeConsensus,
                 interaction_router: FakeInteractionRouter,
                 security_module: FakeSecurity
               )

      assert status.state == :waiting_approval
      assert status.waiting_on == "prop_approval"

      assert {:error, {:waiting_approval, "prop_approval"}} =
               Orchestration.task_result("task_1",
                 caller_id: "human_1",
                 task_store: FakeTaskStore,
                 consensus_module: FakeConsensus,
                 interaction_router: FakeInteractionRouter,
                 security_module: FakeSecurity
               )
    end

    test "security regression: isolates pending approval projection by exact task id" do
      Process.put(
        {FakeConsensus, :pending},
        [
          consensus_proposal("prop_task_2", "agent_1", "arbor://fs/write/repo/two.ex",
            metadata: %{task_id: "task_2"}
          ),
          consensus_proposal("prop_task_1", "agent_1", "arbor://fs/write/repo/one.ex",
            metadata: %{task_id: "task_1"}
          )
        ]
      )

      opts = [
        caller_id: "human_1",
        task_store: FakeTaskStore,
        consensus_module: FakeConsensus,
        interaction_router: FakeInteractionRouter,
        security_module: FakeSecurity
      ]

      assert {:ok, task_1_status} = Orchestration.task_status("task_1", opts)
      assert task_1_status.state == :waiting_approval
      assert task_1_status.waiting_on == "prop_task_1"

      assert {:ok, unrelated_status} = Orchestration.task_status("task_3", opts)
      assert unrelated_status.state == :running
      assert unrelated_status.waiting_on == nil
    end
  end

  describe "cancel_task/2" do
    test "cancels through the task store with task-cancel authorization" do
      assert {:ok, status} =
               Orchestration.cancel_task("task_1",
                 caller_id: "human_1",
                 task_store: FakeTaskStore,
                 consensus_module: FakeConsensus,
                 interaction_router: FakeInteractionRouter,
                 security_module: FakeSecurity
               )

      assert status.task_id == "task_1"
      assert status.state == :cancelled

      assert_received {:authorize, "human_1", "arbor://agent/task/cancel/task_1", :execute,
                       [verify_identity: false]}

      assert_received {:task_status, "task_1", _opts}
      assert_received {:task_cancel, "task_1", _opts}
    end

    test "security regression: cancellation closes only approvals with the exact task provenance" do
      task_id = "task_22082"

      Process.put(
        {FakeConsensus, :pending},
        [
          consensus_proposal("prop_matching", "agent_1", "arbor://fs/write/repo/one.ex",
            metadata: %{provenance: %{task_id: task_id}}
          ),
          consensus_proposal("prop_prefix", "agent_1", "arbor://fs/write/repo/two.ex",
            metadata: %{provenance: %{task_id: task_id <> "0"}}
          ),
          consensus_proposal("prop_missing", "agent_1", "arbor://fs/write/repo/three.ex")
        ]
      )

      Process.put(
        {FakeInteractionRouter, :pending},
        [
          interaction_request("irq_matching", "agent_1", "human_1", "arbor://shell/exec/git",
            metadata: %{
              principal_id: "agent_1",
              approval_context: %{provenance: %{task_id: task_id}}
            }
          ),
          interaction_request("irq_other", "agent_1", "human_1", "arbor://shell/exec/mix",
            metadata: %{principal_id: "agent_1", task_id: "task_other"}
          ),
          interaction_request("irq_missing", "agent_1", "human_1", "arbor://fs/write/repo",
            metadata: %{principal_id: "agent_1"}
          )
        ]
      )

      opts = [
        caller_id: "human_1",
        task_store: FakeTaskStore,
        consensus_module: FakeConsensus,
        interaction_router: FakeInteractionRouter,
        security_module: FakeSecurity,
        audit_module: FakeAudit
      ]

      assert {:ok, %{task_id: ^task_id, state: :cancelled}} =
               Orchestration.cancel_task(task_id, opts)

      assert_received {:consensus_cancel, "prop_matching"}

      assert_received {:interaction_respond, "irq_matching", :rejected, metadata}
      assert metadata.actor == "human_1"
      assert metadata.task_id == task_id
      assert metadata.decision == :task_cancelled
      assert metadata.cleanup == :task_cancellation
      assert metadata.note =~ "task was cancelled"

      refute_received {:consensus_cancel, "prop_prefix"}
      refute_received {:consensus_cancel, "prop_missing"}
      refute_received {:interaction_respond, "irq_other", _, _}
      refute_received {:interaction_respond, "irq_missing", _, _}

      assert {:ok, remaining} =
               Orchestration.list_pending_approvals(
                 authorize?: false,
                 consensus_module: FakeConsensus,
                 interaction_router: FakeInteractionRouter
               )

      assert Enum.sort(Enum.map(remaining, & &1.id)) ==
               Enum.sort(["prop_prefix", "prop_missing", "irq_other", "irq_missing"])

      assert_received {:audit_answered, "human_1", "prop_matching", :consensus, :task_cancelled,
                       consensus_audit}

      assert consensus_audit[:task_id] == task_id
      assert consensus_audit[:cleanup] == :task_cancellation
      assert consensus_audit[:outcome] == :resolved

      assert_received {:audit_answered, "human_1", "irq_matching", :interaction, :task_cancelled,
                       interaction_audit}

      assert interaction_audit[:task_id] == task_id
      assert interaction_audit[:cleanup] == :task_cancellation
      assert interaction_audit[:outcome] == :resolved

      assert_received {:authorize, "human_1", "arbor://agent/task/cancel/" <> ^task_id, :execute,
                       [verify_identity: false]}

      refute_received {:authorize, _, _, _, _}
    end

    test "failed task cancellation leaves every pending approval untouched" do
      Process.put({FakeTaskStore, :cancel_result}, {:error, :executor_refused})

      Process.put(
        {FakeConsensus, :pending},
        [
          consensus_proposal("prop_matching", "agent_1", "arbor://fs/write/repo/one.ex",
            metadata: %{task_id: "task_1"}
          )
        ]
      )

      Process.put(
        {FakeInteractionRouter, :pending},
        [
          interaction_request("irq_matching", "agent_1", "human_1", "arbor://shell/exec/git",
            metadata: %{principal_id: "agent_1", provenance: %{task_id: "task_1"}}
          )
        ]
      )

      opts = [
        caller_id: "human_1",
        task_store: FakeTaskStore,
        consensus_module: FakeConsensus,
        interaction_router: FakeInteractionRouter,
        security_module: FakeSecurity,
        audit_module: FakeAudit
      ]

      assert {:error, :executor_refused} = Orchestration.cancel_task("task_1", opts)

      assert {:ok, remaining} =
               Orchestration.list_pending_approvals(
                 authorize?: false,
                 consensus_module: FakeConsensus,
                 interaction_router: FakeInteractionRouter
               )

      assert Enum.sort(Enum.map(remaining, & &1.id)) == ["irq_matching", "prop_matching"]
      refute_received {:consensus_cancel, _}
      refute_received {:interaction_respond, _, _, _}
      refute_received {:audit_answered, _, _, _, _, _}
    end

    test "repeated cancellation cleanup is harmless" do
      Process.put(
        {FakeConsensus, :pending},
        [
          consensus_proposal("prop_matching", "agent_1", "arbor://fs/write/repo/one.ex",
            metadata: %{task_id: "task_1"}
          )
        ]
      )

      Process.put(
        {FakeInteractionRouter, :pending},
        [
          interaction_request("irq_matching", "agent_1", "human_1", "arbor://shell/exec/git",
            metadata: %{principal_id: "agent_1", provenance: %{task_id: "task_1"}}
          )
        ]
      )

      opts = [
        caller_id: "human_1",
        task_store: FakeTaskStore,
        consensus_module: FakeConsensus,
        interaction_router: FakeInteractionRouter,
        security_module: FakeSecurity,
        audit_module: FakeAudit
      ]

      assert {:ok, %{state: :cancelled}} = Orchestration.cancel_task("task_1", opts)
      assert_received {:consensus_cancel, "prop_matching"}
      assert_received {:interaction_respond, "irq_matching", :rejected, _}

      assert {:ok, %{state: :cancelled}} = Orchestration.cancel_task("task_1", opts)
      refute_received {:consensus_cancel, _}
      refute_received {:interaction_respond, _, _, _}
    end

    test "already-resolved backend results do not fail a successful task cancellation" do
      Process.put({FakeConsensus, :cancel_result}, {:error, :already_decided})
      Process.put({FakeInteractionRouter, :answer_result}, {:error, :not_found})

      Process.put(
        {FakeConsensus, :pending},
        [
          consensus_proposal("prop_stale", "agent_1", "arbor://fs/write/repo/one.ex",
            metadata: %{task_id: "task_1"}
          )
        ]
      )

      Process.put(
        {FakeInteractionRouter, :pending},
        [
          interaction_request("irq_stale", "agent_1", "human_1", "arbor://shell/exec/git",
            metadata: %{principal_id: "agent_1", provenance: %{task_id: "task_1"}}
          )
        ]
      )

      assert {:ok, %{state: :cancelled}} =
               Orchestration.cancel_task("task_1",
                 caller_id: "human_1",
                 task_store: FakeTaskStore,
                 consensus_module: FakeConsensus,
                 interaction_router: FakeInteractionRouter,
                 security_module: FakeSecurity,
                 audit_module: FakeAudit
               )

      assert_received {:consensus_cancel, "prop_stale"}
      assert_received {:interaction_respond, "irq_stale", :rejected, _}

      assert_received {:audit_answered, "human_1", "prop_stale", :consensus, :task_cancelled,
                       consensus_audit}

      assert consensus_audit[:outcome] == :already_resolved
      assert consensus_audit[:error] == ":already_decided"

      assert_received {:audit_answered, "human_1", "irq_stale", :interaction, :task_cancelled,
                       interaction_audit}

      assert interaction_audit[:outcome] == :already_resolved
      assert interaction_audit[:error] == ":not_found"
    end

    test "denies unauthorized cancellation before calling the task store cancel" do
      Process.put({FakeSecurity, :result}, {:error, :no_capability})

      assert {:error, {:unauthorized, :task_cancel_required}} =
               Orchestration.cancel_task("task_1",
                 caller_id: "human_1",
                 task_store: FakeTaskStore,
                 security_module: FakeSecurity
               )

      refute_received {:task_cancel, _, _}
    end
  end

  describe "cleanup_approvals_for_task/2 lifecycle API" do
    test "terminates only exact provenance approvals on both backends with terminal audit metadata" do
      task_id = "task_term_22082"

      Process.put(
        {FakeConsensus, :pending},
        [
          consensus_proposal("prop_matching", "agent_1", "arbor://fs/write/repo/one.ex",
            metadata: %{provenance: %{task_id: task_id}}
          ),
          consensus_proposal("prop_prefix", "agent_1", "arbor://fs/write/repo/two.ex",
            metadata: %{provenance: %{task_id: task_id <> "0"}}
          ),
          consensus_proposal("prop_missing", "agent_1", "arbor://fs/write/repo/three.ex")
        ]
      )

      Process.put(
        {FakeInteractionRouter, :pending},
        [
          interaction_request("irq_matching", "agent_1", "human_1", "arbor://shell/exec/git",
            metadata: %{
              principal_id: "agent_1",
              approval_context: %{provenance: %{task_id: task_id}}
            }
          ),
          interaction_request("irq_other", "agent_1", "human_1", "arbor://shell/exec/mix",
            metadata: %{principal_id: "agent_1", task_id: "task_other"}
          )
        ]
      )

      assert :ok =
               Orchestration.cleanup_approvals_for_task(task_id,
                 caller_id: "dispatch_owner",
                 cleanup_reason: :task_termination,
                 consensus_module: FakeConsensus,
                 interaction_router: FakeInteractionRouter,
                 audit_module: FakeAudit,
                 trace_id: "trace_term"
               )

      assert_received {:consensus_cancel, "prop_matching"}

      assert_received {:interaction_respond, "irq_matching", :rejected, metadata}
      assert metadata.actor == "dispatch_owner"
      assert metadata.task_id == task_id
      assert metadata.decision == :task_terminated
      assert metadata.cleanup == :task_termination
      assert metadata.note =~ "task terminated"

      refute_received {:consensus_cancel, "prop_prefix"}
      refute_received {:consensus_cancel, "prop_missing"}
      refute_received {:interaction_respond, "irq_other", _, _}

      assert_received {:audit_answered, "dispatch_owner", "prop_matching", :consensus,
                       :task_terminated, consensus_audit}

      assert consensus_audit[:task_id] == task_id
      assert consensus_audit[:cleanup] == :task_termination
      assert consensus_audit[:outcome] == :resolved
      assert consensus_audit[:trace_id] == "trace_term"

      assert_received {:audit_answered, "dispatch_owner", "irq_matching", :interaction,
                       :task_terminated, interaction_audit}

      assert interaction_audit[:outcome] == :resolved
      assert interaction_audit[:cleanup] == :task_termination
    end

    test "already-resolved backend races are normalized for terminal cleanup" do
      Process.put({FakeConsensus, :cancel_result}, {:error, :already_decided})
      Process.put({FakeInteractionRouter, :answer_result}, {:error, :not_found})

      Process.put(
        {FakeConsensus, :pending},
        [
          consensus_proposal("prop_stale", "agent_1", "arbor://fs/write/repo/one.ex",
            metadata: %{task_id: "task_1"}
          )
        ]
      )

      Process.put(
        {FakeInteractionRouter, :pending},
        [
          interaction_request("irq_stale", "agent_1", "human_1", "arbor://shell/exec/git",
            metadata: %{principal_id: "agent_1", provenance: %{task_id: "task_1"}}
          )
        ]
      )

      assert :ok =
               Orchestration.cleanup_approvals_for_task("task_1",
                 caller_id: "dispatch_owner",
                 cleanup_reason: :task_termination,
                 consensus_module: FakeConsensus,
                 interaction_router: FakeInteractionRouter,
                 audit_module: FakeAudit
               )

      assert_received {:audit_answered, "dispatch_owner", "prop_stale", :consensus,
                       :task_terminated, consensus_audit}

      assert consensus_audit[:outcome] == :already_resolved
      assert consensus_audit[:error] == ":already_decided"

      assert_received {:audit_answered, "dispatch_owner", "irq_stale", :interaction,
                       :task_terminated, interaction_audit}

      assert interaction_audit[:outcome] == :already_resolved
      assert interaction_audit[:error] == ":not_found"
    end

    test "security regression: ordinary task termination closes only exact-provenance approvals" do
      task_id = "task_term_e2e_" <> Integer.to_string(System.unique_integer([:positive]))
      supervisor = :"term_cleanup_sup_#{System.unique_integer([:positive])}"
      store = :"term_cleanup_store_#{System.unique_integer([:positive])}"

      start_supervised!({Task.Supervisor, name: supervisor})

      # Cleanup backends/audit are store-init authority — not per-dispatch descriptors.
      start_supervised!(
        {Arbor.Agent.Orchestration.TaskStore,
         name: store,
         task_supervisor: supervisor,
         runner: ControlledTaskRunner,
         approval_cleanup_consensus_module: SharedConsensus,
         approval_cleanup_interaction_router: SharedInteractionRouter,
         approval_cleanup_audit_module: SharedAudit}
      )

      token =
        SharedApprovalState.install(self(),
          consensus_pending: [
            consensus_proposal("prop_match_" <> task_id, "agent_1", "arbor://fs/write/a.ex",
              metadata: %{provenance: %{task_id: task_id}}
            ),
            consensus_proposal("prop_prefix_" <> task_id, "agent_1", "arbor://fs/write/b.ex",
              metadata: %{provenance: %{task_id: task_id <> "x"}}
            )
          ],
          interaction_pending: [
            interaction_request(
              "irq_match_" <> task_id,
              "agent_1",
              "human_1",
              "arbor://shell/exec/git",
              metadata: %{
                principal_id: "agent_1",
                approval_context: %{provenance: %{task_id: task_id}}
              }
            ),
            interaction_request(
              "irq_other_" <> task_id,
              "agent_1",
              "human_1",
              "arbor://shell/exec/mix",
              metadata: %{principal_id: "agent_1", task_id: "task_other"}
            )
          ]
        )

      on_exit(fn -> SharedApprovalState.uninstall(token) end)

      opts = [
        caller_id: "dispatch_owner",
        task_id: task_id,
        task_store: Arbor.Agent.Orchestration.TaskStore,
        name: store,
        test_pid: self(),
        runner: ControlledTaskRunner,
        consensus_module: SharedConsensus,
        interaction_router: SharedInteractionRouter,
        security_module: FakeSecurity,
        audit_module: SharedAudit,
        authorize?: false,
        trace_id: "trace_e2e"
      ]

      assert {:ok, ^task_id} = Orchestration.dispatch("agent_1", "ordinary work", opts)
      assert_receive {:runner_started, runner_pid, "agent_1", "ordinary work", runner_opts}
      refute Keyword.has_key?(runner_opts, :approval_cleanup_descriptor)

      send(
        runner_pid,
        {:finish, {:ok, %{result_type: :test, payload: %{ok: true}, raw: "done"}}}
      )

      assert_receive {:consensus_cancel, prop_id}, 1_000
      assert prop_id == "prop_match_" <> task_id

      assert_receive {:interaction_respond, irq_id, :rejected, metadata}, 1_000
      assert irq_id == "irq_match_" <> task_id
      assert metadata.decision == :task_terminated
      assert metadata.cleanup == :task_termination
      assert metadata.actor == "dispatch_owner"
      assert metadata.task_id == task_id

      refute_receive {:consensus_cancel, _}, 200
      refute_receive {:interaction_respond, _, _, _}, 200

      assert {:ok, remaining} =
               Orchestration.list_pending_approvals(
                 authorize?: false,
                 consensus_module: SharedConsensus,
                 interaction_router: SharedInteractionRouter
               )

      remaining_ids = remaining |> Enum.map(& &1.id) |> Enum.sort()

      assert remaining_ids ==
               Enum.sort(["prop_prefix_" <> task_id, "irq_other_" <> task_id])

      assert {:ok, %{state: :done}} =
               Orchestration.task_status(task_id, Keyword.put(opts, :authorize?, false))

      assert {:ok, %{result_type: :test}} =
               Orchestration.task_result(task_id, Keyword.put(opts, :authorize?, false))
    end
  end

  describe "steer_task/3" do
    test "authorizes task-scoped steering and forwards the authenticated caller as sender" do
      assert {:ok, control} =
               Orchestration.steer_task("task_1", "run focused tests",
                 caller_id: "human_1",
                 target_stage: "validation",
                 task_store: FakeTaskStore,
                 security_module: FakeSecurity
               )

      assert control["status"] == "delivered"
      assert control["sender_id"] == "human_1"

      assert_received {:authorize, "human_1", "arbor://agent/task/steer/task_1", :execute,
                       [verify_identity: false]}

      assert_received {:task_steer, "task_1", "run focused tests", opts}
      assert opts[:sender_id] == "human_1"
      assert opts[:target_stage] == "validation"
    end

    test "security regression: a different caller cannot steer, and dispatch owner is scoped to its task" do
      base_opts = [task_store: FakeTaskStore, security_module: FakeTaskSteerSecurity]

      assert {:error, {:unauthorized, :task_steer_required}} =
               Orchestration.steer_task(
                 "task_1",
                 "redirect",
                 Keyword.put(base_opts, :caller_id, "other_caller")
               )

      refute_received {:task_steer, _, _, _}

      assert {:ok, _control} =
               Orchestration.steer_task(
                 "task_1",
                 "redirect",
                 Keyword.put(base_opts, :caller_id, "dispatch_owner")
               )

      assert_received {:task_steer, "task_1", "redirect", opts}
      assert opts[:sender_id] == "dispatch_owner"

      assert {:error, {:unauthorized, :task_steer_required}} =
               Orchestration.steer_task(
                 "task_2",
                 "cross-task",
                 Keyword.put(base_opts, :caller_id, "dispatch_owner")
               )

      refute_received {:task_steer, "task_2", _, _}
    end

    test "security regression: dispatch grants exact task steering and terminal cleanup revokes it" do
      opts = [
        caller_id: "dispatch_owner",
        task_id: "task_1",
        task_store: TerminalTaskStore,
        consensus_module: FakeConsensus,
        interaction_router: FakeInteractionRouter,
        security_module: DispatchScopedSecurity,
        audit_module: FakeAudit
      ]

      assert {:ok, "task_1"} = Orchestration.dispatch("agent_1", "work", opts)

      assert {:ok, _} = Orchestration.steer_task("task_1", "redirect", opts)
      assert_received {:terminal_store_steer, "task_1", "redirect", _}

      assert {:error, {:unauthorized, :task_steer_required}} =
               Orchestration.steer_task(
                 "task_1",
                 "redirect",
                 Keyword.put(opts, :caller_id, "other")
               )

      assert {:error, {:unauthorized, :task_steer_required}} =
               Orchestration.steer_task("task_2", "redirect", opts)

      assert {:ok, %{state: :cancelled}} =
               Orchestration.cancel_task("task_1", Keyword.put(opts, :authorize?, false))

      assert_received {:scoped_revoke, _cap_id, "arbor://agent/task/steer/task_1"}

      assert {:error, {:unauthorized, :task_steer_required}} =
               Orchestration.steer_task("task_1", "redirect", opts)
    end
  end

  describe "list_pending_approvals/1" do
    test "merges existing backends and filters by agent and segment-aware resource prefix" do
      Process.put(
        {FakeConsensus, :pending},
        [
          consensus_proposal("prop_read", "agent_1", "arbor://fs/read/repo/README.md"),
          consensus_proposal("prop_reader", "agent_1", "arbor://fs/reader/secrets"),
          consensus_proposal("prop_other_agent", "agent_2", "arbor://fs/read/repo/README.md"),
          %{id: "prop_non_auth", proposer: "agent_1", topic: :advisory, status: :pending}
        ]
      )

      Process.put(
        {FakeInteractionRouter, :pending},
        [
          interaction_request("irq_read", "agent_1", "human_1", "arbor://fs/read/repo/lib.ex"),
          interaction_request(
            "irq_other_agent",
            "agent_2",
            "human_1",
            "arbor://fs/read/repo/lib.ex"
          )
        ]
      )

      assert {:ok, approvals} =
               Orchestration.list_pending_approvals(
                 caller_id: "human_1",
                 agent_id: "agent_1",
                 resource_uri: "arbor://fs/read",
                 consensus_module: FakeConsensus,
                 interaction_router: FakeInteractionRouter,
                 security_module: FakeSecurity
               )

      assert Enum.map(approvals, & &1.id) == ["prop_read", "irq_read"]
      assert Enum.all?(approvals, &match?(%PendingApproval{}, &1))

      assert_received {:authorize, "human_1", "arbor://approval/read", :read,
                       [verify_identity: false]}
    end
  end

  describe "answer_approval/3" do
    test "answers interaction approvals and records an audit event" do
      Process.put(
        {FakeInteractionRouter, :pending},
        [interaction_request("irq_1", "agent_1", "human_1", "arbor://shell/exec/git")]
      )

      assert :ok =
               Orchestration.answer_approval("irq_1", :approve,
                 caller_id: "human_1",
                 note: "looks bounded",
                 consensus_module: FakeConsensus,
                 interaction_router: FakeInteractionRouter,
                 security_module: FakeSecurity,
                 audit_module: FakeAudit
               )

      assert_received {:authorize, "human_1", "arbor://approval/answer/agent_1", :execute,
                       [verify_identity: false]}

      assert_received {:interaction_respond, "irq_1", :approved, metadata}
      assert metadata.actor == "human_1"
      assert metadata.decision == :approve
      assert metadata.note == "looks bounded"

      assert_received {:audit_answered, "human_1", "irq_1", :interaction, :approve, opts}
      assert opts[:resource_uri] == "arbor://shell/exec/git"
      assert opts[:agent_id] == "agent_1"
    end

    test "maps rework to consensus rejection while preserving rework metadata" do
      Process.put(
        {FakeConsensus, :pending},
        [consensus_proposal("prop_1", "agent_1", "arbor://fs/write/repo/lib.ex")]
      )

      assert :ok =
               Orchestration.answer_approval("prop_1", :rework,
                 caller_id: "human_1",
                 note: "add a regression test first",
                 consensus_module: FakeConsensus,
                 interaction_router: FakeInteractionRouter,
                 security_module: FakeSecurity,
                 audit_module: FakeAudit
               )

      assert_received {:consensus_answer, "prop_1", :rework, "human_1", opts}
      assert opts[:rework] == true
      assert opts[:note] == "add a regression test first"

      assert_received {:audit_answered, "human_1", "prop_1", :consensus, :rework, audit_opts}
      assert audit_opts[:resource_uri] == "arbor://fs/write/repo/lib.ex"
    end

    test "accepts per-agent approval-answer capability without the global grant" do
      Process.put(
        {FakeInteractionRouter, :pending},
        [interaction_request("irq_1", "agent_1", "human_1", "arbor://shell/exec/git")]
      )

      assert :ok =
               Orchestration.answer_approval("irq_1", :approve,
                 caller_id: "human_1",
                 consensus_module: FakeConsensus,
                 interaction_router: FakeInteractionRouter,
                 security_module: FakeScopedSecurity,
                 audit_module: FakeAudit
               )

      assert_received {:authorize, "human_1", "arbor://approval/answer/agent_1", :execute,
                       [verify_identity: false]}

      assert_received {:interaction_respond, "irq_1", :approved, _metadata}
    end

    test "accepts task-scoped approval-answer capability for matching approval provenance" do
      Process.put(
        {FakeInteractionRouter, :pending},
        [
          interaction_request("irq_1", "agent_1", "human_1", "arbor://shell/exec/git",
            metadata: %{
              principal_id: "agent_1",
              approval_context: %{provenance: %{task_id: "task_1"}}
            }
          )
        ]
      )

      assert :ok =
               Orchestration.answer_approval("irq_1", :approve,
                 caller_id: "human_1",
                 consensus_module: FakeConsensus,
                 interaction_router: FakeInteractionRouter,
                 security_module: FakeTaskScopedSecurity,
                 audit_module: FakeAudit
               )

      assert_received {:authorize, "human_1", "arbor://approval/answer/task/task_1", :execute,
                       [verify_identity: false]}

      assert_received {:interaction_respond, "irq_1", :approved, _metadata}
    end

    test "does not allow task-scoped approval-answer capability for another task" do
      Process.put(
        {FakeInteractionRouter, :pending},
        [
          interaction_request("irq_1", "agent_1", "human_1", "arbor://shell/exec/git",
            metadata: %{
              principal_id: "agent_1",
              approval_context: %{provenance: %{task_id: "task_2"}}
            }
          )
        ]
      )

      assert {:error, {:unauthorized, :approval_answer_required}} =
               Orchestration.answer_approval("irq_1", :approve,
                 caller_id: "human_1",
                 consensus_module: FakeConsensus,
                 interaction_router: FakeInteractionRouter,
                 security_module: FakeTaskScopedSecurity,
                 audit_module: FakeAudit
               )

      refute_received {:interaction_respond, _, _, _}
      refute_received {:audit_answered, _, _, _, _, _}
    end

    test "denies unauthorized callers before resolving the backend request" do
      Process.put({FakeSecurity, :result}, {:error, :no_capability})

      Process.put(
        {FakeInteractionRouter, :pending},
        [interaction_request("irq_1", "agent_1", "human_1", "arbor://shell/exec/git")]
      )

      assert {:error, {:unauthorized, :approval_answer_required}} =
               Orchestration.answer_approval("irq_1", :approve,
                 caller_id: "human_1",
                 consensus_module: FakeConsensus,
                 interaction_router: FakeInteractionRouter,
                 security_module: FakeSecurity,
                 audit_module: FakeAudit
               )

      refute_received {:interaction_respond, _, _, _}
      refute_received {:audit_answered, _, _, _, _, _}
    end

    test "does not approve approval records marked as blocked" do
      Process.put(
        {FakeConsensus, :pending},
        [
          consensus_proposal("prop_blocked", "agent_1", "arbor://fs/write/repo/lib.ex",
            metadata: %{blocked: true}
          )
        ]
      )

      assert {:error, :blocked_approval_cannot_be_approved} =
               Orchestration.answer_approval("prop_blocked", :approve,
                 caller_id: "human_1",
                 consensus_module: FakeConsensus,
                 interaction_router: FakeInteractionRouter,
                 security_module: FakeSecurity,
                 audit_module: FakeAudit
               )

      refute_received {:consensus_answer, _, _, _, _}
      refute_received {:audit_answered, _, _, _, _, _}
    end
  end

  defp consensus_proposal(id, agent_id, resource_uri, opts \\ []) do
    metadata =
      %{principal_id: agent_id, resource_uri: resource_uri}
      |> Map.merge(Keyword.get(opts, :metadata, %{}))

    %{
      id: id,
      proposer: agent_id,
      topic: :authorization_request,
      description: "Authorization request for #{resource_uri}",
      metadata: metadata,
      context: %{},
      status: :pending,
      created_at: DateTime.utc_now()
    }
  end

  defp interaction_request(id, agent_id, user_id, resource_uri, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{principal_id: agent_id})

    %{
      request_id: id,
      kind: :approval,
      agent_id: agent_id,
      user_id: user_id,
      description: "Authorization request for #{resource_uri}",
      resource_uri: resource_uri,
      metadata: metadata,
      submitted_at: DateTime.utc_now()
    }
  end
end
