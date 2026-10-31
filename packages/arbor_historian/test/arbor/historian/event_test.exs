defmodule Arbor.Historian.EventTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Historian.Event

  describe "new/1" do
    test "creates event with required fields" do
      {:ok, event} = Event.new(type: :test_event, subject_id: "sub_1", data: %{key: "val"})
      assert event.type == :test_event
      assert event.subject_id == "sub_1"
      assert String.starts_with?(event.id, "event_")
      assert event.version == "1.0.0"
      assert %DateTime{} = event.timestamp
    end

    test "creates event with all optional fields" do
      {:ok, event} =
        Event.new(
          type: :test_event,
          subject_id: "sub_1",
          data: %{},
          causation_id: "cause_1",
          correlation_id: "corr_1",
          trace_id: "trace_1",
          metadata: %{key: "val"},
          subject_type: :agent
        )

      assert event.causation_id == "cause_1"
      assert event.correlation_id == "corr_1"
      assert event.trace_id == "trace_1"
      assert event.metadata == %{key: "val"}
      assert event.subject_type == :agent
    end

    test "uses provided id" do
      {:ok, event} = Event.new(type: :test_event, subject_id: "s1", data: %{}, id: "my_id")
      assert event.id == "my_id"
    end

    test "uses provided version" do
      {:ok, event} = Event.new(type: :test_event, subject_id: "s1", data: %{}, version: "2.0.0")
      assert event.version == "2.0.0"
    end

    test "uses provided timestamp" do
      ts = ~U[2025-01-01 00:00:00Z]
      {:ok, event} = Event.new(type: :test_event, subject_id: "s1", data: %{}, timestamp: ts)
      assert event.timestamp == ts
    end
  end

  describe "new/1 validation errors" do
    test "rejects nil type" do
      assert {:error, {:invalid_event_type, nil}} =
               Event.new(type: nil, subject_id: "s1", data: %{})
    end

    test "rejects empty subject_id" do
      assert {:error, {:invalid_subject_id, ""}} =
               Event.new(type: :test_event, subject_id: "", data: %{})
    end

    test "rejects nil subject_id" do
      assert {:error, {:invalid_subject_id, nil}} =
               Event.new(type: :test_event, subject_id: nil, data: %{})
    end

    test "rejects non-map data" do
      assert {:error, {:invalid_event_data, "not_a_map"}} =
               Event.new(type: :test_event, subject_id: "s1", data: "not_a_map")
    end

    test "rejects nil data" do
      assert {:error, {:invalid_event_data, nil}} =
               Event.new(type: :test_event, subject_id: "s1", data: nil)
    end

    test "rejects invalid version format" do
      assert {:error, {:invalid_version_format, "1.0"}} =
               Event.new(type: :test_event, subject_id: "s1", data: %{}, version: "1.0")
    end

    test "rejects non-binary version" do
      assert {:error, {:invalid_version, 123}} =
               Event.new(type: :test_event, subject_id: "s1", data: %{}, version: 123)
    end
  end

  describe "infer_subject_type" do
    test "infers type from subject_id prefix" do
      {:ok, event} = Event.new(type: :test_event, subject_id: "agent_123", data: %{})
      assert event.subject_type == :agent
    end

    test "explicit subject_type overrides inference" do
      {:ok, event} =
        Event.new(type: :test_event, subject_id: "agent_123", data: %{}, subject_type: :custom)

      assert event.subject_type == :custom
    end

    test "returns :unknown for non-matching prefix" do
      {:ok, event} = Event.new(type: :test_event, subject_id: "foobar_123", data: %{})
      assert event.subject_type == :unknown
    end
  end

  describe "set_position/4" do
    test "sets stream positioning" do
      {:ok, event} = Event.new(type: :test_event, subject_id: "s1", data: %{})
      positioned = Event.set_position(event, "global", 5, 42)
      assert positioned.stream_id == "global"
      assert positioned.stream_version == 5
      assert positioned.global_position == 42
    end
  end

  describe "to_map/1" do
    test "converts event to map" do
      {:ok, event} = Event.new(type: :test_event, subject_id: "s1", data: %{k: "v"})
      map = Event.to_map(event)
      assert is_map(map)
      assert map.type == :test_event
      assert map.data == %{k: "v"}
      refute Map.has_key?(map, :__struct__)
    end
  end

  describe "from_map/1" do
    test "restores event from atom-keyed map" do
      {:ok, original} = Event.new(type: :test_event, subject_id: "s1", data: %{k: "v"})
      map = Event.to_map(original)
      {:ok, restored} = Event.from_map(map)
      assert restored.id == original.id
      assert restored.type == original.type
      assert restored.data == original.data
    end

    test "restores event from string-keyed map" do
      map = %{
        "id" => "event_abc",
        "type" => "test_event",
        "version" => "1.0.0",
        "subject_id" => "s1",
        "subject_type" => "agent",
        "data" => %{},
        "timestamp" => "2025-01-01T00:00:00Z"
      }

      {:ok, event} = Event.from_map(map)
      assert event.id == "event_abc"
      assert event.subject_id == "s1"
      assert %DateTime{} = event.timestamp
    end

    test "handles invalid timestamp string" do
      map = %{
        "type" => "test_event",
        "subject_id" => "s1",
        "data" => %{},
        "timestamp" => "not_a_date"
      }

      {:ok, event} = Event.from_map(map)
      # Should fallback to utc_now
      assert %DateTime{} = event.timestamp
    end

    test "handles non-string/non-datetime timestamp" do
      map = %{
        type: :test_event,
        subject_id: "s1",
        data: %{},
        timestamp: 12_345
      }

      {:ok, event} = Event.from_map(map)
      assert %DateTime{} = event.timestamp
    end

    test "handles nil type gracefully via safe atomize" do
      map = %{type: nil, subject_id: "s1", data: %{}}
      # nil atomizes to nil, which fails validation
      assert {:error, {:invalid_event_type, nil}} = Event.from_map(map)
    end
  end
end
