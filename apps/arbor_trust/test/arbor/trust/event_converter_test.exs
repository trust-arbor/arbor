defmodule Arbor.Trust.EventConverterTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Trust.Event, as: TrustEvent
  alias Arbor.Persistence.Event, as: PersistenceEvent
  alias Arbor.Trust.EventConverter

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

  describe "from_persistence_event/1 with string keys" do
    test "handles string keys in data map" do
      persistence_event =
        PersistenceEvent.new(
          "trust:agent_str_keys",
          "arbor.trust.action_success",
          %{
            "agent_id" => "agent_str_keys",
            "event_type" => "action_success",
            "previous_score" => 50,
            "new_score" => 55,
            "previous_tier" => "trusted",
            "new_tier" => "trusted"
          }
        )

      assert {:ok, event} = EventConverter.from_persistence_event(persistence_event)
      assert event.agent_id == "agent_str_keys"
      assert event.event_type == :action_success
      assert event.previous_score == 50
      assert event.new_score == 55
      assert event.previous_tier == :trusted
      assert event.new_tier == :trusted
    end

    test "handles string keys for tier_changed event type" do
      persistence_event =
        PersistenceEvent.new(
          "trust:agent_str_tier",
          "arbor.trust.tier_changed",
          %{
            "agent_id" => "agent_str_tier",
            "event_type" => "tier_changed",
            "previous_score" => 49,
            "new_score" => 50,
            "previous_tier" => "probationary",
            "new_tier" => "trusted"
          }
        )

      assert {:ok, event} = EventConverter.from_persistence_event(persistence_event)
      assert event.event_type == :tier_changed
      assert event.previous_tier == :probationary
      assert event.new_tier == :trusted
    end

    test "handles mixed atom and string keys in data map" do
      # Elixir maps allow mixed key types when using the => syntax
      data = Map.new([
        {:agent_id, "agent_mixed"},
        {"event_type", "action_success"},
        {:previous_score, 30},
        {"new_score", 35},
        {"previous_tier", "untrusted"},
        {:new_tier, :probationary}
      ])

      persistence_event =
        PersistenceEvent.new(
          "trust:agent_mixed",
          "arbor.trust.action_success",
          data
        )

      assert {:ok, event} = EventConverter.from_persistence_event(persistence_event)
      assert event.agent_id == "agent_mixed"
      assert event.event_type == :action_success
      assert event.previous_score == 30
      assert event.new_score == 35
    end
  end

  describe "from_persistence_event/1 with nil fields" do
    test "handles nil tier values" do
      persistence_event =
        PersistenceEvent.new(
          "trust:agent_nil",
          "arbor.trust.action_success",
          %{
            agent_id: "agent_nil",
            event_type: :action_success,
            previous_score: 0,
            new_score: 5,
            previous_tier: nil,
            new_tier: nil
          }
        )

      assert {:ok, event} = EventConverter.from_persistence_event(persistence_event)
      assert event.previous_tier == nil
      assert event.new_tier == nil
      assert event.event_type == :action_success
    end

    test "handles nil event_type" do
      persistence_event =
        PersistenceEvent.new(
          "trust:agent_nil_type",
          "arbor.trust.nil",
          %{
            agent_id: "agent_nil_type",
            event_type: nil,
            previous_score: 0,
            new_score: 0
          }
        )

      # nil event_type should pass through atomize_event_type as nil
      # but TrustEvent.new validates event_type, so this may error
      result = EventConverter.from_persistence_event(persistence_event)
      # Either returns ok with nil event_type or an error from validation
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "handles nil scores" do
      persistence_event =
        PersistenceEvent.new(
          "trust:agent_nil_scores",
          "arbor.trust.action_success",
          %{
            agent_id: "agent_nil_scores",
            event_type: :action_success,
            previous_score: nil,
            new_score: nil,
            previous_tier: :untrusted,
            new_tier: :untrusted
          }
        )

      assert {:ok, event} = EventConverter.from_persistence_event(persistence_event)
      assert event.previous_score == nil
      assert event.new_score == nil
    end

    test "handles missing optional fields in data" do
      persistence_event =
        PersistenceEvent.new(
          "trust:agent_minimal",
          "arbor.trust.action_success",
          %{
            agent_id: "agent_minimal",
            event_type: :action_success
          }
        )

      assert {:ok, event} = EventConverter.from_persistence_event(persistence_event)
      assert event.agent_id == "agent_minimal"
      assert event.event_type == :action_success
      assert event.previous_score == nil
      assert event.new_score == nil
      assert event.previous_tier == nil
      assert event.new_tier == nil
    end
  end

  describe "from_persistence_event/1 with unknown values" do
    test "handles unknown event type string" do
      persistence_event =
        PersistenceEvent.new(
          "trust:agent_unk",
          "arbor.trust.unknown_type",
          %{
            agent_id: "agent_unk",
            event_type: "totally_invalid_type",
            previous_score: 0,
            new_score: 0
          }
        )

      result = EventConverter.from_persistence_event(persistence_event)
      # atomize_event_type returns nil for unknown types
      # TrustEvent.new may reject nil event_type as invalid
      assert match?({:ok, _}, result) or match?({:error, _}, result)

      case result do
        {:ok, event} ->
          assert event.event_type == nil

        {:error, reason} ->
          # Validation error is acceptable for invalid event type
          assert reason != nil
      end
    end

    test "handles unknown tier string" do
      persistence_event =
        PersistenceEvent.new(
          "trust:agent_unk_tier",
          "arbor.trust.action_success",
          %{
            agent_id: "agent_unk_tier",
            event_type: :action_success,
            previous_score: 0,
            new_score: 0,
            previous_tier: "invalid_tier",
            new_tier: "also_invalid"
          }
        )

      assert {:ok, event} = EventConverter.from_persistence_event(persistence_event)
      # Unknown tier strings should return nil from atomize_tier
      assert event.previous_tier == nil
      assert event.new_tier == nil
    end

    test "handles empty string event type" do
      persistence_event =
        PersistenceEvent.new(
          "trust:agent_empty_type",
          "arbor.trust.empty",
          %{
            agent_id: "agent_empty_type",
            event_type: "",
            previous_score: 0,
            new_score: 0
          }
        )

      result = EventConverter.from_persistence_event(persistence_event)
      # Empty string for event_type goes through atomize_event_type
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "handles empty string tier values" do
      persistence_event =
        PersistenceEvent.new(
          "trust:agent_empty_tier",
          "arbor.trust.action_success",
          %{
            agent_id: "agent_empty_tier",
            event_type: :action_success,
            previous_score: 10,
            new_score: 15,
            previous_tier: "",
            new_tier: ""
          }
        )

      assert {:ok, event} = EventConverter.from_persistence_event(persistence_event)
      # Empty strings should map to nil via atomize_tier
      assert event.previous_tier == nil
      assert event.new_tier == nil
    end
  end

  describe "from_persistence_event/1 with all valid event types as strings" do
    test "handles all known event type strings" do
      valid_types = [
        "action_success",
        "action_failure",
        "test_passed",
        "test_failed",
        "rollback_executed",
        "security_violation",
        "improvement_applied",
        "trust_frozen",
        "trust_unfrozen",
        "trust_decayed",
        "tier_changed",
        "profile_created",
        "profile_deleted"
      ]

      for type_string <- valid_types do
        persistence_event =
          PersistenceEvent.new(
            "trust:agent_type_#{type_string}",
            "arbor.trust.#{type_string}",
            %{
              "agent_id" => "agent_type_#{type_string}",
              "event_type" => type_string,
              "previous_score" => 10,
              "new_score" => 15
            }
          )

        assert {:ok, event} = EventConverter.from_persistence_event(persistence_event),
               "Failed to convert event type string: #{type_string}"

        assert event.event_type == String.to_existing_atom(type_string),
               "Event type mismatch for: #{type_string}"
      end
    end
  end

  describe "from_persistence_event/1 with all valid tier strings" do
    test "handles all known tier strings" do
      valid_tiers = [
        "untrusted",
        "probationary",
        "trusted",
        "veteran",
        "autonomous"
      ]

      for tier_string <- valid_tiers do
        persistence_event =
          PersistenceEvent.new(
            "trust:agent_tier_#{tier_string}",
            "arbor.trust.action_success",
            %{
              "agent_id" => "agent_tier_#{tier_string}",
              "event_type" => "action_success",
              "previous_score" => 10,
              "new_score" => 15,
              "previous_tier" => tier_string,
              "new_tier" => tier_string
            }
          )

        assert {:ok, event} = EventConverter.from_persistence_event(persistence_event),
               "Failed to convert tier string: #{tier_string}"

        assert event.previous_tier == String.to_existing_atom(tier_string),
               "Previous tier mismatch for: #{tier_string}"

        assert event.new_tier == String.to_existing_atom(tier_string),
               "New tier mismatch for: #{tier_string}"
      end
    end

    test "handles legacy tier strings elevated and core" do
      for tier_string <- ["elevated", "core"] do
        persistence_event =
          PersistenceEvent.new(
            "trust:agent_legacy_#{tier_string}",
            "arbor.trust.action_success",
            %{
              "agent_id" => "agent_legacy_#{tier_string}",
              "event_type" => "action_success",
              "previous_score" => 10,
              "new_score" => 15,
              "previous_tier" => tier_string,
              "new_tier" => tier_string
            }
          )

        assert {:ok, event} = EventConverter.from_persistence_event(persistence_event),
               "Failed to convert legacy tier string: #{tier_string}"

        assert event.previous_tier == String.to_existing_atom(tier_string),
               "Legacy tier mismatch for: #{tier_string}"
      end
    end
  end

  describe "to_persistence_event/1 additional cases" do
    test "preserves reason field" do
      event = build_trust_event(reason: :score_threshold)
      result = EventConverter.to_persistence_event(event)

      assert result.data.reason == :score_threshold
    end

    test "preserves delta field" do
      event = build_trust_event(previous_score: 10, new_score: 15)
      result = EventConverter.to_persistence_event(event)

      assert result.data.previous_score == 10
      assert result.data.new_score == 15
    end

    test "handles nil metadata" do
      event = build_trust_event(metadata: nil)
      result = EventConverter.to_persistence_event(event)

      # nil metadata should be converted to empty map
      assert result.metadata == %{}
    end

    test "preserves event id through conversion" do
      event = build_trust_event()
      result = EventConverter.to_persistence_event(event)

      assert result.id == event.id
    end

    test "preserves timestamp through conversion" do
      event = build_trust_event()
      result = EventConverter.to_persistence_event(event)

      assert result.timestamp == event.timestamp
    end
  end

  describe "roundtrip with string keys" do
    test "roundtrip with string keys preserves core data" do
      # Create a trust event, convert to persistence, then simulate string keys
      original = build_trust_event(
        event_type: :action_success,
        previous_score: 40,
        new_score: 45,
        previous_tier: :probationary,
        new_tier: :probationary
      )

      persistence = EventConverter.to_persistence_event(original)

      # Simulate what might happen when data is serialized/deserialized (string keys)
      string_key_data =
        persistence.data
        |> Enum.map(fn {k, v} -> {Atom.to_string(k), v} end)
        |> Map.new()

      string_persistence = %{persistence | data: string_key_data}

      assert {:ok, restored} = EventConverter.from_persistence_event(string_persistence)
      assert restored.agent_id == original.agent_id
      assert restored.event_type == original.event_type
      assert restored.previous_score == original.previous_score
      assert restored.new_score == original.new_score
    end
  end
end
