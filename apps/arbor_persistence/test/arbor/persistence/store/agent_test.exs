defmodule Arbor.Persistence.Store.AgentTest do
  use ExUnit.Case, async: true

  alias Arbor.Persistence.Store.Agent, as: StoreAgent

  setup do
    name = :"store_agent_#{:erlang.unique_integer([:positive])}"
    start_supervised!({StoreAgent, name: name})
    {:ok, name: name}
  end

  describe "put/3 and get/2" do
    test "stores and retrieves a value", %{name: name} do
      assert :ok = StoreAgent.put("key1", "value1", name: name)
      assert {:ok, "value1"} = StoreAgent.get("key1", name: name)
    end

    test "overwrites existing value", %{name: name} do
      StoreAgent.put("key1", "v1", name: name)
      StoreAgent.put("key1", "v2", name: name)
      assert {:ok, "v2"} = StoreAgent.get("key1", name: name)
    end

    test "returns not_found for missing key", %{name: name} do
      assert {:error, :not_found} = StoreAgent.get("missing", name: name)
    end

    test "stores complex values", %{name: name} do
      value = %{nested: %{list: [1, 2, 3]}}
      StoreAgent.put("complex", value, name: name)
      assert {:ok, ^value} = StoreAgent.get("complex", name: name)
    end
  end

  describe "delete/2" do
    test "removes a key", %{name: name} do
      StoreAgent.put("key1", "value1", name: name)
      assert :ok = StoreAgent.delete("key1", name: name)
      assert {:error, :not_found} = StoreAgent.get("key1", name: name)
    end

    test "succeeds for missing key", %{name: name} do
      assert :ok = StoreAgent.delete("missing", name: name)
    end
  end

  describe "list/1" do
    test "returns all keys", %{name: name} do
      StoreAgent.put("a", 1, name: name)
      StoreAgent.put("b", 2, name: name)
      {:ok, keys} = StoreAgent.list(name: name)
      assert Enum.sort(keys) == ["a", "b"]
    end

    test "returns empty list when no data", %{name: name} do
      assert {:ok, []} = StoreAgent.list(name: name)
    end
  end

  describe "exists?/2" do
    test "returns true for existing key", %{name: name} do
      StoreAgent.put("key1", "value1", name: name)
      assert StoreAgent.exists?("key1", name: name)
    end

    test "returns false for missing key", %{name: name} do
      refute StoreAgent.exists?("missing", name: name)
    end
  end
end
