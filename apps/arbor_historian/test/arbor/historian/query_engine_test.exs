defmodule Arbor.Historian.QueryEngineTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Historian.QueryEngine
  alias Arbor.Historian.TestHelpers

  setup do
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    ctx = TestHelpers.start_test_historian(:"qe_#{System.unique_integer([:positive])}")

    # Seed some signals
    signals = [
      TestHelpers.build_agent_signal("a1",
        category: :activity,
        type: :agent_started,
        correlation_id: "corr_1"
      ),
      TestHelpers.build_agent_signal("a1",
        category: :activity,
        type: :task_completed
      ),
      TestHelpers.build_signal(
        category: :security,
        type: :authorization,
        data: %{session_id: "sess_1"}
      ),
      TestHelpers.build_signal(
        category: :logs,
        type: :error,
        data: %{message: "something failed"}
      )
    ]

    for signal <- signals do
      TestHelpers.collect_signal(ctx, signal)
    end

    %{ctx: ctx}
  end

  describe "read_global/1" do
    test "returns all entries", %{ctx: ctx} do
      {:ok, entries} = QueryEngine.read_global(event_log: ctx.event_log)
      assert length(entries) == 4
    end
  end

  describe "read_agent/2" do
    test "returns entries for a specific agent", %{ctx: ctx} do
      {:ok, entries} = QueryEngine.read_agent("a1", event_log: ctx.event_log)
      assert length(entries) == 2
      assert Enum.all?(entries, &(&1.data[:agent_id] == "a1" || &1.data["agent_id"] == "a1"))
    end

    test "returns empty for unknown agent", %{ctx: ctx} do
      {:ok, entries} = QueryEngine.read_agent("nonexistent", event_log: ctx.event_log)
      assert entries == []
    end
  end

  describe "read_category/2" do
    test "returns entries for a specific category", %{ctx: ctx} do
      {:ok, entries} = QueryEngine.read_category(:security, event_log: ctx.event_log)
      assert length(entries) == 1
      assert hd(entries).category == :security
    end

    test "returns entries for activity category", %{ctx: ctx} do
      {:ok, entries} = QueryEngine.read_category(:activity, event_log: ctx.event_log)
      assert length(entries) == 2
    end
  end

  describe "read_session/2" do
    test "returns entries for a specific session", %{ctx: ctx} do
      {:ok, entries} = QueryEngine.read_session("sess_1", event_log: ctx.event_log)
      assert length(entries) == 1
    end
  end

  describe "read_correlation/2" do
    test "returns entries for a correlation chain", %{ctx: ctx} do
      {:ok, entries} = QueryEngine.read_correlation("corr_1", event_log: ctx.event_log)
      assert length(entries) == 1
    end
  end

  describe "query/1" do
    test "filters by category", %{ctx: ctx} do
      {:ok, entries} = QueryEngine.query(event_log: ctx.event_log, category: :logs)
      assert length(entries) == 1
      assert hd(entries).category == :logs
    end

    test "filters by type", %{ctx: ctx} do
      {:ok, entries} = QueryEngine.query(event_log: ctx.event_log, type: :agent_started)
      assert length(entries) == 1
      assert hd(entries).type == :agent_started
    end

    test "applies limit", %{ctx: ctx} do
      {:ok, entries} = QueryEngine.query(event_log: ctx.event_log, limit: 2)
      assert length(entries) == 2
    end

    test "combines filters", %{ctx: ctx} do
      {:ok, entries} =
        QueryEngine.query(event_log: ctx.event_log, category: :activity, type: :task_completed)

      assert length(entries) == 1
    end

    test "returns empty when no matches", %{ctx: ctx} do
      {:ok, entries} = QueryEngine.query(event_log: ctx.event_log, category: :nonexistent)
      assert entries == []
    end
  end

  describe "query edge cases" do
    test "query with no filters returns all entries", %{ctx: ctx} do
      {:ok, entries} = QueryEngine.query(event_log: ctx.event_log)
      assert length(entries) == 4
    end

    test "query with limit larger than result set returns all entries", %{ctx: ctx} do
      {:ok, entries} = QueryEngine.query(event_log: ctx.event_log, limit: 100)
      assert length(entries) == 4
    end

    test "query with limit of 1 returns exactly one entry", %{ctx: ctx} do
      {:ok, entries} = QueryEngine.query(event_log: ctx.event_log, limit: 1)
      assert length(entries) == 1
    end

    test "query with multiple filter types combined", %{ctx: ctx} do
      {:ok, entries} =
        QueryEngine.query(
          event_log: ctx.event_log,
          category: :activity,
          type: :agent_started,
          correlation_id: "corr_1"
        )

      assert length(entries) == 1
      entry = hd(entries)
      assert entry.category == :activity
      assert entry.type == :agent_started
      assert entry.correlation_id == "corr_1"
    end

    test "query with time range filters", %{ctx: ctx} do
      now = DateTime.utc_now()
      past = DateTime.add(now, -3600, :second)
      future = DateTime.add(now, 3600, :second)

      {:ok, entries} = QueryEngine.query(event_log: ctx.event_log, from: past, to: future)
      assert length(entries) == 4

      # With a very narrow window in the past, should get nothing
      very_old = DateTime.add(now, -7200, :second)
      old = DateTime.add(now, -3600, :second)
      {:ok, entries} = QueryEngine.query(event_log: ctx.event_log, from: very_old, to: old)
      assert entries == []
    end

    test "query with source filter", %{ctx: ctx} do
      {:ok, entries} =
        QueryEngine.query(event_log: ctx.event_log, source: "arbor://test/historian")

      assert length(entries) == 4
      assert Enum.all?(entries, &(&1.source == "arbor://test/historian"))
    end

    test "query with source filter no match", %{ctx: ctx} do
      {:ok, entries} =
        QueryEngine.query(event_log: ctx.event_log, source: "arbor://nonexistent")

      assert entries == []
    end
  end

  describe "read_stream/2" do
    test "returns empty list for non-existent stream", %{ctx: ctx} do
      {:ok, entries} = QueryEngine.read_stream("nonexistent_stream", event_log: ctx.event_log)
      assert entries == []
    end
  end

  describe "find_by_signal_id/2" do
    test "finds entry by original signal ID", %{ctx: ctx} do
      signal = TestHelpers.build_signal(id: "sig_findme", category: :metrics, type: :cpu)
      TestHelpers.collect_signal(ctx, signal)

      {:ok, entry} = QueryEngine.find_by_signal_id("sig_findme", event_log: ctx.event_log)
      assert entry.signal_id == "sig_findme"
    end

    test "returns not_found for unknown signal", %{ctx: ctx} do
      assert {:error, :not_found} =
               QueryEngine.find_by_signal_id("sig_unknown", event_log: ctx.event_log)
    end
  end
end
