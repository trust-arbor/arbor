defmodule Arbor.Historian.EventConverterTest do
  use ExUnit.Case, async: true

  alias Arbor.Historian.Event, as: HistorianEvent
  alias Arbor.Historian.EventConverter
  alias Arbor.Persistence.Event, as: PersistenceEvent

  defp build_historian_event(overrides \\ []) do
    {:ok, event} =
      HistorianEvent.new(
        Keyword.merge(
          [
            type: :agent_started,
            subject_id: "agent_123",
            data: %{agent_type: :llm, capabilities: ["read", "write"]},
            causation_id: "cmd_start_xyz",
            correlation_id: "session_abc"
          ],
          overrides
        )
      )

    event
  end

  describe "to_persistence_event/2" do
    test "converts a historian event to a persistence event" do
      historian_event = build_historian_event()
      result = EventConverter.to_persistence_event(historian_event, "activity:agent_123")

      assert %PersistenceEvent{} = result
      assert result.id == historian_event.id
      assert result.stream_id == "activity:agent_123"
      assert result.type == "arbor.historian.agent_started"
      assert result.data == %{agent_type: :llm, capabilities: ["read", "write"]}
      assert result.causation_id == "cmd_start_xyz"
      assert result.correlation_id == "session_abc"
      assert result.metadata[:subject_id] == "agent_123"
      assert result.metadata[:subject_type] == :agent
    end
  end

  describe "from_persistence_event/1" do
    test "converts a persistence event back to a historian event" do
      historian_event = build_historian_event()
      persistence_event = EventConverter.to_persistence_event(historian_event, "activity:agent_123")

      assert {:ok, restored} = EventConverter.from_persistence_event(persistence_event)
      assert restored.id == historian_event.id
      assert restored.type == :agent_started
      assert restored.subject_id == "agent_123"
      assert restored.subject_type == :agent
      assert restored.data == %{agent_type: :llm, capabilities: ["read", "write"]}
      assert restored.causation_id == "cmd_start_xyz"
      assert restored.correlation_id == "session_abc"
    end

    test "roundtrip preserves data" do
      event = build_historian_event(metadata: %{user_id: "user_123"})
      persistence = EventConverter.to_persistence_event(event, "activity:agent_123")
      {:ok, restored} = EventConverter.from_persistence_event(persistence)

      assert restored.type == :agent_started
      assert restored.data == event.data
    end
  end

  describe "edge cases for safe_atomize and atomize_subject_type" do
    test "from_persistence_event handles nil subject_type in metadata" do
      historian_event = build_historian_event()

      persistence_event =
        EventConverter.to_persistence_event(historian_event, "activity:agent_123")

      # Set subject_type to nil in metadata to exercise atomize_subject_type(nil) -> nil
      modified =
        %{persistence_event | metadata: Map.put(persistence_event.metadata, :subject_type, nil)}

      assert {:ok, restored} = EventConverter.from_persistence_event(modified)
      # When subject_type is nil, Event.new infer_subject_type fills it from subject_id
      assert is_atom(restored.subject_type)
    end

    test "from_persistence_event handles atom subject_type passthrough" do
      historian_event = build_historian_event()

      persistence_event =
        EventConverter.to_persistence_event(historian_event, "activity:agent_123")

      # Set subject_type to an atom to exercise atomize_subject_type(atom) -> atom
      modified =
        %{persistence_event | metadata: Map.put(persistence_event.metadata, :subject_type, :session)}

      assert {:ok, restored} = EventConverter.from_persistence_event(modified)
      assert restored.subject_type == :session
    end

    test "safe_atomize returns :unknown for string that is not an existing atom" do
      historian_event = build_historian_event()

      persistence_event =
        EventConverter.to_persistence_event(historian_event, "activity:agent_123")

      # Use a type string that definitely does not exist as an atom
      modified =
        %{persistence_event | type: "arbor.historian.zzz_nonexistent_atom_xyz_99999"}

      assert {:ok, restored} = EventConverter.from_persistence_event(modified)
      assert restored.type == :unknown
    end

    test "extract_type strips arbor.historian. prefix and atomizes" do
      historian_event = build_historian_event()

      persistence_event =
        EventConverter.to_persistence_event(historian_event, "activity:agent_123")

      # The default type is "arbor.historian.agent_started"
      assert persistence_event.type == "arbor.historian.agent_started"

      assert {:ok, restored} = EventConverter.from_persistence_event(persistence_event)
      assert restored.type == :agent_started
    end

    test "extract_type handles plain binary type without prefix" do
      historian_event = build_historian_event()

      persistence_event =
        EventConverter.to_persistence_event(historian_event, "activity:agent_123")

      # Set type to a plain binary (no arbor.historian. prefix)
      modified = %{persistence_event | type: "agent_started"}

      assert {:ok, restored} = EventConverter.from_persistence_event(modified)
      assert restored.type == :agent_started
    end

    test "from_persistence_event with string subject_type in metadata" do
      historian_event = build_historian_event()

      persistence_event =
        EventConverter.to_persistence_event(historian_event, "activity:agent_123")

      # Use string keys in metadata to exercise string subject_type path via atomize_subject_type
      modified =
        %{
          persistence_event
          | metadata: %{
              "subject_type" => "agent",
              "subject_id" => "agent_123",
              "version" => "1.0.0"
            }
        }

      assert {:ok, restored} = EventConverter.from_persistence_event(modified)
      assert restored.subject_type == :agent
    end

    test "from_persistence_event with missing metadata uses stream_id as subject_id" do
      historian_event = build_historian_event()

      persistence_event =
        EventConverter.to_persistence_event(historian_event, "activity:agent_123")

      # Clear all metadata so subject_id falls back to stream_id
      modified = %{persistence_event | metadata: %{}}

      assert {:ok, restored} = EventConverter.from_persistence_event(modified)
      # Falls back to stream_id from persistence event
      assert restored.subject_id == "activity:agent_123"
    end
  end
end
