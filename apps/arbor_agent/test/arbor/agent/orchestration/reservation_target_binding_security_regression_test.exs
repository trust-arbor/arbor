defmodule Arbor.Agent.Orchestration.ReservationTargetBindingSecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Agent.Orchestration.{TaskControlRecoveryMemory, TaskStore}

  defmodule HangRunner do
    @moduledoc false

    def run(_agent_id, _task, _context) do
      Process.sleep(60_000)
      {:ok, %{}}
    end
  end

  setup do
    TaskControlRecoveryMemory.ensure!()
    TaskControlRecoveryMemory.reset!()

    supervisor_name = unique(:supervisor)
    supervisor = start_supervised!({Task.Supervisor, name: supervisor_name}, id: supervisor_name)
    store_name = unique(:store)

    store =
      start_supervised!(
        {TaskStore,
         name: store_name,
         task_supervisor: supervisor,
         cleanup_supervisor: supervisor,
         recovery_force_ready: true,
         task_control_recovery_facade: TaskControlRecoveryMemory,
         runner: HangRunner},
        id: store_name
      )

    %{store: store}
  end

  test "security regression: reservation activation rejects an invalid replacement target", %{
    store: store
  } do
    assert {:ok, %{task_id: task_id, reservation_token: token}} =
             reserve_for_current_api("agent_target1", store)

    assert {:error, :reservation_target_mismatch} =
             TaskStore.activate("invalid-target", "work", task_id, token, name: store)
  end

  defp reserve_for_current_api(target_agent_id, store) do
    if function_exported?(TaskStore, :reserve, 2) do
      apply(TaskStore, :reserve, [target_agent_id, [name: store]])
    else
      apply(TaskStore, :reserve, [[name: store]])
    end
  end

  defp unique(prefix) do
    String.to_atom("#{prefix}_#{System.unique_integer([:positive, :monotonic])}")
  end
end
