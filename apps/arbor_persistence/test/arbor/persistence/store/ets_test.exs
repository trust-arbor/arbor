defmodule Arbor.Persistence.Store.ETSTest do
  use ExUnit.Case, async: true

  alias Arbor.Persistence.Store.ETS

  setup do
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
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

  describe "capacity warning" do
    test "logs warning when approaching capacity" do
      import ExUnit.CaptureLog

      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"store_warn_#{:erlang.unique_integer([:positive])}"
      start_supervised!({ETS, name: name, max_entries: 10}, id: name)

      log =
        capture_log(fn ->
          # Insert 8 entries to trigger 80% warning
          for i <- 1..8 do
            ETS.put("key_#{i}", i, name: name)
          end
        end)

      assert log =~ "approaching capacity"
    end

    test "only warns once" do
      import ExUnit.CaptureLog

      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"store_warn_once_#{:erlang.unique_integer([:positive])}"
      start_supervised!({ETS, name: name, max_entries: 5}, id: name)

      log =
        capture_log(fn ->
          for i <- 1..5 do
            ETS.put("key_#{i}", i, name: name)
          end
        end)

      # Warning should appear exactly once
      assert length(String.split(log, "approaching capacity")) == 2
    end
  end

  describe "resource limits" do
    test "rejects new keys when store is full" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"store_limits_#{:erlang.unique_integer([:positive])}"
      start_supervised!({ETS, name: name, max_entries: 3}, id: name)

      assert :ok = ETS.put("a", 1, name: name)
      assert :ok = ETS.put("b", 2, name: name)
      assert :ok = ETS.put("c", 3, name: name)
      assert {:error, :store_full} = ETS.put("d", 4, name: name)
    end

    test "allows overwriting existing keys when full" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"store_overwrite_#{:erlang.unique_integer([:positive])}"
      start_supervised!({ETS, name: name, max_entries: 2}, id: name)

      assert :ok = ETS.put("a", 1, name: name)
      assert :ok = ETS.put("b", 2, name: name)
      # Overwrite existing key should succeed even when full
      assert :ok = ETS.put("a", 99, name: name)
      assert {:ok, 99} = ETS.get("a", name: name)
    end

    test "accepts new keys after deleting from full store" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"store_delete_#{:erlang.unique_integer([:positive])}"
      start_supervised!({ETS, name: name, max_entries: 2}, id: name)

      ETS.put("a", 1, name: name)
      ETS.put("b", 2, name: name)
      assert {:error, :store_full} = ETS.put("c", 3, name: name)

      ETS.delete("a", name: name)
      assert :ok = ETS.put("c", 3, name: name)
    end
  end
end
