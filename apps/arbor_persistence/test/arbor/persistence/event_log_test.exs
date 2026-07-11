defmodule Arbor.Persistence.EventLogTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Persistence.AppendOperation
  alias Arbor.Persistence.{Event, EventLog}

  test "admission rejects improper event and option lists without raising" do
    event = Event.new("bounded", "created", %{value: 1})

    assert {:error, :invalid_events} =
             EventLog.validate_append("bounded", [event | :improper], [])

    assert {:error, :invalid_precondition} =
             EventLog.validate_append("bounded", event, [{:expected_version, 0} | :improper])

    assert {:error, :invalid_precondition} =
             EventLog.operation_deadline([{:append_timeout_ms, 10} | :improper])
  end

  test "admission rejects non-JSON data and invalid durable identity fields" do
    base = Event.new("json", "created", %{value: 1})

    invalid_events = [
      %Event{base | data: %{callback: fn -> :ok end}},
      %Event{base | metadata: %{owner: self()}},
      %Event{base | timestamp: "not-a-datetime"},
      %Event{base | agent_id: 42},
      %Event{base | causation_id: ""},
      %Event{base | correlation_id: String.duplicate("x", 1_025)}
    ]

    Enum.each(invalid_events, fn event ->
      assert {:error, :invalid_events} = EventLog.validate_append("json", event, [])
      assert {:error, :invalid_append_operation} = EventLog.build_operation("json", [event])
      assert is_nil(EventLog.event_fingerprint("json", event))
    end)
  end

  test "build and reconciliation helpers are total and bounded" do
    event = Event.new("bounded", "created", %{value: 1})

    assert {:ok, %AppendOperation{} = operation} =
             EventLog.build_operation("bounded", [event])

    assert {:error, :invalid_append_operation} =
             EventLog.build_operation("bounded", [event | :improper])

    oversized_events =
      Enum.map(1..1_001, fn index ->
        Event.new("bounded", "created", %{index: index}, id: "evt_#{index}")
      end)

    assert {:error, :invalid_append_operation} =
             EventLog.build_operation("bounded", oversized_events)

    assert {:error, :invalid_reconciliation} =
             EventLog.reconcile_events(operation, [event | :improper])

    assert {:error, :invalid_reconciliation} =
             EventLog.reconcile_events(operation, List.duplicate(event, 1_001))

    forged = %AppendOperation{operation | event_ids: [event.id | :improper]}
    assert {:error, :invalid_append_operation} = EventLog.reconcile_events(forged, [event])
  end
end
