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
end
