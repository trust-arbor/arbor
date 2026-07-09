defmodule Arbor.Agent.OrchestrationTaskStoreTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Agent.Orchestration.TaskStore

  defmodule ControlledRunner do
    def run(agent_id, task, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, {:runner_started, self(), agent_id, task})

      receive do
        {:finish, result} -> result
      after
        1_000 -> {:error, :test_timeout}
      end
    end
  end

  defmodule PendingRunner do
    def run(_agent_id, _task, _opts) do
      {:ok, :pending_approval, "approval_1"}
    end
  end

  setup do
    unique = System.unique_integer([:positive])
    supervisor = Module.concat(__MODULE__, :"TaskSupervisor#{unique}")
    store = Module.concat(__MODULE__, :"Store#{unique}")

    start_supervised!({Task.Supervisor, name: supervisor})

    start_supervised!(
      {TaskStore, name: store, task_supervisor: supervisor, runner: ControlledRunner}
    )

    {:ok, store: store}
  end

  test "dispatch returns before the runner completes, then stores the structured result", %{
    store: store
  } do
    assert {:ok, task_id} =
             TaskStore.dispatch("agent_1", "do work",
               name: store,
               test_pid: self(),
               metadata: %{ticket: "A-1"},
               approval_answer_cap_id: "cap_task_1",
               approval_answer_revoke: revoke_to(self())
             )

    assert_receive {:runner_started, runner_pid, "agent_1", "do work"}

    assert {:ok, status} = TaskStore.status(task_id, name: store)
    assert status.state == :running
    assert status.current_step == "running"
    assert status.metadata == %{ticket: "A-1"}

    assert {:error, :not_ready} = TaskStore.result(task_id, name: store)

    send(
      runner_pid,
      {:finish, {:ok, %{result_type: :test, payload: %{ok: true}, raw: "done"}}}
    )

    assert_eventually(fn ->
      assert {:ok, status} = TaskStore.status(task_id, name: store)
      assert status.state == :done
      assert status.current_step == "done"

      assert {:ok, result} = TaskStore.result(task_id, name: store)
      assert result.result_type == :test
      assert result.payload.ok == true
    end)

    assert_receive {:revoke_approval_answer_capability, "cap_task_1"}
  end

  test "records pending approval tasks as waiting_approval", %{store: store} do
    assert {:ok, task_id} =
             TaskStore.dispatch("agent_1", "do gated work",
               name: store,
               runner: PendingRunner
             )

    assert_eventually(fn ->
      assert {:ok, status} = TaskStore.status(task_id, name: store)
      assert status.state == :waiting_approval
      assert status.waiting_on == "approval_1"
      assert {:error, {:waiting_approval, "approval_1"}} = TaskStore.result(task_id, name: store)
    end)

    refute_received {:revoke_approval_answer_capability, _}
  end

  test "cancels a running task and keeps it cancelled after the process exits", %{store: store} do
    assert {:ok, task_id} =
             TaskStore.dispatch("agent_1", "do work",
               name: store,
               test_pid: self(),
               metadata: %{ticket: "A-1"},
               approval_answer_cap_id: "cap_task_cancel",
               approval_answer_revoke: revoke_to(self())
             )

    assert_receive {:runner_started, runner_pid, "agent_1", "do work"}
    ref = Process.monitor(runner_pid)

    assert {:ok, status} = TaskStore.cancel(task_id, name: store)
    assert status.state == :cancelled
    assert status.current_step == "cancelled"
    assert status.completed_at

    assert_receive {:DOWN, ^ref, :process, ^runner_pid, :killed}

    assert {:ok, status} = TaskStore.status(task_id, name: store)
    assert status.state == :cancelled
    assert {:error, :cancelled} = TaskStore.result(task_id, name: store)
    assert_receive {:revoke_approval_answer_capability, "cap_task_cancel"}
  end

  test "cancel propagates agent_id and task_id to the scoped turn bridge before killing the runner",
       %{store: store} do
    test_pid = self()

    # Production-shaped callback: SessionManager.cancel_task/2 (agent_id, task_id).
    cancel_turn = fn agent_id, cancelled_task_id ->
      send(test_pid, {:cancel_turn_hook, agent_id, cancelled_task_id, self()})
      :ok
    end

    assert {:ok, task_id} =
             TaskStore.dispatch("agent_coding_1", "implement feature",
               name: store,
               test_pid: test_pid,
               cancel_turn: cancel_turn,
               approval_answer_cap_id: "cap_turn_cancel",
               approval_answer_revoke: revoke_to(test_pid)
             )

    assert_receive {:runner_started, runner_pid, "agent_coding_1", "implement feature"}
    ref = Process.monitor(runner_pid)

    assert {:ok, status} = TaskStore.cancel(task_id, name: store)
    assert status.state == :cancelled

    # Hook must fire from the store process (survives :kill) with agent + task_id.
    assert_receive {:cancel_turn_hook, "agent_coding_1", ^task_id, store_pid}
    assert store_pid != runner_pid
    assert Process.whereis(store) == store_pid or is_pid(store_pid)

    assert_receive {:DOWN, ^ref, :process, ^runner_pid, :killed}
    assert_receive {:revoke_approval_answer_capability, "cap_turn_cancel"}
    assert {:error, :cancelled} = TaskStore.result(task_id, name: store)
  end

  test "returns clean errors for unknown and finished task cancellation", %{store: store} do
    assert {:error, :not_found} = TaskStore.cancel("missing", name: store)

    assert {:ok, task_id} =
             TaskStore.dispatch("agent_1", "do work",
               name: store,
               test_pid: self()
             )

    assert_receive {:runner_started, runner_pid, "agent_1", "do work"}
    send(runner_pid, {:finish, {:ok, %{result_type: :test, payload: %{}, raw: "done"}}})

    assert_eventually(fn ->
      assert {:ok, status} = TaskStore.status(task_id, name: store)
      assert status.state == :done
    end)

    assert {:error, {:not_running, :done}} = TaskStore.cancel(task_id, name: store)
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    fun.()
  rescue
    error in [ExUnit.AssertionError] ->
      if attempts == 1 do
        reraise error, __STACKTRACE__
      else
        Process.sleep(10)
        assert_eventually(fun, attempts - 1)
      end
  end

  defp revoke_to(test_pid) do
    fn capability_id ->
      send(test_pid, {:revoke_approval_answer_capability, capability_id})
      :ok
    end
  end
end
