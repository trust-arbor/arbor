defmodule Arbor.Checkpoint.Store.ETSTest do
  use ExUnit.Case, async: false

  alias Arbor.Checkpoint.Store.ETS

  import Arbor.Checkpoint.TestHelpers, only: [safe_stop: 1]

  @moduletag :fast

  setup do
    {:ok, pid} = ETS.start_link()
    on_exit(fn -> safe_stop(pid) end)
    {:ok, pid: pid}
  end

  describe "put/3" do
    test "stores checkpoint" do
      checkpoint = %{data: %{counter: 42}, timestamp: 123, node: node(), version: "1.0.0"}

      assert :ok = ETS.put("test_id", checkpoint)
      assert {:ok, ^checkpoint} = ETS.get("test_id")
    end

    test "overwrites existing checkpoint" do
      checkpoint1 = %{data: %{v: 1}, timestamp: 1, node: node(), version: "1.0.0"}
      checkpoint2 = %{data: %{v: 2}, timestamp: 2, node: node(), version: "1.0.0"}

      :ok = ETS.put("test_id", checkpoint1)
      :ok = ETS.put("test_id", checkpoint2)

      assert {:ok, ^checkpoint2} = ETS.get("test_id")
    end
  end

  describe "get/2" do
    test "retrieves existing checkpoint" do
      checkpoint = %{data: "test", timestamp: 123, node: node(), version: "1.0.0"}
      :ok = ETS.put("test_id", checkpoint)

      assert {:ok, ^checkpoint} = ETS.get("test_id")
    end

    test "returns error for non-existent checkpoint" do
      assert {:error, :not_found} = ETS.get("nonexistent")
    end
  end

  describe "delete/2" do
    test "removes checkpoint" do
      checkpoint = %{data: "test", timestamp: 123, node: node(), version: "1.0.0"}
      :ok = ETS.put("test_id", checkpoint)

      assert :ok = ETS.delete("test_id")
      assert {:error, :not_found} = ETS.get("test_id")
    end

    test "succeeds for non-existent checkpoint" do
      assert :ok = ETS.delete("nonexistent")
    end
  end

  describe "list/1" do
    test "returns empty list when no checkpoints" do
      assert {:ok, []} = ETS.list()
    end

    test "returns all checkpoint IDs" do
      :ok = ETS.put("id_1", %{data: 1, timestamp: 1, node: node(), version: "1.0.0"})
      :ok = ETS.put("id_2", %{data: 2, timestamp: 2, node: node(), version: "1.0.0"})

      assert {:ok, ids} = ETS.list()
      assert Enum.sort(ids) == ["id_1", "id_2"]
    end
  end

  describe "exists?/2" do
    test "returns true for existing checkpoint" do
      :ok = ETS.put("test_id", %{data: "test", timestamp: 123, node: node(), version: "1.0.0"})

      assert ETS.exists?("test_id")
    end

    test "returns false for non-existent checkpoint" do
      refute ETS.exists?("nonexistent")
    end
  end

  describe "clear/0" do
    test "removes all checkpoints" do
      :ok = ETS.put("id_1", %{data: 1, timestamp: 1, node: node(), version: "1.0.0"})
      :ok = ETS.put("id_2", %{data: 2, timestamp: 2, node: node(), version: "1.0.0"})

      assert ETS.count() == 2
      assert :ok = ETS.clear()
      assert ETS.count() == 0
    end
  end

  describe "count/0" do
    test "returns number of checkpoints" do
      assert ETS.count() == 0

      :ok = ETS.put("id_1", %{data: 1, timestamp: 1, node: node(), version: "1.0.0"})
      assert ETS.count() == 1

      :ok = ETS.put("id_2", %{data: 2, timestamp: 2, node: node(), version: "1.0.0"})
      assert ETS.count() == 2
    end
  end
end
