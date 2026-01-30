defmodule Arbor.Shell.ExecutionRegistryTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Shell.ExecutionRegistry

  describe "register/2 and get/1" do
    test "registers and retrieves execution" do
      {:ok, id} = ExecutionRegistry.register("echo test")
      {:ok, exec} = ExecutionRegistry.get(id)

      assert exec.id == id
      assert exec.command == "echo test"
      assert exec.status == :pending
      assert exec.result == nil
    end

    test "returns not_found for unknown ID" do
      assert {:error, :not_found} = ExecutionRegistry.get("exec_nonexistent")
    end
  end

  describe "update_status/3" do
    test "updates execution status" do
      {:ok, id} = ExecutionRegistry.register("echo test")

      assert :ok = ExecutionRegistry.update_status(id, :running)

      {:ok, exec} = ExecutionRegistry.get(id)
      assert exec.status == :running
    end

    test "sets completed_at for terminal statuses" do
      {:ok, id} = ExecutionRegistry.register("echo test")

      :ok = ExecutionRegistry.update_status(id, :completed, %{result: %{exit_code: 0}})

      {:ok, exec} = ExecutionRegistry.get(id)
      assert exec.status == :completed
      assert exec.completed_at != nil
      assert exec.result == %{exit_code: 0}
    end

    test "does not set completed_at for non-terminal status" do
      {:ok, id} = ExecutionRegistry.register("echo test")

      :ok = ExecutionRegistry.update_status(id, :running)

      {:ok, exec} = ExecutionRegistry.get(id)
      assert exec.completed_at == nil
    end

    test "returns not_found for unknown ID" do
      assert {:error, :not_found} =
               ExecutionRegistry.update_status("exec_nonexistent", :completed)
    end
  end

  describe "list/1" do
    test "returns all executions" do
      {:ok, _} = ExecutionRegistry.register("echo list1")
      {:ok, _} = ExecutionRegistry.register("echo list2")

      {:ok, execs} = ExecutionRegistry.list()
      assert is_list(execs)
    end

    test "filters by status" do
      {:ok, id1} = ExecutionRegistry.register("echo pending")
      {:ok, id2} = ExecutionRegistry.register("echo done")

      :ok = ExecutionRegistry.update_status(id2, :completed)

      {:ok, completed} = ExecutionRegistry.list(status: :completed)
      completed_ids = Enum.map(completed, & &1.id)

      assert id2 in completed_ids
      refute id1 in completed_ids
    end

    test "respects limit" do
      for _ <- 1..5 do
        ExecutionRegistry.register("echo limited")
      end

      {:ok, execs} = ExecutionRegistry.list(limit: 2)
      assert length(execs) <= 2
    end
  end

  describe "cleanup/1" do
    test "removes old completed executions" do
      {:ok, id} = ExecutionRegistry.register("echo old")

      # Mark as completed with a past timestamp
      :ok = ExecutionRegistry.update_status(id, :completed, %{result: %{exit_code: 0}})

      # Cleanup with 0-second TTL (removes everything completed)
      ExecutionRegistry.cleanup(0)
      # Give GenServer time to process the cast
      Process.sleep(50)

      assert {:error, :not_found} = ExecutionRegistry.get(id)
    end

    test "preserves running executions" do
      {:ok, id} = ExecutionRegistry.register("echo running")
      :ok = ExecutionRegistry.update_status(id, :running)

      ExecutionRegistry.cleanup(0)
      Process.sleep(50)

      assert {:ok, exec} = ExecutionRegistry.get(id)
      assert exec.status == :running
    end
  end
end
