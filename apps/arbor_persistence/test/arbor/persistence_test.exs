defmodule Arbor.PersistenceTest do
  use ExUnit.Case, async: true

  alias Arbor.Persistence
  alias Arbor.Persistence.{Event, Filter, Record}
  alias Arbor.Persistence.EventLog
  alias Arbor.Persistence.QueryableStore
  alias Arbor.Persistence.Store

  describe "Store facade" do
    setup do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"facade_store_#{:erlang.unique_integer([:positive])}"
      start_supervised!({Store.ETS, name: name})
      {:ok, name: name, backend: Store.ETS}
    end

    test "put/get/delete/list/exists?", %{name: name, backend: backend} do
      assert :ok = Persistence.put(name, backend, "k1", "v1")
      assert {:ok, "v1"} = Persistence.get(name, backend, "k1")
      assert Persistence.exists?(name, backend, "k1")
      assert {:ok, ["k1"]} = Persistence.list(name, backend)
      assert :ok = Persistence.delete(name, backend, "k1")
      assert {:error, :not_found} = Persistence.get(name, backend, "k1")
    end
  end

  describe "QueryableStore facade" do
    setup do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"facade_qs_#{:erlang.unique_integer([:positive])}"
      start_supervised!({QueryableStore.ETS, name: name})
      {:ok, name: name, backend: QueryableStore.ETS}
    end

    test "put/query/count", %{name: name, backend: backend} do
      r1 = Record.new("a", %{type: "x"})
      r2 = Record.new("b", %{type: "y"})

      Persistence.put(name, backend, "a", r1)
      Persistence.put(name, backend, "b", r2)

      filter = Filter.new() |> Filter.where(:key, :eq, "a")
      {:ok, results} = Persistence.query(name, backend, filter)
      assert length(results) == 1

      {:ok, count} = Persistence.count(name, backend, Filter.new())
      assert count == 2
    end

    test "aggregate", %{name: name, backend: backend} do
      for {key, val} <- [{"a", 10}, {"b", 20}] do
        record = Record.new(key, %{}) |> Map.put(:score, val)
        Persistence.put(name, backend, key, record)
      end

      {:ok, sum} = Persistence.aggregate(name, backend, Filter.new(), :score, :sum)
      assert sum == 30
    end
  end

  describe "EventLog facade" do
    setup do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"facade_el_#{:erlang.unique_integer([:positive])}"
      start_supervised!({EventLog.ETS, name: name})
      {:ok, name: name, backend: EventLog.ETS}
    end

    test "append/read_stream/read_all", %{name: name, backend: backend} do
      event = Event.new("s1", "test_type", %{v: 1})
      {:ok, [persisted]} = Persistence.append(name, backend, "s1", event)
      assert persisted.event_number == 1

      {:ok, stream} = Persistence.read_stream(name, backend, "s1")
      assert length(stream) == 1

      {:ok, all} = Persistence.read_all(name, backend)
      assert length(all) == 1
    end

    test "stream_exists?/stream_version", %{name: name, backend: backend} do
      refute Persistence.stream_exists?(name, backend, "s1")
      Persistence.append(name, backend, "s1", Event.new("s1", "t", %{}))
      assert Persistence.stream_exists?(name, backend, "s1")
      assert {:ok, 1} = Persistence.stream_version(name, backend, "s1")
    end

    test "list_streams/stream_count/event_count", %{name: name, backend: backend} do
      Persistence.append(name, backend, "s1", Event.new("s1", "t", %{}))
      Persistence.append(name, backend, "s2", Event.new("s2", "t", %{}))

      {:ok, streams} = Persistence.list_streams(name, backend)
      assert "s1" in streams
      assert "s2" in streams

      {:ok, count} = Persistence.stream_count(name, backend)
      assert count == 2

      {:ok, events} = Persistence.event_count(name, backend)
      assert events == 2
    end
  end

  describe "error paths with failing backends" do
    alias Arbor.Persistence.TestBackends.FailingEventLog
    alias Arbor.Persistence.TestBackends.FailingStore

    test "failing store returns errors" do
      assert {:error, :write_failed} = Persistence.put(:x, FailingStore, "k", "v")
      assert {:error, :read_failed} = Persistence.get(:x, FailingStore, "k")
      assert {:error, :delete_failed} = Persistence.delete(:x, FailingStore, "k")
      assert {:error, :list_failed} = Persistence.list(:x, FailingStore)
    end

    test "failing event log returns errors" do
      event = Event.new("s1", "t", %{})
      assert {:error, :append_failed} = Persistence.append(:x, FailingEventLog, "s1", event)
      assert {:error, :read_failed} = Persistence.read_stream(:x, FailingEventLog, "s1")
      assert {:error, :read_failed} = Persistence.read_all(:x, FailingEventLog)
    end
  end
end
