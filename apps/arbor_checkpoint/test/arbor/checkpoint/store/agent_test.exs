defmodule Arbor.Checkpoint.Store.AgentTest do
  use ExUnit.Case, async: false

  alias Arbor.Checkpoint.Store.Agent, as: AgentStore

  import Arbor.Checkpoint.TestHelpers, only: [safe_stop: 1]

  @moduletag :fast

  setup do
    {:ok, pid} = AgentStore.start_link()
    on_exit(fn -> safe_stop(pid) end)
    {:ok, pid: pid}
  end

  describe "put/3" do
    test "stores checkpoint" do
      checkpoint = %{data: %{counter: 42}, timestamp: 123, node: node(), version: "1.0.0"}

      assert :ok = AgentStore.put("test_id", checkpoint)
      assert {:ok, ^checkpoint} = AgentStore.get("test_id")
    end

    test "overwrites existing checkpoint" do
      checkpoint1 = %{data: %{v: 1}, timestamp: 1, node: node(), version: "1.0.0"}
      checkpoint2 = %{data: %{v: 2}, timestamp: 2, node: node(), version: "1.0.0"}

      :ok = AgentStore.put("test_id", checkpoint1)
      :ok = AgentStore.put("test_id", checkpoint2)

      assert {:ok, ^checkpoint2} = AgentStore.get("test_id")
    end
  end

  describe "get/2" do
    test "retrieves existing checkpoint" do
      checkpoint = %{data: "test", timestamp: 123, node: node(), version: "1.0.0"}
      :ok = AgentStore.put("test_id", checkpoint)

      assert {:ok, ^checkpoint} = AgentStore.get("test_id")
    end

    test "returns error for non-existent checkpoint" do
      assert {:error, :not_found} = AgentStore.get("nonexistent")
    end
  end

  describe "delete/2" do
    test "removes checkpoint" do
      checkpoint = %{data: "test", timestamp: 123, node: node(), version: "1.0.0"}
      :ok = AgentStore.put("test_id", checkpoint)

      assert :ok = AgentStore.delete("test_id")
      assert {:error, :not_found} = AgentStore.get("test_id")
    end

    test "succeeds for non-existent checkpoint" do
      assert :ok = AgentStore.delete("nonexistent")
    end
  end

  describe "list/1" do
    test "returns empty list when no checkpoints" do
      assert {:ok, []} = AgentStore.list()
    end

    test "returns all checkpoint IDs" do
      :ok = AgentStore.put("id_1", %{data: 1, timestamp: 1, node: node(), version: "1.0.0"})
      :ok = AgentStore.put("id_2", %{data: 2, timestamp: 2, node: node(), version: "1.0.0"})

      assert {:ok, ids} = AgentStore.list()
      assert Enum.sort(ids) == ["id_1", "id_2"]
    end
  end

  describe "exists?/2" do
    test "returns true for existing checkpoint" do
      :ok = AgentStore.put("test_id", %{data: "test", timestamp: 123, node: node(), version: "1.0.0"})

      assert AgentStore.exists?("test_id")
    end

    test "returns false for non-existent checkpoint" do
      refute AgentStore.exists?("nonexistent")
    end
  end

  describe "clear/0" do
    test "removes all checkpoints" do
      :ok = AgentStore.put("id_1", %{data: 1, timestamp: 1, node: node(), version: "1.0.0"})
      :ok = AgentStore.put("id_2", %{data: 2, timestamp: 2, node: node(), version: "1.0.0"})

      assert AgentStore.count() == 2
      assert :ok = AgentStore.clear()
      assert AgentStore.count() == 0
    end
  end

  describe "count/0" do
    test "returns number of checkpoints" do
      assert AgentStore.count() == 0

      :ok = AgentStore.put("id_1", %{data: 1, timestamp: 1, node: node(), version: "1.0.0"})
      assert AgentStore.count() == 1

      :ok = AgentStore.put("id_2", %{data: 2, timestamp: 2, node: node(), version: "1.0.0"})
      assert AgentStore.count() == 2
    end
  end
end
