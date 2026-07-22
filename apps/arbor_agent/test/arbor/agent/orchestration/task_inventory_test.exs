defmodule Arbor.Agent.OrchestrationTaskInventoryTest do
  use ExUnit.Case, async: true

  alias Arbor.Agent.Orchestration
  alias Arbor.Agent.Orchestration.TaskStore

  @moduletag :fast
  @timestamp ~U[2026-07-22 12:00:00Z]

  test "TaskStore inventory is read-only and reports owner liveness" do
    unique = System.unique_integer([:positive])
    supervisor = Module.concat(__MODULE__, :"TaskSupervisor#{unique}")
    store = Module.concat(__MODULE__, :"TaskStore#{unique}")

    start_supervised!({Task.Supervisor, name: supervisor})
    start_supervised!({TaskStore, name: store, task_supervisor: supervisor})

    record = %{
      task_id: "task-live",
      agent_id: "agent-a",
      state: :running,
      current_step: "running",
      waiting_on: nil,
      started_at: @timestamp,
      updated_at: @timestamp,
      completed_at: nil,
      controls: [],
      pid: self(),
      result: nil,
      error: nil
    }

    :sys.replace_state(store, fn state -> %{state | tasks: %{"task-live" => record}} end)
    before = :sys.get_state(store)

    assert {:ok, inventory} = TaskStore.inventory(name: store, max_items: 10)
    after_state = :sys.get_state(store)

    assert before == after_state
    assert hd(inventory["tasks"])["owner_process"] == %{"present" => true, "alive" => true}
    assert inventory["storage"] == %{"durability" => "volatile"}
  end

  test "security regression: forged selector-bearing inventory messages are rejected safely" do
    unique = System.unique_integer([:positive])
    supervisor = Module.concat(__MODULE__, :"ForgedTaskSupervisor#{unique}")
    store = Module.concat(__MODULE__, :"ForgedTaskStore#{unique}")

    start_supervised!({Task.Supervisor, name: supervisor})
    start_supervised!({TaskStore, name: store, task_supervisor: supervisor})
    Process.register(self(), :inventory_forgery_probe)

    before = :sys.get_state(store)

    assert {:error, :invalid_task_inventory_message} =
             GenServer.call(store, {:inventory, %{}, 10, EvilProjection})

    refute_received :evil_projection_executed
    assert before == :sys.get_state(store)
  end

  test "security regression: public inventory rejects executable and selector injection" do
    rejected = [
      [caller_id: "operator", runner: fn -> :evil end],
      [caller_id: "operator", name: self()],
      [caller_id: "operator", task_store: EvilTaskStore],
      [caller_id: "operator", projection: EvilProjection],
      [caller_id: "operator", security_module: EvilAuthorizer]
    ]

    for opts <- rejected do
      assert {:error, :invalid_task_inventory_options} = Orchestration.task_inventory(opts)
    end
  end

  test "requires a caller and the global read capability for an unfiltered inventory" do
    assert {:error, :invalid_task_inventory_options} = Orchestration.task_inventory([])

    caller = "inventory-operator-#{System.unique_integer([:positive])}"

    assert {:error, {:unauthorized, :task_read_required}} =
             Orchestration.task_inventory(caller_id: caller)
  end

  test "rejects invalid inventory bounds and filters before touching authorization" do
    assert {:error, :invalid_task_inventory_options} =
             Orchestration.task_inventory(caller_id: "operator", max_items: 1_001)

    assert {:error, :invalid_task_inventory_options} =
             Orchestration.task_inventory(caller_id: "operator", state: :unknown)

    assert {:error, :invalid_task_inventory_options} =
             Orchestration.task_inventory(caller_id: "operator", agent_id: <<0>>)
  end

  defmodule EvilTaskStore do
  end

  defmodule EvilProjection do
    def from_state(_state, _filters, _max_items, _owner_statuses) do
      send(Process.whereis(:inventory_forgery_probe), :evil_projection_executed)
      %{}
    end
  end

  defmodule EvilAuthorizer do
  end
end
