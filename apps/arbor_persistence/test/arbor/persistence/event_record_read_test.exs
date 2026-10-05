defmodule Arbor.Persistence.EventRecordReadTest do
  use ExUnit.Case, async: true
  alias Arbor.Persistence
  alias Arbor.Persistence.{Event, EventLog}
  @moduletag :fast

  defmodule Unsupported do
    def read_stream(_, _), do: raise("full replay is forbidden")
  end

  defmodule Invalid do
    def read_event_records(_, _, opts), do: {:ok, Process.get(Keyword.fetch!(opts, :name))}
  end

  for backend <- [EventLog.Agent, EventLog.ETS] do
    @backend backend
    test "#{backend} exact reads pin the head and omit only absent transitions" do
      backend = @backend
      name = unique_name()
      start_supervised!({backend, name: name})

      events =
        for n <- 1..100, do: Event.new("stream", "transition", %{value: n}, id: "event_#{n}")

      assert {:ok, _} = Persistence.append(name, backend, "stream", events)

      assert {:ok, %{events: selected, head: head}} =
               Persistence.read_event_records(
                 name,
                 backend,
                 "stream",
                 ["event_90", "absent", "event_1"],
                 max_event_number: 50
               )

      assert Enum.map(selected, & &1.id) == ["event_1"]
      assert head.event_number == 50

      assert {:ok, %{events: [last], head: latest}} =
               Persistence.read_event_records(name, backend, "stream", ["event_100"])

      assert last.id == latest.id
      assert latest.event_number == 100

      assert {:error, :head_unavailable} =
               Persistence.read_event_records(name, backend, "stream", ["event_1"],
                 max_event_number: 101
               )
    end
  end

  test "security regression exact record boundary rejects wrong stream, fingerprint and positions" do
    event = Event.new("stream", "transition", %{text: "saved"}, id: "one")

    event = %{
      event
      | event_number: 1,
        global_position: 1,
        operation_fingerprint: EventLog.event_fingerprint("stream", event)
    }

    valid = %{events: [event], head: event}
    Process.put(:invalid_record_reader, valid)

    assert {:ok, ^valid} =
             Persistence.read_event_records(:invalid_record_reader, Invalid, "stream", ["one"])

    for bad <- [
          %{event | stream_id: "other"},
          %{event | data: %{"text" => "changed"}},
          %{event | event_number: 0},
          %{event | global_position: nil},
          %{event | operation_fingerprint: nil}
        ] do
      Process.put(:invalid_record_reader, %{events: [bad], head: event})

      assert {:error, :event_records_invalid} =
               Persistence.read_event_records(:invalid_record_reader, Invalid, "stream", ["one"])
    end

    Process.put(:invalid_record_reader, %{events: [event], head: nil})

    assert {:error, :event_records_invalid} =
             Persistence.read_event_records(:invalid_record_reader, Invalid, "stream", ["one"],
               max_event_number: 1
             )
  end

  test "unsupported adapters and invalid bounds never trigger a stream replay fallback" do
    assert {:error, :event_records_not_supported} =
             Persistence.read_event_records(:records, Unsupported, "stream", ["one"])

    for {ids, opts} <- [
          {[], []},
          {List.duplicate("one", 6), []},
          {["one", "one"], []},
          {["one"], [max_event_number: -1]},
          {["one"], [limit: 100]},
          {["one"], [max_event_number: 1, max_event_number: 2]}
        ] do
      assert {:error, :invalid_precondition} =
               Persistence.read_event_records(:records, Unsupported, "stream", ids, opts)
    end
  end

  test "security regression the Agent exact reader detects stored payload corruption" do
    name = unique_name()
    start_supervised!({EventLog.Agent, name: name})

    assert {:ok, _} =
             Persistence.append(name, EventLog.Agent, "stream", [
               Event.new("stream", "transition", %{text: "saved"}, id: "one")
             ])

    Agent.update(name, fn state ->
      put_in(state.event_index["one"].data, %{"text" => "altered"})
    end)

    assert {:error, :event_records_invalid} =
             Persistence.read_event_records(name, EventLog.Agent, "stream", ["one"])
  end

  test "security regression exact records enforce a cumulative byte bound" do
    events =
      for n <- 1..5 do
        event =
          Event.new("stream", "transition", %{text: String.duplicate("x", 800_000)},
            id: "large_#{n}"
          )

        %{
          event
          | event_number: n,
            global_position: n,
            operation_fingerprint: EventLog.event_fingerprint("stream", event)
        }
      end

    Process.put(:large_record_reader, %{events: events, head: List.last(events)})

    assert {:error, :event_records_invalid} =
             Persistence.read_event_records(
               :large_record_reader,
               Invalid,
               "stream",
               Enum.map(events, & &1.id)
             )
  end

  defp unique_name, do: String.to_atom("bounded_records_#{System.unique_integer([:positive])}")
end
