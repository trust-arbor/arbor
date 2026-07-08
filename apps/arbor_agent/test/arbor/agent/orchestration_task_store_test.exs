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
               metadata: %{ticket: "A-1"}
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
end
