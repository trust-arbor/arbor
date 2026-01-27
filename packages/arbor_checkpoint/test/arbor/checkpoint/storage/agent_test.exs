defmodule Arbor.Checkpoint.Storage.AgentTest do
  use ExUnit.Case, async: false

  alias Arbor.Checkpoint.Storage.Agent, as: AgentStorage

  @moduletag :fast

  setup do
    {:ok, pid} = AgentStorage.start_link()
    on_exit(fn -> if Process.alive?(pid), do: AgentStorage.stop() end)
    {:ok, pid: pid}
  end

  describe "put/2" do
    test "stores checkpoint" do
      checkpoint = %{data: %{counter: 42}, timestamp: 123, node: node(), version: "1.0.0"}

      assert :ok = AgentStorage.put("test_id", checkpoint)
      assert {:ok, ^checkpoint} = AgentStorage.get("test_id")
    end

    test "overwrites existing checkpoint" do
      checkpoint1 = %{data: %{v: 1}, timestamp: 1, node: node(), version: "1.0.0"}
      checkpoint2 = %{data: %{v: 2}, timestamp: 2, node: node(), version: "1.0.0"}

      :ok = AgentStorage.put("test_id", checkpoint1)
      :ok = AgentStorage.put("test_id", checkpoint2)

      assert {:ok, ^checkpoint2} = AgentStorage.get("test_id")
    end
  end

  describe "get/1" do
    test "retrieves existing checkpoint" do
      checkpoint = %{data: "test", timestamp: 123, node: node(), version: "1.0.0"}
      :ok = AgentStorage.put("test_id", checkpoint)

      assert {:ok, ^checkpoint} = AgentStorage.get("test_id")
    end

    test "returns error for non-existent checkpoint" do
      assert {:error, :not_found} = AgentStorage.get("nonexistent")
    end
  end

  describe "delete/1" do
    test "removes checkpoint" do
      checkpoint = %{data: "test", timestamp: 123, node: node(), version: "1.0.0"}
      :ok = AgentStorage.put("test_id", checkpoint)

      assert :ok = AgentStorage.delete("test_id")
      assert {:error, :not_found} = AgentStorage.get("test_id")
    end

    test "succeeds for non-existent checkpoint" do
      assert :ok = AgentStorage.delete("nonexistent")
    end
  end

  describe "list/0" do
    test "returns empty list when no checkpoints" do
      assert {:ok, []} = AgentStorage.list()
    end

    test "returns all checkpoint IDs" do
      :ok = AgentStorage.put("id_1", %{data: 1, timestamp: 1, node: node(), version: "1.0.0"})
      :ok = AgentStorage.put("id_2", %{data: 2, timestamp: 2, node: node(), version: "1.0.0"})

      assert {:ok, ids} = AgentStorage.list()
      assert Enum.sort(ids) == ["id_1", "id_2"]
    end
  end

  describe "exists?/1" do
    test "returns true for existing checkpoint" do
      :ok = AgentStorage.put("test_id", %{data: "test", timestamp: 123, node: node(), version: "1.0.0"})

      assert AgentStorage.exists?("test_id")
    end

    test "returns false for non-existent checkpoint" do
      refute AgentStorage.exists?("nonexistent")
    end
  end

  describe "clear/0" do
    test "removes all checkpoints" do
      :ok = AgentStorage.put("id_1", %{data: 1, timestamp: 1, node: node(), version: "1.0.0"})
      :ok = AgentStorage.put("id_2", %{data: 2, timestamp: 2, node: node(), version: "1.0.0"})

      assert AgentStorage.count() == 2
      assert :ok = AgentStorage.clear()
      assert AgentStorage.count() == 0
    end
  end

  describe "count/0" do
    test "returns number of checkpoints" do
      assert AgentStorage.count() == 0

      :ok = AgentStorage.put("id_1", %{data: 1, timestamp: 1, node: node(), version: "1.0.0"})
      assert AgentStorage.count() == 1

      :ok = AgentStorage.put("id_2", %{data: 2, timestamp: 2, node: node(), version: "1.0.0"})
      assert AgentStorage.count() == 2
    end
  end
end
