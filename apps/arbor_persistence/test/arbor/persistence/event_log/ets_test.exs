defmodule Arbor.Persistence.EventLog.ETSTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Persistence.Event
  alias Arbor.Persistence.EventLog.ETS

  defmodule RestoreStore do
    @moduledoc false

    def get("freshness_restore:meta", _opts), do: {:ok, %{"latest_id" => "1"}}

    def get("freshness_restore:snapshot:1", _opts) do
      {:ok,
       %{
         "global_position" => 1,
         "stream_versions" => %{"restored" => 1},
         "events" => [
           %{
             "id" => "evt_restored",
             "stream_id" => "restored",
             "event_number" => 1,
             "global_position" => 1,
             "type" => "started",
             "data" => %{},
             "metadata" => %{},
             "timestamp" => "2099-01-01T00:00:00Z"
           }
         ]
       }}
    end

    def get(_key, _opts), do: {:error, :not_found}
  end

  setup do
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    name = :"el_ets_#{:erlang.unique_integer([:positive])}"
    start_supervised!({ETS, name: name})
    {:ok, name: name}
  end

  describe "append/3" do
    test "appends a single event", %{name: name} do
      event = Event.new("stream-1", "test_event", %{value: 1})
      assert {:ok, [persisted]} = ETS.append("stream-1", event, name: name)

      assert persisted.stream_id == "stream-1"
      assert persisted.event_number == 1
      assert persisted.global_position == 1
    end

    test "appends multiple events with incrementing numbers", %{name: name} do
      events = [
        Event.new("stream-1", "evt1", %{v: 1}),
        Event.new("stream-1", "evt2", %{v: 2}),
        Event.new("stream-1", "evt3", %{v: 3})
      ]

      {:ok, persisted} = ETS.append("stream-1", events, name: name)
      assert length(persisted) == 3
      numbers = Enum.map(persisted, & &1.event_number)
      assert numbers == [1, 2, 3]
    end

    test "maintains separate numbering per stream", %{name: name} do
      {:ok, [e1]} = ETS.append("s1", Event.new("s1", "t", %{}), name: name)
      {:ok, [e2]} = ETS.append("s2", Event.new("s2", "t", %{}), name: name)
      {:ok, [e3]} = ETS.append("s1", Event.new("s1", "t", %{}), name: name)

      assert e1.event_number == 1
      assert e2.event_number == 1
      assert e3.event_number == 2

      # Global positions are monotonic across streams
      assert e1.global_position == 1
      assert e2.global_position == 2
      assert e3.global_position == 3
    end

    test "security regression: expected_version is enforced atomically", %{name: name} do
      event = Event.new("cas", "created", %{})
      assert {:ok, [_]} = ETS.append("cas", event, name: name, expected_version: 0)

      assert {:error, :version_conflict} =
               ETS.append("cas", event, name: name, expected_version: 0)

      assert {:ok, 1} = ETS.stream_version("cas", name: name)
    end

    test "concurrent exact-version appends accept exactly one", %{name: name} do
      results =
        1..20
        |> Task.async_stream(
          fn i ->
            event = Event.new("cas-race", "terminal", %{winner: i})
            ETS.append("cas-race", event, name: name, expected_version: 0)
          end,
          max_concurrency: 20,
          ordered: false
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &match?({:ok, [_]}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :version_conflict})) == 19
    end

    test "freshness uses backend monotonic evidence, not caller timestamp", %{name: name} do
      future = DateTime.add(DateTime.utc_now(), 86_400, :second)
      event = Event.new("deadline", "started", %{}, timestamp: future)
      assert {:ok, [_]} = ETS.append("deadline", event, name: name)

      assert {:ok, [_]} =
               ETS.append("deadline", event,
                 name: name,
                 expected_version: 1,
                 max_current_age_ms: 60_000
               )

      # Age equal to the deadline is expired; max_current_age_ms is strict.
      assert {:error, :deadline_exceeded} =
               ETS.append("deadline", event,
                 name: name,
                 expected_version: 2,
                 max_current_age_ms: 0
               )

      assert {:ok, nil} = ETS.read_stream_head("deadline", name: name, max_current_age_ms: 0)
      assert {:ok, %Event{event_number: 2}} = ETS.read_stream_head("deadline", name: name)
    end

    test "invalid preconditions fail before append", %{name: name} do
      event = Event.new("invalid", "event", %{})

      assert {:error, :invalid_precondition} =
               ETS.append("invalid", event, name: name, expected_version: :any)

      assert {:error, :invalid_precondition} =
               ETS.append("invalid", event, name: name, max_current_age_ms: :infinity)

      assert {:error, :invalid_stream_id} =
               ETS.append(String.duplicate("s", 1_025), event, name: name)

      refute ETS.stream_exists?("invalid", name: name)
    end
  end

  describe "freshness after restore" do
    test "restart cannot extend a restored head deadline" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"el_restore_#{:erlang.unique_integer([:positive])}"

      start_supervised!(
        {ETS, name: name, snapshot_store: RestoreStore, snapshot_namespace: "freshness_restore"},
        id: name
      )

      assert {:ok, [%Event{event_number: 1}]} = ETS.read_stream("restored", name: name)

      assert {:ok, nil} =
               ETS.read_stream_head("restored", name: name, max_current_age_ms: 60_000)

      assert {:error, :deadline_exceeded} =
               ETS.append("restored", Event.new("restored", "terminal", %{}),
                 name: name,
                 expected_version: 1,
                 max_current_age_ms: 60_000
               )
    end
  end

  describe "read_stream/2" do
    test "reads all events from a stream", %{name: name} do
      events = for i <- 1..5, do: Event.new("s1", "type_#{i}", %{i: i})
      ETS.append("s1", events, name: name)

      {:ok, read} = ETS.read_stream("s1", name: name)
      assert length(read) == 5
      assert Enum.map(read, & &1.event_number) == [1, 2, 3, 4, 5]
    end

    test "reads from a specific event number", %{name: name} do
      events = for i <- 1..5, do: Event.new("s1", "type_#{i}", %{i: i})
      ETS.append("s1", events, name: name)

      {:ok, read} = ETS.read_stream("s1", name: name, from: 3)
      assert length(read) == 3
      assert hd(read).event_number == 3
    end

    test "limits results", %{name: name} do
      events = for i <- 1..5, do: Event.new("s1", "t", %{i: i})
      ETS.append("s1", events, name: name)

      {:ok, read} = ETS.read_stream("s1", name: name, limit: 2)
      assert length(read) == 2
    end

    test "reads backward", %{name: name} do
      events = for i <- 1..3, do: Event.new("s1", "t", %{i: i})
      ETS.append("s1", events, name: name)

      {:ok, read} = ETS.read_stream("s1", name: name, direction: :backward)
      numbers = Enum.map(read, & &1.event_number)
      assert numbers == [3, 2, 1]
    end

    test "security regression (max_scan): bounds how many events are walked into memory",
         %{name: name} do
      # codex resource-exhaustion.historian-taint-query-full-scan: without a
      # bound the reader collects the ENTIRE stream before applying a limit.
      # :max_scan caps the walk so an unbounded stream can't be materialized.
      events = for i <- 1..50, do: Event.new("s1", "t", %{i: i})
      ETS.append("s1", events, name: name)

      {:ok, bounded} = ETS.read_stream("s1", name: name, max_scan: 10)
      assert length(bounded) == 10, "max_scan must bound the walk to 10, got #{length(bounded)}"

      # Default (no max_scan) is unbounded — backward-compatible.
      {:ok, all} = ETS.read_stream("s1", name: name)
      assert length(all) == 50
    end

    test "returns empty for nonexistent stream", %{name: name} do
      {:ok, read} = ETS.read_stream("nonexistent", name: name)
      assert read == []
    end
  end

  describe "read_all/1" do
    test "reads all events in global order", %{name: name} do
      ETS.append("s1", Event.new("s1", "a", %{}), name: name)
      ETS.append("s2", Event.new("s2", "b", %{}), name: name)
      ETS.append("s1", Event.new("s1", "c", %{}), name: name)

      {:ok, all} = ETS.read_all(name: name)
      assert length(all) == 3
      types = Enum.map(all, & &1.type)
      assert types == ["a", "b", "c"]
    end

    test "reads from a global position", %{name: name} do
      for i <- 1..5 do
        ETS.append("s1", Event.new("s1", "t#{i}", %{}), name: name)
      end

      {:ok, all} = ETS.read_all(name: name, from: 3)
      assert length(all) == 3
      assert hd(all).global_position == 3
    end

    test "limits results", %{name: name} do
      for i <- 1..5 do
        ETS.append("s1", Event.new("s1", "t#{i}", %{}), name: name)
      end

      {:ok, all} = ETS.read_all(name: name, limit: 2)
      assert length(all) == 2
    end
  end

  describe "stream_exists?/2" do
    test "returns true for existing stream", %{name: name} do
      ETS.append("s1", Event.new("s1", "t", %{}), name: name)
      assert ETS.stream_exists?("s1", name: name)
    end

    test "returns false for nonexistent stream", %{name: name} do
      refute ETS.stream_exists?("nope", name: name)
    end
  end

  describe "stream_version/2" do
    test "returns current version", %{name: name} do
      ETS.append("s1", Event.new("s1", "t", %{}), name: name)
      ETS.append("s1", Event.new("s1", "t", %{}), name: name)
      assert {:ok, 2} = ETS.stream_version("s1", name: name)
    end

    test "returns 0 for nonexistent stream", %{name: name} do
      assert {:ok, 0} = ETS.stream_version("nope", name: name)
    end
  end

  describe "list_streams/1" do
    test "returns empty list when no streams exist", %{name: name} do
      assert {:ok, []} = ETS.list_streams(name: name)
    end

    test "returns all stream IDs", %{name: name} do
      ETS.append("stream-a", Event.new("stream-a", "t", %{}), name: name)
      ETS.append("stream-b", Event.new("stream-b", "t", %{}), name: name)
      ETS.append("stream-c", Event.new("stream-c", "t", %{}), name: name)

      {:ok, streams} = ETS.list_streams(name: name)
      assert Enum.sort(streams) == ["stream-a", "stream-b", "stream-c"]
    end
  end

  describe "stream_count/1" do
    test "returns 0 when no streams exist", %{name: name} do
      assert {:ok, 0} = ETS.stream_count(name: name)
    end

    test "returns correct count of distinct streams", %{name: name} do
      ETS.append("s1", Event.new("s1", "t", %{}), name: name)
      ETS.append("s2", Event.new("s2", "t", %{}), name: name)
      ETS.append("s1", Event.new("s1", "t", %{}), name: name)

      assert {:ok, 2} = ETS.stream_count(name: name)
    end
  end

  describe "event_count/1" do
    test "returns 0 when no events exist", %{name: name} do
      assert {:ok, 0} = ETS.event_count(name: name)
    end

    test "returns total events across all streams", %{name: name} do
      ETS.append("s1", Event.new("s1", "t", %{}), name: name)
      ETS.append("s2", Event.new("s2", "t", %{}), name: name)
      ETS.append("s1", Event.new("s1", "t", %{}), name: name)

      assert {:ok, 3} = ETS.event_count(name: name)
    end
  end

  describe "subscribe/3" do
    test "notifies subscriber of new events", %{name: name} do
      {:ok, _ref} = ETS.subscribe("s1", self(), name: name)
      ETS.append("s1", Event.new("s1", "test_type", %{v: 1}), name: name)

      assert_receive {:event, %Event{type: "test_type", stream_id: "s1"}}
    end

    test "notifies :all subscribers", %{name: name} do
      {:ok, _ref} = ETS.subscribe(:all, self(), name: name)
      ETS.append("s1", Event.new("s1", "from_s1", %{}), name: name)
      ETS.append("s2", Event.new("s2", "from_s2", %{}), name: name)

      assert_receive {:event, %Event{type: "from_s1"}}
      assert_receive {:event, %Event{type: "from_s2"}}
    end

    test "cleans up subscriber on process death", %{name: name} do
      pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      {:ok, _ref} = ETS.subscribe("s1", pid, name: name)
      send(pid, :stop)
      Process.sleep(50)

      # Should not crash when appending after subscriber died
      assert {:ok, _} = ETS.append("s1", Event.new("s1", "t", %{}), name: name)
    end
  end

  describe "resource limits" do
    test "rejects appends when event log is full" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"el_limits_#{:erlang.unique_integer([:positive])}"
      start_supervised!({ETS, name: name, max_events: 3}, id: name)

      ETS.append("s1", Event.new("s1", "t1", %{}), name: name)
      ETS.append("s1", Event.new("s1", "t2", %{}), name: name)
      ETS.append("s1", Event.new("s1", "t3", %{}), name: name)

      assert {:error, :event_log_full} =
               ETS.append("s1", Event.new("s1", "t4", %{}), name: name)
    end

    test "read_all uses default limit when none specified" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"el_read_limit_#{:erlang.unique_integer([:positive])}"
      start_supervised!({ETS, name: name}, id: name)

      for i <- 1..5 do
        ETS.append("s1", Event.new("s1", "t#{i}", %{}), name: name)
      end

      {:ok, events} = ETS.read_all(name: name)
      assert length(events) == 5
    end

    test "read_all respects explicit limit" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"el_explicit_limit_#{:erlang.unique_integer([:positive])}"
      start_supervised!({ETS, name: name}, id: name)

      for i <- 1..10 do
        ETS.append("s1", Event.new("s1", "t#{i}", %{}), name: name)
      end

      {:ok, events} = ETS.read_all(name: name, limit: 3)
      assert length(events) == 3
    end
  end

  describe "stream-table dedup invariant" do
    # PR landing 2026-06-06: stream table value type changed from full
    # %Event{} to global_position integer. The two-index storage no
    # longer doubles RAM cost. This test guards the shape so a future
    # refactor doesn't silently revert it.
    test "stream_table value is the global_position integer, not the event", %{name: name} do
      ETS.append("s1", Event.new("s1", "t1", %{v: 1}), name: name)
      ETS.append("s1", Event.new("s1", "t2", %{v: 2}), name: name)

      state = :sys.get_state(name)
      stream_entries = :ets.tab2list(state.stream_table)

      # Expect [{{"s1", 1}, 1}, {{"s1", 2}, 2}] — pointer-only, not events.
      assert length(stream_entries) == 2

      Enum.each(stream_entries, fn {{stream_id, event_number}, value} ->
        assert stream_id == "s1"
        assert is_integer(event_number)

        assert is_integer(value),
               "stream_table value must be global_position, got: #{inspect(value)}"
      end)
    end

    test "read_stream still returns full events after dedup", %{name: name} do
      e1 = Event.new("s1", "first", %{v: 1})
      e2 = Event.new("s1", "second", %{v: 2})

      ETS.append("s1", [e1, e2], name: name)
      {:ok, events} = ETS.read_stream("s1", name: name)

      assert length(events) == 2

      assert [%Event{type: "first", data: %{v: 1}}, %Event{type: "second", data: %{v: 2}}] =
               events
    end
  end

  describe "retention trim" do
    # Trim is age-based. We force trim deterministically by sending the
    # :trim_old_events message directly rather than waiting for the timer.
    test "trims events whose timestamp is older than max_age_ms" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"el_retention_#{:erlang.unique_integer([:positive])}"
      # 1-minute window; disable the periodic timer so the test drives trim
      start_supervised!(
        {ETS, name: name, max_age_ms: 60_000, trim_interval_ms: :disabled},
        id: name
      )

      old = DateTime.utc_now() |> DateTime.add(-2 * 60 * 60, :second)
      fresh = DateTime.utc_now()

      old_event =
        Event.new("s1", "old_event", %{}, timestamp: old)

      fresh_event =
        Event.new("s1", "fresh_event", %{}, timestamp: fresh)

      ETS.append("s1", [old_event, fresh_event], name: name)

      {:ok, before_trim} = ETS.read_stream("s1", name: name)
      assert length(before_trim) == 2

      # Force a trim sweep
      send(Process.whereis(name), :trim_old_events)
      # Allow the cast/info to be processed before reading.
      _ = :sys.get_state(name)

      {:ok, after_trim} = ETS.read_stream("s1", name: name)
      assert length(after_trim) == 1
      assert hd(after_trim).type == "fresh_event"
    end

    test "max_age_ms: :infinity disables trim" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"el_no_retention_#{:erlang.unique_integer([:positive])}"

      start_supervised!(
        {ETS, name: name, max_age_ms: :infinity, trim_interval_ms: :disabled},
        id: name
      )

      ancient = DateTime.utc_now() |> DateTime.add(-365 * 24 * 60 * 60, :second)
      ETS.append("s1", Event.new("s1", "ancient", %{}, timestamp: ancient), name: name)

      send(Process.whereis(name), :trim_old_events)
      _ = :sys.get_state(name)

      {:ok, events} = ETS.read_stream("s1", name: name)
      assert length(events) == 1
    end
  end

  describe "rehydrate_metadata/2" do
    # PR 2 (2026-06-06): boot doesn't replay events anymore. Instead,
    # the bookkeeping (stream_versions + global_position) is loaded
    # from the durable backend so subsequent appends use correct,
    # non-colliding values from t=0. The actual events stay in the
    # durable backend; reads for old events fall through at query time.

    test "sets stream_versions and global_position without inserting events", %{name: name} do
      snapshot = %{
        stream_versions: %{"s1" => 100, "s2" => 50},
        global_position: 150
      }

      assert :ok = ETS.rehydrate_metadata(snapshot, name: name)

      assert {:ok, 100} = ETS.stream_version("s1", name: name)
      assert {:ok, 50} = ETS.stream_version("s2", name: name)
      assert {:ok, 150} = ETS.event_count(name: name)

      # No events were actually inserted — read returns empty
      assert {:ok, []} = ETS.read_stream("s1", name: name)
    end

    test "next append after rehydrate uses the rehydrated counter", %{name: name} do
      snapshot = %{stream_versions: %{"s1" => 100}, global_position: 100}
      :ok = ETS.rehydrate_metadata(snapshot, name: name)

      # Next append should be event_number 101, global_position 101
      assert {:ok, [persisted]} =
               ETS.append("s1", Event.new("s1", "next", %{}), name: name)

      assert persisted.event_number == 101
      assert persisted.global_position == 101
    end

    test "idempotent — merges via max for streams, max for global_position", %{name: name} do
      first = %{stream_versions: %{"s1" => 100, "s2" => 200}, global_position: 200}
      second = %{stream_versions: %{"s1" => 50, "s3" => 300}, global_position: 100}

      :ok = ETS.rehydrate_metadata(first, name: name)
      :ok = ETS.rehydrate_metadata(second, name: name)

      # s1: max(100, 50) = 100
      assert {:ok, 100} = ETS.stream_version("s1", name: name)
      # s2: still 200 (not in second)
      assert {:ok, 200} = ETS.stream_version("s2", name: name)
      # s3: 300 (new from second)
      assert {:ok, 300} = ETS.stream_version("s3", name: name)
      # global_position: max(200, 100) = 200
      assert {:ok, 200} = ETS.event_count(name: name)
    end

    test "doesn't clobber existing live appends", %{name: name} do
      # Write a real event first
      {:ok, [_]} = ETS.append("s1", Event.new("s1", "live", %{}), name: name)
      # Now rehydrate with a SMALLER counter (e.g., stale snapshot)
      snapshot = %{stream_versions: %{"s1" => 0}, global_position: 0}
      :ok = ETS.rehydrate_metadata(snapshot, name: name)

      # The real event's counter should win
      assert {:ok, 1} = ETS.stream_version("s1", name: name)
      assert {:ok, 1} = ETS.event_count(name: name)
    end
  end

  describe "oldest_event_number/2" do
    test "returns nil for streams with no events in cache", %{name: name} do
      assert {:ok, nil} = ETS.oldest_event_number("never_existed", name: name)
    end

    test "returns 1 immediately after the first append", %{name: name} do
      ETS.append("s1", Event.new("s1", "t", %{}), name: name)
      assert {:ok, 1} = ETS.oldest_event_number("s1", name: name)
    end

    test "advances after retention trims older events" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"el_oldest_#{:erlang.unique_integer([:positive])}"

      start_supervised!(
        {ETS, name: name, max_age_ms: 60_000, trim_interval_ms: :disabled},
        id: name
      )

      old = DateTime.utc_now() |> DateTime.add(-2 * 60 * 60, :second)
      fresh = DateTime.utc_now()

      ETS.append("s1", Event.new("s1", "e1", %{}, timestamp: old), name: name)
      ETS.append("s1", Event.new("s1", "e2", %{}, timestamp: old), name: name)
      ETS.append("s1", Event.new("s1", "e3", %{}, timestamp: fresh), name: name)

      assert {:ok, 1} = ETS.oldest_event_number("s1", name: name)

      send(Process.whereis(name), :trim_old_events)
      _ = :sys.get_state(name)

      # First two events were trimmed, so oldest is now event_number 3.
      assert {:ok, 3} = ETS.oldest_event_number("s1", name: name)
    end
  end
end
