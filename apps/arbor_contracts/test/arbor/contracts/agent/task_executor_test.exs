defmodule Arbor.Contracts.Agent.TaskExecutorTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Contracts.Agent.TaskExecutor

  defmodule CompliantExecutor do
    @behaviour TaskExecutor

    @impl true
    def run(agent_id, task, context) when is_binary(agent_id) do
      {:ok,
       %{
         result_type: :test,
         payload: %{agent_id: agent_id, task: task, context: context},
         raw: "ok"
       }}
    end
  end

  defmodule FullExecutor do
    @behaviour TaskExecutor

    @impl true
    def run(_agent_id, _task, _context), do: {:ok, %{result_type: :test, payload: %{}, raw: "ok"}}

    @impl true
    def task_status(_agent_id, _context) do
      {:ok, %{"current_step" => "compiling", "waiting_on" => nil}}
    end

    @impl true
    def cancel_task(_agent_id, _context), do: :ok

    @impl true
    def steer_task(_agent_id, _control, _context), do: {:ok, :native_tool_loop}

    @impl true
    def finalize_task(_agent_id, result, _reconciled_controls, _context), do: {:ok, result}
  end

  defmodule PendingApprovalExecutor do
    @behaviour TaskExecutor

    @impl true
    def run(_agent_id, _task, _context) do
      {:ok, :pending_approval, "approval_contract_1"}
    end
  end

  test "behaviour callback is implemented by compliant modules" do
    assert function_exported?(CompliantExecutor, :run, 3)
    assert function_exported?(PendingApprovalExecutor, :run, 3)
  end

  test "optional progress, cancel, steering, and finalize callbacks are declared" do
    assert {:task_status, 2} in TaskExecutor.behaviour_info(:optional_callbacks)
    assert {:cancel_task, 2} in TaskExecutor.behaviour_info(:optional_callbacks)
    assert {:steer_task, 3} in TaskExecutor.behaviour_info(:optional_callbacks)
    assert {:finalize_task, 4} in TaskExecutor.behaviour_info(:optional_callbacks)
    assert {:run, 3} in TaskExecutor.behaviour_info(:callbacks)
    assert {:task_status, 2} in TaskExecutor.behaviour_info(:callbacks)
    assert {:cancel_task, 2} in TaskExecutor.behaviour_info(:callbacks)
    assert {:steer_task, 3} in TaskExecutor.behaviour_info(:callbacks)
    assert {:finalize_task, 4} in TaskExecutor.behaviour_info(:callbacks)

    assert function_exported?(FullExecutor, :task_status, 2)
    assert function_exported?(FullExecutor, :cancel_task, 2)
    assert function_exported?(FullExecutor, :steer_task, 3)
    assert function_exported?(FullExecutor, :finalize_task, 4)
    refute function_exported?(CompliantExecutor, :task_status, 2)
    refute function_exported?(CompliantExecutor, :cancel_task, 2)
    refute function_exported?(CompliantExecutor, :finalize_task, 4)
  end

  test "run/3 returns structured success with JSON-clean context" do
    task = %{"kind" => "coding_change", "input" => "ship it"}
    context = %{"task_id" => "task_1", "timeout" => 1_000, "caller_id" => "caller_1"}

    assert {:ok, result} = CompliantExecutor.run("agent_1", task, context)
    assert result.payload.agent_id == "agent_1"
    assert result.payload.task == task
    assert result.payload.context == context
  end

  test "run/3 preserves pending-approval result support" do
    assert {:ok, :pending_approval, "approval_contract_1"} =
             PendingApprovalExecutor.run("agent_1", "work", %{"task_id" => "task_1"})
  end

  test "task_status/2 and cancel_task/2 return contract shapes" do
    context = %{"task_id" => "task_1"}

    assert {:ok, progress} = FullExecutor.task_status("agent_1", context)
    assert progress["current_step"] == "compiling"
    assert progress["waiting_on"] == nil
    assert :ok = FullExecutor.cancel_task("agent_1", context)

    assert {:ok, :native_tool_loop} =
             FullExecutor.steer_task("agent_1", %{"control_id" => "ctl_1"}, context)
  end

  test "finalize_task/4 preserves a successful JSON-clean result payload" do
    result = %{"result_type" => "coding_change", "evidence" => %{"path" => "/tmp/evidence"}}
    controls = [%{"control_id" => "ctl_1", "status" => "delivered"}]
    context = %{"task_id" => "task_1"}

    assert {:ok, ^result} = FullExecutor.finalize_task("agent_1", result, controls, context)
  end

  test "behaviour module documents the contract" do
    assert {:docs_v1, _, :elixir, _, %{"en" => moduledoc}, _, _} =
             Code.fetch_docs(TaskExecutor)

    assert moduledoc =~ "JSON-clean"
    assert moduledoc =~ "pending_approval"
    assert moduledoc =~ "coding_change"
    assert moduledoc =~ "task_status"
    assert moduledoc =~ "cancel_task"
    assert moduledoc =~ "steer_task"
    assert moduledoc =~ "finalize_task"
    assert moduledoc =~ "terminal artifact retention"
    assert moduledoc =~ "terminal steering reconciliation"
    assert moduledoc =~ "explicit runner overrides do not invoke this callback"
    assert moduledoc =~ "transfers responsibility"
    assert moduledoc =~ "successful `run/3` return"
  end
end
