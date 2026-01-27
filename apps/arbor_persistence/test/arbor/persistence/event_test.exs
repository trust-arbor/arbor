defmodule Arbor.Persistence.EventTest do
  use ExUnit.Case, async: true

  alias Arbor.Persistence.Event

  describe "new/4" do
    test "creates event with auto-generated id and timestamp" do
      event = Event.new("stream-1", "user_created", %{name: "Alice"})

      assert String.starts_with?(event.id, "evt_")
      assert event.stream_id == "stream-1"
      assert event.type == "user_created"
      assert event.data == %{name: "Alice"}
      assert event.event_number == 0
      assert event.global_position == nil
      assert %DateTime{} = event.timestamp
    end

    test "creates event with causation and correlation IDs" do
      event =
        Event.new("stream-1", "order_placed", %{},
          causation_id: "cause_123",
          correlation_id: "corr_456"
        )

      assert event.causation_id == "cause_123"
      assert event.correlation_id == "corr_456"
    end

    test "creates event with custom metadata" do
      event = Event.new("s1", "t1", %{}, metadata: %{source: "api"})
      assert event.metadata == %{source: "api"}
    end

    test "creates event with default empty data" do
      event = Event.new("s1", "t1")
      assert event.data == %{}
    end
  end

  describe "Jason encoding" do
    test "encodes to JSON" do
      event = Event.new("stream-1", "test_event", %{value: 1})
      assert {:ok, json} = Jason.encode(event)
      assert is_binary(json)
      decoded = Jason.decode!(json)
      assert decoded["stream_id"] == "stream-1"
      assert decoded["type"] == "test_event"
    end
  end
end
