defmodule Arbor.Trust.EventConverterTest do
  use ExUnit.Case, async: true

  alias Arbor.Trust.EventConverter
  alias Arbor.Contracts.Trust.Event, as: TrustEvent
  alias Arbor.Persistence.Event, as: PersistenceEvent

  defp build_trust_event(overrides \\ []) do
    {:ok, event} =
      TrustEvent.new(
        Keyword.merge(
          [
            agent_id: "agent_123",
            event_type: :action_success,
            previous_score: 45,
            new_score: 46,
            metadata: %{action: "sort_list"}
          ],
          overrides
        )
      )

    event
  end

  describe "to_persistence_event/1" do
    test "converts a trust event to a persistence event" do
      trust_event = build_trust_event()
      result = EventConverter.to_persistence_event(trust_event)

      assert %PersistenceEvent{} = result
      assert result.id == trust_event.id
      assert result.stream_id == "trust:agent_123"
      assert result.type == "arbor.trust.action_success"
      assert result.data.agent_id == "agent_123"
      assert result.data.previous_score == 45
      assert result.data.new_score == 46
      assert result.metadata == %{action: "sort_list"}
      assert result.timestamp == trust_event.timestamp
    end

    test "preserves tier change data" do
      event =
        build_trust_event(
          event_type: :tier_changed,
          previous_tier: :probationary,
          new_tier: :trusted,
          previous_score: 49,
          new_score: 50
        )

      result = EventConverter.to_persistence_event(event)

      assert result.data.previous_tier == :probationary
      assert result.data.new_tier == :trusted
    end
  end

  describe "from_persistence_event/1" do
    test "converts a persistence event back to a trust event" do
      trust_event = build_trust_event()
      persistence_event = EventConverter.to_persistence_event(trust_event)

      assert {:ok, restored} = EventConverter.from_persistence_event(persistence_event)
      assert restored.id == trust_event.id
      assert restored.agent_id == "agent_123"
      assert restored.event_type == :action_success
      assert restored.previous_score == 45
      assert restored.new_score == 46
    end

    test "roundtrip preserves all fields" do
      event =
        build_trust_event(
          event_type: :tier_changed,
          previous_tier: :probationary,
          new_tier: :trusted,
          previous_score: 49,
          new_score: 50,
          reason: :score_threshold,
          metadata: %{triggered_by: "auto"}
        )

      persistence = EventConverter.to_persistence_event(event)
      {:ok, restored} = EventConverter.from_persistence_event(persistence)

      assert restored.event_type == :tier_changed
      assert restored.previous_tier == :probationary
      assert restored.new_tier == :trusted
      assert restored.reason == :score_threshold
    end
  end

  describe "stream_id/1" do
    test "returns trust:agent_id format" do
      event = build_trust_event(agent_id: "agent_xyz")
      assert EventConverter.stream_id(event) == "trust:agent_xyz"
    end
  end
end
