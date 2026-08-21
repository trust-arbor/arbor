defmodule Arbor.Persistence.EventLog.ProjectionCoreTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Persistence.Event
  alias Arbor.Persistence.EventLog
  alias Arbor.Persistence.EventLog.ProjectionCore

  @timestamp ~U[2026-08-21 00:00:00.000000Z]
  @max_events 1_000_000

  describe "prepare/1 batch validation" do
    test "rejects anything that is not a nonempty list of events" do
      assert {:error, :invalid_projection_events} = ProjectionCore.prepare([])
      assert {:error, :invalid_projection_events} = ProjectionCore.prepare(:not_a_list)
      assert {:error, :invalid_projection_events} = ProjectionCore.prepare([%{}])
      assert {:error, :invalid_projection_events} = ProjectionCore.prepare([event(), :garbage])
    end

    test "bounds the batch at 1000 events" do
      assert ProjectionCore.max_batch_events() == 1_000

      at_limit =
        for n <- 1..1_000, do: event(id: "evt_#{n}", event_number: n, global_position: n)

      assert {:ok, entries} = ProjectionCore.prepare(at_limit)
      assert length(entries) == 1_000

      over_limit =
        at_limit ++ [event(id: "evt_1001", event_number: 1_001, global_position: 1_001)]

      assert {:error, :projection_batch_too_large} = ProjectionCore.prepare(over_limit)
    end

    test "requires positive bounded stream and global positions" do
      for invalid <- [0, -1, 2_147_483_648, nil, "1", 1.0] do
        assert {:error, :invalid_projection_events} =
                 ProjectionCore.prepare([event(event_number: invalid)])

        assert {:error, :invalid_projection_events} =
                 ProjectionCore.prepare([event(global_position: invalid)])
      end
    end

    test "canonicalizes data and metadata through JSON before deciding" do
      atom_keyed = event(data: %{nested: %{count: 1}})

      canonical =
        %Event{atom_keyed | data: %{"nested" => %{"count" => 1}}}
        |> with_fingerprint()

      assert {:ok, [entry]} =
               ProjectionCore.prepare([
                 %Event{atom_keyed | operation_fingerprint: canonical.operation_fingerprint}
               ])

      assert entry.event.data == %{"nested" => %{"count" => 1}}
      assert entry.event == canonical
    end

    test "distinguishes missing, malformed, and mismatched fingerprints" do
      assert {:error, :projection_fingerprint_missing} =
               ProjectionCore.prepare([%Event{event() | operation_fingerprint: nil}])

      assert {:error, :projection_fingerprint_invalid} =
               ProjectionCore.prepare([%Event{event() | operation_fingerprint: "not-a-digest"}])

      assert {:error, :projection_fingerprint_invalid} =
               ProjectionCore.prepare([%Event{event() | operation_fingerprint: ""}])

      assert {:error, :projection_fingerprint_mismatch} =
               ProjectionCore.prepare([
                 %Event{event() | operation_fingerprint: String.duplicate("a", 64)}
               ])
    end

    test "rejects a fingerprint that matches other content than the event carries" do
      original = event(data: %{"amount" => 1})
      tampered = %Event{original | data: %{"amount" => 1_000_000}}

      assert {:error, :projection_fingerprint_mismatch} = ProjectionCore.prepare([tampered])
    end

    test "rejects duplicate identity, global position, and stream position inside one batch" do
      assert {:error, :event_id_conflict} =
               ProjectionCore.prepare([
                 event(id: "evt_dup", event_number: 1, global_position: 1),
                 event(id: "evt_dup", event_number: 2, global_position: 2)
               ])

      assert {:error, :global_position_conflict} =
               ProjectionCore.prepare([
                 event(id: "evt_a", event_number: 1, global_position: 7),
                 event(id: "evt_b", event_number: 2, global_position: 7)
               ])

      assert {:error, :stream_position_conflict} =
               ProjectionCore.prepare([
                 event(id: "evt_a", event_number: 3, global_position: 1),
                 event(id: "evt_b", event_number: 3, global_position: 2)
               ])
    end

    test "preserves the exact caller-supplied positions and fingerprint" do
      assert {:ok, [entry]} =
               ProjectionCore.prepare([event(event_number: 41, global_position: 907)])

      assert entry.event_number == 41
      assert entry.global_position == 907
      assert entry.stream_position == {"stream", 41}
      assert entry.identity == {entry.fingerprint, "stream", 41, 907}
      assert entry.fingerprint == EventLog.event_fingerprint("stream", entry.event)
    end
  end

  describe "plan/4 against resident surfaces" do
    test "projects every surface for an absent event" do
      {:ok, entries} = ProjectionCore.prepare([event(event_number: 1, global_position: 1)])
      [entry] = entries

      assert {:ok, plan} = ProjectionCore.plan(entries, empty_resident(), 0, @max_events)

      assert plan.projected == 1
      assert plan.skipped == 0
      assert plan.global_rows == [{1, entry.event}]
      assert plan.stream_rows == [{{"stream", 1}, 1}]
      assert plan.identity_rows == [{entry.event_id, entry.identity}]
      assert plan.identity_position_rows == [{1, entry.event_id}]
      assert plan.identity_stream_position_rows == [{{"stream", 1}, entry.event_id}]
      assert plan.stream_versions == %{"stream" => 1}
      assert plan.max_global_position == 1
    end

    test "byte-identical re-projection is skipped, not re-inserted" do
      {:ok, [entry] = entries} =
        ProjectionCore.prepare([event(event_number: 1, global_position: 1)])

      assert {:ok, plan} = ProjectionCore.plan(entries, resident_for([entry]), 1, @max_events)

      assert plan.projected == 0
      assert plan.skipped == 1
      assert plan.global_rows == []
      assert plan.identity_rows == []
      assert plan.stream_versions == %{"stream" => 1}
    end

    test "re-projects an event whose payload was evicted but identity survives" do
      {:ok, [entry] = entries} =
        ProjectionCore.prepare([event(event_number: 1, global_position: 1)])

      resident = %{resident_for([entry]) | payloads: %{}}

      assert {:ok, plan} = ProjectionCore.plan(entries, resident, 0, @max_events)
      assert plan.projected == 1
      assert plan.global_rows == [{1, entry.event}]
    end

    test "reports an event-id conflict when a resident identity disagrees" do
      {:ok, [entry] = entries} =
        ProjectionCore.prepare([event(event_number: 1, global_position: 1)])

      {fingerprint, stream_id, event_number, _position} = entry.identity

      resident = %{
        empty_resident()
        | identities: %{entry.event_id => {fingerprint, stream_id, event_number, 99}}
      }

      assert {:error, :event_id_conflict} =
               ProjectionCore.plan(entries, resident, 0, @max_events)
    end

    test "reports a global-position conflict when the position belongs to another event" do
      {:ok, [entry] = entries} =
        ProjectionCore.prepare([event(event_number: 1, global_position: 1)])

      resident = %{empty_resident() | identity_positions: %{1 => "evt_other"}}

      assert {:error, :global_position_conflict} =
               ProjectionCore.plan(entries, resident, 0, @max_events)

      %Event{} = projected = entry.event
      payload_resident = %{empty_resident() | payloads: %{1 => %{projected | id: "evt_other"}}}

      assert {:error, :global_position_conflict} =
               ProjectionCore.plan(entries, payload_resident, 0, @max_events)
    end

    test "reports a stream-position conflict from either stream-keyed surface" do
      {:ok, [_entry] = entries} =
        ProjectionCore.prepare([event(event_number: 1, global_position: 1)])

      identity_stream = %{
        empty_resident()
        | identity_stream_positions: %{{"stream", 1} => "evt_other"}
      }

      assert {:error, :stream_position_conflict} =
               ProjectionCore.plan(entries, identity_stream, 0, @max_events)

      pointer = %{empty_resident() | stream_pointers: %{{"stream", 1} => 42}}

      assert {:error, :stream_position_conflict} =
               ProjectionCore.plan(entries, pointer, 0, @max_events)
    end

    test "a malformed resident row is a conflict, never treated as absence" do
      {:ok, [entry] = entries} =
        ProjectionCore.prepare([event(event_number: 1, global_position: 1)])

      malformed = [
        {:identities, %{entry.event_id => :malformed}, :event_id_conflict},
        {:identity_positions, %{1 => :malformed}, :global_position_conflict},
        {:identity_stream_positions, %{{"stream", 1} => :malformed}, :stream_position_conflict},
        {:stream_pointers, %{{"stream", 1} => :malformed}, :stream_position_conflict},
        {:payloads, %{1 => :malformed}, :global_position_conflict}
      ]

      for {surface, rows, expected} <- malformed do
        resident = Map.put(empty_resident(), surface, rows)

        assert {:error, ^expected} = ProjectionCore.plan(entries, resident, 0, @max_events),
               "malformed #{surface} row must conflict"
      end
    end

    test "a legacy two-element identity row conflicts instead of being overwritten" do
      {:ok, [entry] = entries} =
        ProjectionCore.prepare([event(event_number: 1, global_position: 1)])

      resident = %{empty_resident() | identities: %{entry.event_id => {entry.fingerprint, 1}}}

      assert {:error, :event_id_conflict} =
               ProjectionCore.plan(entries, resident, 0, @max_events)
    end

    test "a conflict on the third event abandons the whole batch" do
      {:ok, entries} =
        ProjectionCore.prepare([
          event(id: "evt_1", event_number: 1, global_position: 1),
          event(id: "evt_2", event_number: 2, global_position: 2),
          event(id: "evt_3", event_number: 3, global_position: 3)
        ])

      resident = %{empty_resident() | identity_positions: %{3 => "evt_other"}}

      assert {:error, :global_position_conflict} =
               ProjectionCore.plan(entries, resident, 0, @max_events)
    end

    test "refuses a batch that would exceed the resident ceiling" do
      {:ok, entries} =
        ProjectionCore.prepare([
          event(id: "evt_1", event_number: 1, global_position: 1),
          event(id: "evt_2", event_number: 2, global_position: 2)
        ])

      assert {:error, :projection_capacity_exceeded} =
               ProjectionCore.plan(entries, empty_resident(), 9, 10)

      assert {:ok, _plan} = ProjectionCore.plan(entries, empty_resident(), 8, 10)
    end

    test "skipped events do not consume capacity" do
      {:ok, [entry] = entries} =
        ProjectionCore.prepare([event(event_number: 1, global_position: 1)])

      assert {:ok, plan} = ProjectionCore.plan(entries, resident_for([entry]), 10, 10)
      assert plan.skipped == 1
    end
  end

  test "the core is pure: no ETS, process, clock, or randomness access" do
    source =
      Path.expand(
        "../../../../lib/arbor/persistence/event_log/projection_core.ex",
        __DIR__
      )
      |> File.read!()

    for forbidden <- [
          ":ets.",
          "GenServer.",
          "Process.",
          "Agent.",
          "send(",
          "Logger.",
          "DateTime.utc_now",
          "System.monotonic_time",
          ":rand.",
          "File."
        ] do
      refute source =~ forbidden,
             "ProjectionCore must stay pure but references #{forbidden}"
    end
  end

  defp empty_resident do
    %{
      identities: %{},
      identity_positions: %{},
      identity_stream_positions: %{},
      payloads: %{},
      stream_pointers: %{}
    }
  end

  defp resident_for(entries) do
    Enum.reduce(entries, empty_resident(), fn entry, acc ->
      %{
        acc
        | identities: Map.put(acc.identities, entry.event_id, entry.identity),
          identity_positions:
            Map.put(acc.identity_positions, entry.global_position, entry.event_id),
          identity_stream_positions:
            Map.put(acc.identity_stream_positions, entry.stream_position, entry.event_id),
          payloads: Map.put(acc.payloads, entry.global_position, entry.event),
          stream_pointers:
            Map.put(acc.stream_pointers, entry.stream_position, entry.global_position)
      }
    end)
  end

  defp event(opts \\ []) do
    stream_id = Keyword.get(opts, :stream_id, "stream")

    %Event{
      id: Keyword.get(opts, :id, "evt_projected"),
      stream_id: stream_id,
      event_number: Keyword.get(opts, :event_number, 1),
      global_position: Keyword.get(opts, :global_position, 1),
      type: Keyword.get(opts, :type, "projected"),
      data: Keyword.get(opts, :data, %{"value" => "v"}),
      metadata: %{},
      timestamp: Keyword.get(opts, :timestamp, @timestamp)
    }
    |> with_fingerprint()
  end

  defp with_fingerprint(%Event{} = event) do
    %Event{event | operation_fingerprint: EventLog.event_fingerprint(event.stream_id, event)}
  end
end
