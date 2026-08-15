defmodule Arbor.Contracts.Persistence.AppendOperationTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Persistence.AppendOperation

  @fingerprint String.duplicate("a", 64)

  test "constructs a bounded exact-ID operation" do
    assert {:ok, operation} =
             AppendOperation.new(
               operation_id: "append_123",
               stream_id: "stream-1",
               event_ids: ["evt_1"],
               fingerprints: %{"evt_1" => @fingerprint}
             )

    assert operation.event_ids == ["evt_1"]
    assert Jason.encode!(operation) =~ "append_123"
  end

  test "rejects duplicate IDs and incomplete fingerprints" do
    assert {:error, :invalid_append_operation} =
             AppendOperation.new(
               operation_id: "append_123",
               stream_id: "stream-1",
               event_ids: ["evt_1", "evt_1"],
               fingerprints: %{"evt_1" => @fingerprint}
             )

    assert {:error, :invalid_append_operation} =
             AppendOperation.new(
               operation_id: "append_123",
               stream_id: "stream-1",
               event_ids: ["evt_1"],
               fingerprints: %{}
             )
  end

  test "security regression: fingerprints are lowercase 64-character hexadecimal strings" do
    for invalid <- [
          String.duplicate("g", 64),
          String.duplicate("A", 64),
          String.duplicate("0", 63) <> <<255>>
        ] do
      assert {:error, :invalid_append_operation} =
               AppendOperation.new(
                 operation_id: "append_123",
                 stream_id: "stream-1",
                 event_ids: ["evt_1"],
                 fingerprints: %{"evt_1" => invalid}
               )
    end
  end

  test "accepts exactly the maximum bounded event set" do
    event_ids = Enum.map(1..1_000, &"evt_#{&1}")
    fingerprints = Map.new(event_ids, &{&1, @fingerprint})

    assert {:ok, operation} =
             AppendOperation.new(
               operation_id: "append_123",
               stream_id: "stream-1",
               event_ids: event_ids,
               fingerprints: fingerprints
             )

    assert operation.event_ids == event_ids
  end

  test "rejects huge and improper event ID lists without raising" do
    huge_event_ids = Enum.map(1..100_000, &"evt_#{&1}")

    assert {:error, :invalid_append_operation} =
             AppendOperation.new(
               operation_id: "append_123",
               stream_id: "stream-1",
               event_ids: huge_event_ids,
               fingerprints: %{}
             )

    assert {:error, :invalid_append_operation} =
             AppendOperation.new(
               operation_id: "append_123",
               stream_id: "stream-1",
               event_ids: ["evt_1" | :improper],
               fingerprints: %{"evt_1" => @fingerprint}
             )
  end

  test "rejects oversized and improper attribute lists without converting them" do
    valid_attrs = [
      operation_id: "append_123",
      stream_id: "stream-1",
      event_ids: ["evt_1"],
      fingerprints: %{"evt_1" => @fingerprint}
    ]

    oversized_attrs = valid_attrs ++ List.duplicate({:operation_id, "ignored"}, 100_000)

    assert {:error, :invalid_append_operation} = AppendOperation.new(oversized_attrs)

    assert {:error, :invalid_append_operation} =
             AppendOperation.new([{:operation_id, "append_123"} | :improper])
  end
end
