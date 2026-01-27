defmodule Arbor.Persistence.Store.ETSTest do
  use ExUnit.Case, async: true

  alias Arbor.Persistence.Store.ETS

  setup do
    name = :"store_ets_#{:erlang.unique_integer([:positive])}"
    start_supervised!({ETS, name: name})
    {:ok, name: name}
  end

  describe "put/3 and get/2" do
    test "stores and retrieves a value", %{name: name} do
      assert :ok = ETS.put("key1", "value1", name: name)
      assert {:ok, "value1"} = ETS.get("key1", name: name)
    end

    test "overwrites existing value", %{name: name} do
      ETS.put("key1", "v1", name: name)
      ETS.put("key1", "v2", name: name)
      assert {:ok, "v2"} = ETS.get("key1", name: name)
    end

    test "returns not_found for missing key", %{name: name} do
      assert {:error, :not_found} = ETS.get("missing", name: name)
    end

    test "stores complex values", %{name: name} do
      value = %{nested: %{list: [1, 2, 3]}, tuple: {:ok, true}}
      ETS.put("complex", value, name: name)
      assert {:ok, ^value} = ETS.get("complex", name: name)
    end
  end

  describe "delete/2" do
    test "removes a key", %{name: name} do
      ETS.put("key1", "value1", name: name)
      assert :ok = ETS.delete("key1", name: name)
      assert {:error, :not_found} = ETS.get("key1", name: name)
    end

    test "succeeds for missing key", %{name: name} do
      assert :ok = ETS.delete("missing", name: name)
    end
  end

  describe "list/1" do
    test "returns all keys", %{name: name} do
      ETS.put("a", 1, name: name)
      ETS.put("b", 2, name: name)
      ETS.put("c", 3, name: name)

      {:ok, keys} = ETS.list(name: name)
      assert Enum.sort(keys) == ["a", "b", "c"]
    end

    test "returns empty list when no data", %{name: name} do
      assert {:ok, []} = ETS.list(name: name)
    end
  end

  describe "exists?/2" do
    test "returns true for existing key", %{name: name} do
      ETS.put("key1", "value1", name: name)
      assert ETS.exists?("key1", name: name)
    end

    test "returns false for missing key", %{name: name} do
      refute ETS.exists?("missing", name: name)
    end
  end
end
