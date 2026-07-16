defmodule Arbor.Persistence.EventLog.ETSTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Persistence.Event
  alias Arbor.Persistence.EventLog.ETS
  alias Arbor.Persistence.EventLog.Snapshotter

  defmodule SnapshotStore do
    @moduledoc false

    use Agent

    def start_link(opts), do: Agent.start_link(fn -> %{} end, name: Keyword.fetch!(opts, :name))

    def put(key, value, opts) do
      Agent.update(Keyword.fetch!(opts, :name), &Map.put(&1, key, value))
    end

    def get(key, opts) do
      case Agent.get(Keyword.fetch!(opts, :name), &Map.fetch(&1, key)) do
        {:ok, value} -> {:ok, value}
        :error -> {:error, :not_found}
      end
    end

    def delete(key, opts) do
      Agent.update(Keyword.fetch!(opts, :name), &Map.delete(&1, key))
    end
  end

  defmodule RestoreStore do
    @moduledoc false

    def get("freshness_restore:meta", _opts), do: {:ok, %{"latest_id" => "1"}}

    def get("freshness_restore:snapshot:1", _opts) do
      timestamp = DateTime.from_iso8601("2099-01-01T00:00:00Z") |> elem(1)

      event = %Arbor.Persistence.Event{
        id: "evt_restored",
        stream_id: "restored",
        event_number: 1,
        global_position: 1,
        type: "started",
        data: %{},
        metadata: %{},
        timestamp: timestamp
      }

      fingerprint = Arbor.Persistence.EventLog.event_fingerprint("restored", event)

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
             "timestamp" => "2099-01-01T00:00:00Z",
             "operation_fingerprint" => fingerprint
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

    assert {:ok, :identity_history_complete} =
             ETS.rehydrate_metadata(%{stream_versions: %{}, global_position: 0}, name: name)

    {:ok, name: name}
  end

  test "security regression: a new store rejects append and reconcile until initialized" do
    name = :"el_incomplete_start_#{:erlang.unique_integer([:positive])}"
    start_supervised!({ETS, name: name, identity_history: :incomplete}, id: name)

    event = Event.new("incomplete", "arbor.review.ordinary", %{value: 1})
    assert {:ok, operation} = Arbor.Persistence.EventLog.build_operation("incomplete", [event])

    assert {:ok,
            {:identity_history_unavailable,
             %{reason: :startup_incomplete, expected_events: 0, loaded_events: 0}}} =
             ETS.identity_history_status(name: name)

    assert {:error, {:append_indeterminate, ^operation}} =
             ETS.append("incomplete", event, name: name)

    assert {:error, {:append_indeterminate, ^operation}} =
             ETS.reconcile_append(operation, name: name)

    assert {:ok, :identity_history_complete} =
             ETS.rehydrate_metadata(%{stream_versions: %{}, global_position: 0}, name: name)

    assert {:ok, [%Event{event_number: 1, global_position: 1}]} =
             ETS.append("incomplete", event, name: name)
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
               ETS.append("cas", Event.new("cas", "duplicate", %{}),
                 name: name,
                 expected_version: 0
               )

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
               ETS.append("deadline", Event.new("deadline", "continued", %{}, timestamp: future),
                 name: name,
                 expected_version: 1,
                 max_current_age_ms: 60_000
               )

      # Age equal to the deadline is expired; max_current_age_ms is strict.
      assert {:error, :deadline_exceeded} =
               ETS.append("deadline", Event.new("deadline", "expired", %{}, timestamp: future),
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

    test "security regression: a suspended queued append expires without later mutation", %{
      name: name
    } do
      event = Event.new("queued-timeout", "must-not-commit", %{})
      :ok = :sys.suspend(name)

      task =
        Task.async(fn ->
          ETS.append("queued-timeout", event,
            name: name,
            expected_version: 0,
            append_timeout_ms: 25
          )
        end)

      result =
        try do
          Task.await(task, 1_000)
        after
          :ok = :sys.resume(name)
        end

      assert {:error, {:append_indeterminate, operation}} = result

      assert {:ok, 0} = ETS.stream_version("queued-timeout", name: name)
      refute ETS.stream_exists?("queued-timeout", name: name)
      assert {:ok, :absent} = ETS.reconcile_append(operation, name: name)
    end

    test "forged operations and improper reconcile options cannot crash the ETS owner", %{
      name: name
    } do
      event = Event.new("forged", "created", %{value: 1})

      assert {:ok, operation} =
               Arbor.Persistence.EventLog.build_operation("forged", [event])

      Enum.each(forged_operations(operation), fn forged ->
        assert {:error, :invalid_append_operation} = ETS.reconcile_append(forged, name: name)
      end)

      assert {:error, :invalid_precondition} =
               ETS.reconcile_append(operation, [{:name, name} | :improper])

      assert Process.alive?(Process.whereis(name))
    end

    test "same exact append is idempotent and changed content under one ID conflicts", %{
      name: name
    } do
      event = Event.new("idempotent", "created", %{value: 1})
      assert {:ok, [first]} = ETS.append("idempotent", event, name: name)
      assert {:ok, [retried]} = ETS.append("idempotent", event, name: name)
      assert retried == first

      changed = %Event{event | data: %{value: 2}}
      assert {:error, :event_identity_conflict} = ETS.append("idempotent", changed, name: name)
      assert {:ok, 1} = ETS.stream_version("idempotent", name: name)
    end

    test "append, retry, and read return one canonical JSON representation", %{name: name} do
      event =
        Event.new("canonical", "arbor.review.ordinary", %{outer: %{value: 1}},
          metadata: %{source: "ets"}
        )

      expected_data = %{"outer" => %{"value" => 1}}
      expected_metadata = %{"source" => "ets"}

      assert {:ok, [first]} = ETS.append("canonical", event, name: name)
      assert first.data == expected_data
      assert first.metadata == expected_metadata

      assert {:ok, [retried]} = ETS.append("canonical", event, name: name)
      assert retried == first

      assert {:ok, [read]} = ETS.read_stream("canonical", name: name)
      assert read == first
    end

    test "security regression: an expired ETS candidate cannot commit" do
      parent = self()
      name = :"el_ets_delayed_candidate_#{:erlang.unique_integer([:positive])}"

      start_supervised!(
        {ETS,
         name: name,
         append_candidate_hook: fn ->
           send(parent, :ets_candidate_built)
           Process.sleep(35)
         end},
        id: name
      )

      initialize_empty_store(name)

      event = Event.new("ets-post-decision-timeout", "must-not-commit", %{})

      assert {:error, {:append_indeterminate, _operation}} =
               ETS.append("ets-post-decision-timeout", event,
                 name: name,
                 append_timeout_ms: 10
               )

      assert_receive :ets_candidate_built
      assert {:ok, 0} = ETS.stream_version("ets-post-decision-timeout", name: name)
      refute ETS.stream_exists?("ets-post-decision-timeout", name: name)
    end

    test "malformed public names are rejected without raising" do
      event = Event.new("invalid-name", "event", %{})

      for invalid_name <- [%{not: :a_server}, nil] do
        assert {:error, :invalid_precondition} =
                 ETS.append("invalid-name", event, name: invalid_name)
      end
    end

    test "position exhaustion returns controlled errors before mutation", %{name: name} do
      :sys.replace_state(name, fn state ->
        %{state | stream_versions: %{"full-stream" => 2_147_483_647}}
      end)

      assert {:error, :stream_position_exhausted} =
               ETS.append("full-stream", Event.new("full-stream", "event", %{}), name: name)

      :sys.replace_state(name, fn state ->
        %{
          state
          | stream_versions: %{},
            global_position: 2_147_483_647,
            max_events: 2_147_483_648
        }
      end)

      assert {:error, :global_position_exhausted} =
               ETS.append("global-full", Event.new("global-full", "event", %{}), name: name)
    end
  end

  defp forged_operations(operation) do
    oversized_ids = Enum.map(1..1_001, &"evt_forged_#{&1}")

    [
      rebuild_operation(operation, event_ids: ["evt_forged" | :improper]),
      rebuild_operation(operation, event_ids: oversized_ids, fingerprints: %{})
    ]
  end

  defp rebuild_operation(operation, attrs) do
    operation.__struct__
    |> struct(Map.merge(Map.from_struct(operation), Map.new(attrs)))
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

    test "security regression: rehydrating a newer durable head clears local freshness", %{
      name: name
    } do
      stream_id = "rehydrated-head"
      event = Event.new(stream_id, "local", %{})

      assert {:ok, [%Event{event_number: 1}]} = ETS.append(stream_id, event, name: name)

      assert {:ok,
              {:identity_history_unavailable,
               %{expected_events: 2, loaded_events: 1, reason: :durable_metadata_only}}} =
               ETS.rehydrate_metadata(
                 %{stream_versions: %{stream_id => 2}, global_position: 2},
                 name: name
               )

      assert {:error, :head_unavailable} =
               ETS.read_stream_head(stream_id, name: name, max_current_age_ms: 60_000)

      assert {:error, :head_unavailable} = ETS.read_stream_head(stream_id, name: name)

      assert {:error, {:append_indeterminate, _operation}} =
               ETS.append(stream_id, Event.new(stream_id, "must-not-commit", %{}),
                 name: name,
                 expected_version: 2,
                 max_current_age_ms: 60_000
               )

      assert {:ok, 2} = ETS.stream_version(stream_id, name: name)
      assert {:ok, [%Event{event_number: 1}]} = ETS.read_stream(stream_id, name: name)
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
      initialize_empty_store(name)

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
      initialize_empty_store(name)

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
      initialize_empty_store(name)

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

      assert [
               %Event{type: "first", data: %{"v" => 1}},
               %Event{type: "second", data: %{"v" => 2}}
             ] =
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

      initialize_empty_store(name)

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

    test "security regression: retrying a trimmed event cannot duplicate its identity" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"el_trim_identity_#{:erlang.unique_integer([:positive])}"

      start_supervised!(
        {ETS, name: name, max_age_ms: 60_000, trim_interval_ms: :disabled},
        id: name
      )

      initialize_empty_store(name)

      old = DateTime.utc_now() |> DateTime.add(-2 * 60 * 60, :second)
      event = Event.new("trimmed-id", "old_event", %{value: 1}, timestamp: old)

      assert {:ok, [_persisted]} = ETS.append("trimmed-id", event, name: name)

      send(Process.whereis(name), :trim_old_events)
      _ = :sys.get_state(name)

      assert {:ok, []} = ETS.read_stream("trimmed-id", name: name)

      assert {:ok, [%Event{event_number: 1, global_position: 1}]} =
               ETS.append("trimmed-id", event, name: name)

      assert {:ok, 1} = ETS.stream_version("trimmed-id", name: name)
      assert {:ok, []} = ETS.read_stream("trimmed-id", name: name)
    end

    test "security regression: snapshot recovery preserves trimmed identity tombstones" do
      suffix = System.unique_integer([:positive])
      name = :"el_trim_snapshot_#{suffix}"
      store_name = :"el_trim_snapshot_store_#{suffix}"
      snapshotter_name = :"el_trim_snapshotter_#{suffix}"
      namespace = "trimmed_identity_#{suffix}"

      start_supervised!({SnapshotStore, name: store_name}, id: store_name)

      start_supervised!(
        {ETS, name: name, max_age_ms: 60_000, trim_interval_ms: :disabled},
        id: name
      )

      initialize_empty_store(name)

      start_supervised!(
        {Snapshotter,
         name: snapshotter_name,
         event_log_name: name,
         store: SnapshotStore,
         store_opts: [name: store_name],
         namespace: namespace,
         interval_ms: 60_000},
        id: snapshotter_name
      )

      old = DateTime.utc_now() |> DateTime.add(-2 * 60 * 60, :second)

      event =
        Event.new("snapshot-trimmed-id", "old_event", %{value: 1},
          id: "evt_snapshot_trimmed_identity",
          timestamp: old
        )

      assert {:ok, [%Event{event_number: 1, global_position: 1}]} =
               ETS.append("snapshot-trimmed-id", event, name: name)

      send(Process.whereis(name), :trim_old_events)
      _ = :sys.get_state(name)
      assert {:ok, []} = ETS.read_stream("snapshot-trimmed-id", name: name)
      assert :ok = Snapshotter.snapshot_now(snapshotter_name)

      stop_supervised(snapshotter_name)
      stop_supervised(name)

      start_supervised!(
        {ETS,
         name: name,
         max_age_ms: 60_000,
         trim_interval_ms: :disabled,
         snapshot_store: SnapshotStore,
         snapshot_store_opts: [name: store_name],
         snapshot_namespace: namespace},
        id: name
      )

      assert {:ok, [%Event{event_number: 1, global_position: 1}]} =
               ETS.append("snapshot-trimmed-id", event, name: name)

      conflicting = %Event{event | data: %{value: 2}}

      assert {:error, :event_identity_conflict} =
               ETS.append("snapshot-trimmed-id", conflicting, name: name)

      assert {:ok, 1} = ETS.stream_version("snapshot-trimmed-id", name: name)
      assert {:ok, []} = ETS.read_stream("snapshot-trimmed-id", name: name)
    end

    test "max_age_ms: :infinity disables trim" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"el_no_retention_#{:erlang.unique_integer([:positive])}"

      start_supervised!(
        {ETS, name: name, max_age_ms: :infinity, trim_interval_ms: :disabled},
        id: name
      )

      initialize_empty_store(name)

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

      assert {:ok,
              {:identity_history_unavailable,
               %{expected_events: 150, loaded_events: 0, reason: :durable_metadata_only}}} =
               ETS.rehydrate_metadata(snapshot, name: name)

      assert {:ok, 100} = ETS.stream_version("s1", name: name)
      assert {:ok, 50} = ETS.stream_version("s2", name: name)
      assert {:ok, 150} = ETS.event_count(name: name)

      # No events were actually inserted — read returns empty
      assert {:ok, []} = ETS.read_stream("s1", name: name)
      assert {:error, :head_unavailable} = ETS.read_stream_head("s1", name: name)
    end

    test "next append waits for identity replay instead of assuming an ID is absent", %{
      name: name
    } do
      snapshot = %{stream_versions: %{"s1" => 100}, global_position: 100}

      assert {:ok, {:identity_history_unavailable, _details}} =
               ETS.rehydrate_metadata(snapshot, name: name)

      assert {:error, {:append_indeterminate, _operation}} =
               ETS.append("s1", Event.new("s1", "next", %{}), name: name)
    end

    test "idempotent — merges via max for streams, max for global_position", %{name: name} do
      first = %{stream_versions: %{"s1" => 100, "s2" => 200}, global_position: 200}
      second = %{stream_versions: %{"s1" => 50, "s3" => 300}, global_position: 100}

      assert {:ok, {:identity_history_unavailable, %{reason: :metadata_sequence_inconsistent}}} =
               ETS.rehydrate_metadata(first, name: name)

      assert {:ok, {:identity_history_unavailable, %{reason: :metadata_sequence_inconsistent}}} =
               ETS.rehydrate_metadata(second, name: name)

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

      assert {:ok, :identity_history_complete} =
               ETS.rehydrate_metadata(snapshot, name: name)

      # The real event's counter should win
      assert {:ok, 1} = ETS.stream_version("s1", name: name)
      assert {:ok, 1} = ETS.event_count(name: name)
    end

    test "security regression: a v2 snapshot with unavailable durable identity history restarts" do
      suffix = System.unique_integer([:positive])
      name = :"el_metadata_snapshot_#{suffix}"
      store_name = :"el_metadata_snapshot_store_#{suffix}"
      snapshotter_name = :"el_metadata_snapshotter_#{suffix}"
      namespace = "metadata_snapshot_#{suffix}"

      start_supervised!({SnapshotStore, name: store_name}, id: store_name)
      start_supervised!({ETS, name: name}, id: name)

      assert {:ok, {:identity_history_unavailable, _details}} =
               ETS.rehydrate_metadata(
                 %{stream_versions: %{"durable" => 2}, global_position: 2},
                 name: name
               )

      start_supervised!(
        {Snapshotter,
         name: snapshotter_name,
         event_log_name: name,
         store: SnapshotStore,
         store_opts: [name: store_name],
         namespace: namespace,
         interval_ms: 60_000},
        id: snapshotter_name
      )

      assert :ok = Snapshotter.snapshot_now(snapshotter_name)
      stop_supervised(snapshotter_name)
      stop_supervised(name)

      start_supervised!(
        {ETS,
         name: name,
         snapshot_store: SnapshotStore,
         snapshot_store_opts: [name: store_name],
         snapshot_namespace: namespace},
        id: name
      )

      assert {:ok,
              {:identity_history_unavailable,
               %{expected_events: 2, loaded_events: 0, reason: :durable_metadata_only}}} =
               apply(ETS, :identity_history_status, [[name: name]])
    end

    test "security regression: an incomplete R2 snapshot restarts with explicit remediation" do
      suffix = System.unique_integer([:positive])
      name = :"el_legacy_incomplete_snapshot_#{suffix}"
      store_name = :"el_legacy_incomplete_store_#{suffix}"
      namespace = "legacy_incomplete_#{suffix}"

      start_supervised!({SnapshotStore, name: store_name}, id: store_name)

      assert :ok =
               SnapshotStore.put(
                 "#{namespace}:meta",
                 %{"latest_id" => "1"},
                 name: store_name
               )

      assert :ok =
               SnapshotStore.put(
                 "#{namespace}:snapshot:1",
                 %{
                   "snapshot_version" => 2,
                   "global_position" => 2,
                   "stream_versions" => %{"legacy" => 2},
                   "events" => [],
                   "identity_tombstones" => []
                 },
                 name: store_name
               )

      start_supervised!(
        {ETS,
         name: name,
         snapshot_store: SnapshotStore,
         snapshot_store_opts: [name: store_name],
         snapshot_namespace: namespace},
        id: name
      )

      assert {:ok,
              {:identity_history_unavailable,
               %{expected_events: 2, loaded_events: 0, reason: :legacy_snapshot_incomplete}}} =
               apply(ETS, :identity_history_status, [[name: name]])
    end

    test "malformed durable snapshot restarts fail closed and can be replay-remediated" do
      suffix = System.unique_integer([:positive])
      name = :"el_malformed_snapshot_#{suffix}"
      store_name = :"el_malformed_store_#{suffix}"
      namespace = "malformed_snapshot_#{suffix}"

      start_supervised!({SnapshotStore, name: store_name}, id: store_name)

      assert :ok =
               SnapshotStore.put(
                 "#{namespace}:meta",
                 %{"latest_id" => "1"},
                 name: store_name
               )

      assert :ok =
               SnapshotStore.put(
                 "#{namespace}:snapshot:1",
                 %{
                   "snapshot_version" => 2,
                   "global_position" => 1,
                   "stream_versions" => %{"recovered" => 1},
                   "events" => :not_a_list,
                   "identity_tombstones" => []
                 },
                 name: store_name
               )

      start_supervised!(
        {ETS,
         name: name,
         snapshot_store: SnapshotStore,
         snapshot_store_opts: [name: store_name],
         snapshot_namespace: namespace},
        id: name
      )

      assert {:ok,
              {:identity_history_unavailable,
               %{expected_events: 0, loaded_events: 0, reason: :snapshot_restore_failed}}} =
               apply(ETS, :identity_history_status, [[name: name]])

      recovered =
        %Event{
          Event.new("recovered", "arbor.review.ordinary", %{value: 1}, id: "evt_recovered")
          | event_number: 1,
            global_position: 1
        }
        |> with_durable_fingerprint()

      assert {:ok, {:identity_history_unavailable, _details}} =
               ETS.rehydrate_metadata(
                 %{stream_versions: %{"recovered" => 1}, global_position: 1},
                 name: name
               )

      assert {:ok, %{remaining: 0, status: :identity_history_complete}} =
               apply(ETS, :replay_identity_history, [
                 [recovered],
                 [name: name, complete: true]
               ])
    end

    test "security regression: unavailable identity history has a bounded replay path", %{
      name: name
    } do
      first =
        %Event{
          Event.new("replayed", "arbor.review.ordinary", %{value: 1}, id: "evt_replay_1")
          | event_number: 1,
            global_position: 1
        }
        |> with_durable_fingerprint()

      second =
        %Event{
          Event.new("replayed", "arbor.review.ordinary", %{value: 2}, id: "evt_replay_2")
          | event_number: 2,
            global_position: 2
        }
        |> with_durable_fingerprint()

      assert {:ok, {:identity_history_unavailable, _details}} =
               ETS.rehydrate_metadata(
                 %{stream_versions: %{"replayed" => 2}, global_position: 2},
                 name: name
               )

      assert {:ok, %{accepted: 1, remaining: 1, status: {:identity_history_unavailable, _}}} =
               apply(ETS, :replay_identity_history, [[first], [name: name]])

      assert {:ok, %{accepted: 1, remaining: 0, status: :identity_history_complete}} =
               apply(ETS, :replay_identity_history, [
                 [second],
                 [name: name, complete: true]
               ])

      assert {:ok, [%Event{event_number: 3, global_position: 3}]} =
               ETS.append(
                 "replayed",
                 Event.new("replayed", "arbor.review.ordinary", %{value: 3}),
                 name: name
               )
    end

    test "security regression: an unavailable snapshot rejects all append reconciliation", %{
      name: source_name
    } do
      event = Event.new("replay-blocked", "arbor.review.ordinary", %{value: 1})

      assert {:ok, operation} =
               Arbor.Persistence.EventLog.build_operation(event.stream_id, [event])

      fingerprint = Map.fetch!(operation.fingerprints, event.id)
      timestamp = DateTime.to_iso8601(event.timestamp)

      suffix = System.unique_integer([:positive])
      store_name = :"el_replay_blocked_store_#{suffix}"
      target_name = :"el_replay_blocked_target_#{suffix}"
      namespace = "replay_blocked_#{suffix}"

      start_supervised!({SnapshotStore, name: store_name}, id: store_name)

      assert :ok =
               SnapshotStore.put(
                 "#{namespace}:meta",
                 %{"latest_id" => "1"},
                 name: store_name
               )

      assert :ok =
               SnapshotStore.put(
                 "#{namespace}:snapshot:1",
                 %{
                   "snapshot_version" => 2,
                   "global_position" => 1,
                   "stream_versions" => %{"replay-blocked" => 1},
                   "events" => [
                     %{
                       "id" => event.id,
                       "stream_id" => event.stream_id,
                       "event_number" => 1,
                       "global_position" => 1,
                       "type" => event.type,
                       "data" => %{"value" => 1},
                       "metadata" => %{},
                       "timestamp" => timestamp
                     }
                   ],
                   "identity_tombstones" => [
                     %{
                       "event_id" => event.id,
                       "fingerprint" => fingerprint,
                       "stream_id" => event.stream_id,
                       "event_number" => 1,
                       "global_position" => 1
                     }
                   ],
                   "identity_history" => %{
                     "status" => "unavailable",
                     "reason" => "durable_metadata_only"
                   }
                 },
                 name: store_name
               )

      start_supervised!(
        {ETS,
         name: target_name,
         snapshot_store: SnapshotStore,
         snapshot_store_opts: [name: store_name],
         snapshot_namespace: namespace},
        id: target_name
      )

      assert {:ok, {:identity_history_unavailable, _details}} =
               ETS.identity_history_status(name: target_name)

      assert {:error, {:append_indeterminate, ^operation}} =
               ETS.append(event.stream_id, event, name: target_name)

      assert {:error, {:append_indeterminate, ^operation}} =
               ETS.reconcile_append(operation, name: target_name)

      assert Process.alive?(Process.whereis(source_name))
    end

    test "security regression: replay rejects a tampered payload with its persisted fingerprint",
         %{name: name} do
      event =
        %Event{
          Event.new("fingerprint-replay", "arbor.review.ordinary", %{value: 1},
            id: "evt_fingerprint_replay"
          )
          | event_number: 1,
            global_position: 1
        }

      fingerprint = Arbor.Persistence.EventLog.event_fingerprint(event.stream_id, event)

      tampered =
        event
        |> Map.put(:operation_fingerprint, fingerprint)
        |> Map.put(:data, %{"value" => 999})

      assert {:ok, {:identity_history_unavailable, _details}} =
               ETS.rehydrate_metadata(
                 %{stream_versions: %{event.stream_id => 1}, global_position: 1},
                 name: name
               )

      assert {:error, :identity_replay_fingerprint_mismatch} =
               ETS.replay_identity_history([tampered], name: name, complete: true)

      assert {:ok, {:identity_history_unavailable, %{expected_events: 1, loaded_events: 0}}} =
               ETS.identity_history_status(name: name)
    end

    test "security regression: legacy NULL fingerprints require explicit remediation", %{
      name: name
    } do
      event =
        %Event{
          Event.new("legacy-fingerprint", "arbor.review.ordinary", %{value: 1},
            id: "evt_legacy_fingerprint"
          )
          | event_number: 1,
            global_position: 1
        }

      assert {:ok, {:identity_history_unavailable, _details}} =
               ETS.rehydrate_metadata(
                 %{stream_versions: %{event.stream_id => 1}, global_position: 1},
                 name: name
               )

      assert {:error, :identity_replay_fingerprint_missing} =
               ETS.replay_identity_history([event], name: name, complete: true)

      trusted_fingerprint = Arbor.Persistence.EventLog.event_fingerprint(event.stream_id, event)
      remediated = Map.put(event, :operation_fingerprint, trusted_fingerprint)

      assert {:ok, %{status: :identity_history_complete, remaining: 0}} =
               ETS.replay_identity_history([remediated], name: name, complete: true)
    end

    test "identity replay accepts a bounded legacy event above the append event limit", %{
      name: name
    } do
      event =
        %Event{
          Event.new(
            "legacy-large-replay",
            "legacy.payload",
            %{
              "payload" => String.duplicate("x", 1_200_000)
            },
            id: "evt_legacy_large_replay"
          )
          | event_number: 1,
            global_position: 1
        }

      fingerprint = Arbor.Persistence.EventLog.event_fingerprint(event.stream_id, event)
      assert is_binary(fingerprint)

      assert {:ok, {:identity_history_unavailable, _details}} =
               ETS.rehydrate_metadata(
                 %{stream_versions: %{event.stream_id => 1}, global_position: 1},
                 name: name
               )

      assert {:ok, %{accepted: 1, remaining: 0, status: :identity_history_complete}} =
               ETS.replay_identity_history(
                 [%Event{event | operation_fingerprint: fingerprint}],
                 name: name,
                 complete: true
               )
    end

    test "identity replay rejects duplicate stream positions atomically", %{name: name} do
      first =
        %Event{
          Event.new("replayed", "arbor.review.ordinary", %{value: 1}, id: "evt_replay_a")
          | event_number: 1,
            global_position: 1
        }
        |> with_durable_fingerprint()

      conflicting =
        %Event{
          Event.new("replayed", "arbor.review.ordinary", %{value: 2}, id: "evt_replay_b")
          | event_number: 1,
            global_position: 2
        }
        |> with_durable_fingerprint()

      assert {:ok, {:identity_history_unavailable, _details}} =
               ETS.rehydrate_metadata(
                 %{stream_versions: %{"replayed" => 2}, global_position: 2},
                 name: name
               )

      assert {:error, :invalid_identity_replay} =
               apply(ETS, :replay_identity_history, [[first, conflicting], [name: name]])

      assert {:ok,
              {:identity_history_unavailable,
               %{expected_events: 2, loaded_events: 0, reason: :durable_metadata_only}}} =
               apply(ETS, :identity_history_status, [[name: name]])
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

      initialize_empty_store(name)

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

  defp with_durable_fingerprint(%Event{} = event) do
    fingerprint = Arbor.Persistence.EventLog.event_fingerprint(event.stream_id, event)
    Map.put(event, :operation_fingerprint, fingerprint)
  end

  defp initialize_empty_store(name) do
    assert {:ok, :identity_history_complete} =
             ETS.rehydrate_metadata(%{stream_versions: %{}, global_position: 0}, name: name)
  end
end
