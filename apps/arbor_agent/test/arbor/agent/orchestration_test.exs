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

  defmodule FakeConsensus do
    def list_pending do
      Process.get({__MODULE__, :pending}, [])
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
      Process.get({__MODULE__, :answer_result}, :ok)
    end
  end

  defmodule FakeTaskStore do
    def dispatch(agent_id, task, opts) do
      send(self(), {:task_dispatch, agent_id, task, opts})
      Process.get({__MODULE__, :dispatch_result}, {:ok, "task_1"})
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

  setup do
    for key <- [
          {FakeSecurity, :result},
          {FakeConsensus, :pending},
          {FakeConsensus, :answer_result},
          {FakeInteractionRouter, :pending},
          {FakeInteractionRouter, :answer_result},
          {FakeTaskStore, :dispatch_result},
          {FakeTaskStore, :status_result},
          {FakeTaskStore, :result_result}
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
                 metadata: %{ticket: "A-1"},
                 task_store: FakeTaskStore,
                 security_module: FakeSecurity,
                 audit_module: FakeAudit
               )

      assert_received {:authorize, "human_1", "arbor://agent/dispatch/agent_1", :execute,
                       [verify_identity: false]}

      assert_received {:task_dispatch, "agent_1", "write a patch", opts}
      assert opts[:metadata] == %{ticket: "A-1"}

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
        [consensus_proposal("prop_approval", "agent_1", "arbor://fs/write/repo/lib.ex")]
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

  defp interaction_request(id, agent_id, user_id, resource_uri) do
    %{
      request_id: id,
      kind: :approval,
      agent_id: agent_id,
      user_id: user_id,
      description: "Authorization request for #{resource_uri}",
      resource_uri: resource_uri,
      metadata: %{principal_id: agent_id},
      submitted_at: DateTime.utc_now()
    }
  end
end
