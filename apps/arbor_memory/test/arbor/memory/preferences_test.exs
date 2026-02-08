defmodule Arbor.Memory.PreferencesTest do
  use ExUnit.Case, async: true

  alias Arbor.Memory.Preferences

  @moduletag :fast

  describe "new/2" do
    test "creates with defaults" do
      prefs = Preferences.new("agent_001")

      assert prefs.agent_id == "agent_001"
      assert prefs.decay_rate == 0.10
      assert prefs.max_pins == 50
      assert prefs.retrieval_threshold == 0.3
      assert prefs.consolidation_interval == 1_800_000
      assert prefs.pinned_memories == []
      assert prefs.attention_focus == nil
      assert is_map(prefs.type_quotas)
    end

    test "accepts custom options" do
      prefs = Preferences.new("agent_001", decay_rate: 0.15, max_pins: 100)

      assert prefs.decay_rate == 0.15
      assert prefs.max_pins == 100
    end

    test "starts with nil last_adjusted_at and 0 adjustment_count" do
      prefs = Preferences.new("agent_001")

      assert prefs.last_adjusted_at == nil
      assert prefs.adjustment_count == 0
    end

    test "creates with default context_preferences" do
      prefs = Preferences.new("agent_001")

      assert prefs.context_preferences.include_goals == true
      assert prefs.context_preferences.include_relationships == true
      assert prefs.context_preferences.include_recent_facts == true
      assert prefs.context_preferences.include_self_insights == true
      assert prefs.context_preferences.max_context_nodes == 50
    end

    test "accepts custom context_preferences" do
      custom = %{include_goals: false, max_context_nodes: 30}
      prefs = Preferences.new("agent_001", context_preferences: custom)

      assert prefs.context_preferences.include_goals == false
      assert prefs.context_preferences.max_context_nodes == 30
    end
  end

  describe "memory pinning" do
    test "pin adds memory to pinned list" do
      prefs =
        Preferences.new("agent_001")
        |> Preferences.pin("memory_123")

      assert "memory_123" in prefs.pinned_memories
    end

    test "pin is idempotent" do
      prefs =
        Preferences.new("agent_001")
        |> Preferences.pin("memory_123")
        |> Preferences.pin("memory_123")

      assert length(prefs.pinned_memories) == 1
    end

    test "pin respects max_pins limit" do
      prefs = Preferences.new("agent_001", max_pins: 2)

      prefs = Preferences.pin(prefs, "mem_1")
      prefs = Preferences.pin(prefs, "mem_2")
      result = Preferences.pin(prefs, "mem_3")

      assert result == {:error, :max_pins_reached}
    end

    test "unpin removes memory from list" do
      prefs =
        Preferences.new("agent_001")
        |> Preferences.pin("memory_123")
        |> Preferences.unpin("memory_123")

      refute "memory_123" in prefs.pinned_memories
    end

    test "pinned? returns correct status" do
      prefs =
        Preferences.new("agent_001")
        |> Preferences.pin("memory_123")

      assert Preferences.pinned?(prefs, "memory_123")
      refute Preferences.pinned?(prefs, "other_memory")
    end

    test "pin updates audit trail" do
      prefs = Preferences.new("agent_001")
      assert prefs.adjustment_count == 0
      assert prefs.last_adjusted_at == nil

      prefs = Preferences.pin(prefs, "mem_1")
      assert prefs.adjustment_count == 1
      assert %DateTime{} = prefs.last_adjusted_at
    end

    test "unpin updates audit trail" do
      prefs =
        Preferences.new("agent_001")
        |> Preferences.pin("mem_1")

      count_before = prefs.adjustment_count
      prefs = Preferences.unpin(prefs, "mem_1")
      assert prefs.adjustment_count == count_before + 1
    end

    test "pin with trust_tier uses tier max_pins" do
      prefs = Preferences.new("agent_001", max_pins: 200)

      # Probationary tier allows max 5 pins
      pinned =
        Enum.reduce(1..5, prefs, fn i, acc ->
          Preferences.pin(acc, "mem_#{i}", trust_tier: :probationary)
        end)

      assert length(pinned.pinned_memories) == 5

      result = Preferences.pin(pinned, "mem_6", trust_tier: :probationary)
      assert result == {:error, :max_pins_reached}
    end

    test "pin without trust_tier uses struct max_pins" do
      prefs = Preferences.new("agent_001", max_pins: 3)

      pinned =
        Enum.reduce(1..3, prefs, fn i, acc ->
          Preferences.pin(acc, "mem_#{i}")
        end)

      assert length(pinned.pinned_memories) == 3
      result = Preferences.pin(pinned, "mem_4")
      assert result == {:error, :max_pins_reached}
    end

    test "pin with untrusted tier allows 0 pins" do
      prefs = Preferences.new("agent_001")
      result = Preferences.pin(prefs, "mem_1", trust_tier: :untrusted)
      assert result == {:error, :max_pins_reached}
    end
  end

  describe "adjust/3 (backward compat)" do
    test "validates decay_rate range" do
      prefs = Preferences.new("agent_001")

      {:ok, updated} = Preferences.adjust(prefs, :decay_rate, 0.15)
      assert updated.decay_rate == 0.15

      assert {:error, {:out_of_range, :decay_rate, {0.01, 0.50}}} =
               Preferences.adjust(prefs, :decay_rate, 0.001)

      assert {:error, {:out_of_range, :decay_rate, {0.01, 0.50}}} =
               Preferences.adjust(prefs, :decay_rate, 0.75)
    end

    test "validates max_pins range" do
      prefs = Preferences.new("agent_001")

      {:ok, updated} = Preferences.adjust(prefs, :max_pins, 100)
      assert updated.max_pins == 100

      assert {:error, {:out_of_range, :max_pins, {1, 200}}} =
               Preferences.adjust(prefs, :max_pins, 0)

      assert {:error, {:out_of_range, :max_pins, {1, 200}}} =
               Preferences.adjust(prefs, :max_pins, 500)
    end

    test "truncates pinned_memories when max_pins is lowered" do
      prefs =
        Preferences.new("agent_001")
        |> Preferences.pin("mem_1")
        |> Preferences.pin("mem_2")
        |> Preferences.pin("mem_3")

      {:ok, updated} = Preferences.adjust(prefs, :max_pins, 2)
      assert length(updated.pinned_memories) == 2
    end

    test "validates retrieval_threshold range" do
      prefs = Preferences.new("agent_001")

      {:ok, updated} = Preferences.adjust(prefs, :retrieval_threshold, 0.5)
      assert updated.retrieval_threshold == 0.5

      {:ok, at_zero} = Preferences.adjust(prefs, :retrieval_threshold, 0.0)
      assert at_zero.retrieval_threshold == 0.0

      {:ok, at_one} = Preferences.adjust(prefs, :retrieval_threshold, 1.0)
      assert at_one.retrieval_threshold == 1.0

      assert {:error, {:out_of_range, :retrieval_threshold, {min, max}}} =
               Preferences.adjust(prefs, :retrieval_threshold, -0.1)

      assert min == 0.0
      assert max == 1.0

      assert {:error, {:out_of_range, :retrieval_threshold, _}} =
               Preferences.adjust(prefs, :retrieval_threshold, 1.5)
    end

    test "validates consolidation_interval range" do
      prefs = Preferences.new("agent_001")

      {:ok, updated} = Preferences.adjust(prefs, :consolidation_interval, 120_000)
      assert updated.consolidation_interval == 120_000

      assert {:error, {:out_of_range, :consolidation_interval, {60_000, 3_600_000}}} =
               Preferences.adjust(prefs, :consolidation_interval, 30_000)

      assert {:error, {:out_of_range, :consolidation_interval, {60_000, 3_600_000}}} =
               Preferences.adjust(prefs, :consolidation_interval, 5_000_000)
    end

    test "accepts attention_focus string or nil" do
      prefs = Preferences.new("agent_001")

      {:ok, updated} = Preferences.adjust(prefs, :attention_focus, "debugging")
      assert updated.attention_focus == "debugging"

      {:ok, cleared} = Preferences.adjust(prefs, :attention_focus, nil)
      assert cleared.attention_focus == nil
    end

    test "accepts type_quota tuple" do
      prefs = Preferences.new("agent_001")

      {:ok, updated} = Preferences.adjust(prefs, :type_quota, {:fact, 1000})
      assert updated.type_quotas[:fact] == 1000

      {:ok, unlimited} = Preferences.adjust(prefs, :type_quota, {:skill, :unlimited})
      assert unlimited.type_quotas[:skill] == :unlimited
    end

    test "rejects invalid quota values" do
      prefs = Preferences.new("agent_001")

      assert {:error, {:invalid_quota, :must_be_positive_or_unlimited}} =
               Preferences.adjust(prefs, :type_quota, {:fact, 0})

      assert {:error, {:invalid_quota, :must_be_positive_or_unlimited}} =
               Preferences.adjust(prefs, :type_quota, {:fact, -10})
    end

    test "rejects invalid param names" do
      prefs = Preferences.new("agent_001")

      assert {:error, {:invalid_param, :unknown}} =
               Preferences.adjust(prefs, :unknown, "value")
    end
  end

  describe "adjust/4 audit trail" do
    test "updates last_adjusted_at and increments adjustment_count" do
      prefs = Preferences.new("agent_001")
      assert prefs.adjustment_count == 0

      {:ok, updated} = Preferences.adjust(prefs, :decay_rate, 0.15)
      assert updated.adjustment_count == 1
      assert %DateTime{} = updated.last_adjusted_at
    end

    test "increments count on successive adjustments" do
      prefs = Preferences.new("agent_001")

      {:ok, p1} = Preferences.adjust(prefs, :decay_rate, 0.15)
      {:ok, p2} = Preferences.adjust(p1, :retrieval_threshold, 0.5)
      {:ok, p3} = Preferences.adjust(p2, :attention_focus, "testing")

      assert p3.adjustment_count == 3
    end

    test "context_preference adjustment updates audit trail" do
      prefs = Preferences.new("agent_001")
      {:ok, updated} = Preferences.adjust(prefs, :context_preference, {:include_goals, false})
      assert updated.adjustment_count == 1
      assert %DateTime{} = updated.last_adjusted_at
    end
  end

  describe "adjust/4 with trust_tier" do
    test "validates decay_rate against tier range" do
      prefs = Preferences.new("agent_001")

      # Trusted tier: decay range {0.05, 0.15}
      {:ok, updated} = Preferences.adjust(prefs, :decay_rate, 0.10, trust_tier: :trusted)
      assert updated.decay_rate == 0.10

      assert {:error, {:out_of_range, :decay_rate, {0.05, 0.15}}} =
               Preferences.adjust(prefs, :decay_rate, 0.03, trust_tier: :trusted)

      assert {:error, {:out_of_range, :decay_rate, {0.05, 0.15}}} =
               Preferences.adjust(prefs, :decay_rate, 0.20, trust_tier: :trusted)
    end

    test "probationary tier uses narrower decay range" do
      prefs = Preferences.new("agent_001")

      # Probationary: {0.08, 0.12}
      {:ok, _} = Preferences.adjust(prefs, :decay_rate, 0.10, trust_tier: :probationary)

      assert {:error, {:out_of_range, :decay_rate, {0.08, 0.12}}} =
               Preferences.adjust(prefs, :decay_rate, 0.05, trust_tier: :probationary)
    end

    test "untrusted tier has fixed decay rate" do
      prefs = Preferences.new("agent_001")

      # Untrusted: {0.10, 0.10} — only 0.10 is valid
      {:ok, updated} = Preferences.adjust(prefs, :decay_rate, 0.10, trust_tier: :untrusted)
      assert updated.decay_rate == 0.10

      assert {:error, {:out_of_range, :decay_rate, {0.10, 0.10}}} =
               Preferences.adjust(prefs, :decay_rate, 0.09, trust_tier: :untrusted)
    end

    test "without trust_tier uses global range (backward compat)" do
      prefs = Preferences.new("agent_001")

      # Global range: {0.01, 0.50}
      {:ok, updated} = Preferences.adjust(prefs, :decay_rate, 0.03)
      assert updated.decay_rate == 0.03
    end

    test "validates type_quota against tier quota_range" do
      prefs = Preferences.new("agent_001")

      # Trusted: quota_range {10, 35}
      {:ok, _} = Preferences.adjust(prefs, :type_quota, {:fact, 20}, trust_tier: :trusted)

      assert {:error, {:exceeds_max_quota, :fact}} =
               Preferences.adjust(prefs, :type_quota, {:fact, 40}, trust_tier: :trusted)

      assert {:error, {:below_min_quota, :fact}} =
               Preferences.adjust(prefs, :type_quota, {:fact, 5}, trust_tier: :trusted)
    end

    test "type_quota :unlimited bypasses tier range check" do
      prefs = Preferences.new("agent_001")

      {:ok, updated} =
        Preferences.adjust(prefs, :type_quota, {:fact, :unlimited}, trust_tier: :trusted)

      assert updated.type_quotas[:fact] == :unlimited
    end

    test "without trust_tier, type_quota has no range constraint" do
      prefs = Preferences.new("agent_001")

      # Without trust tier, any positive value is accepted
      {:ok, updated} = Preferences.adjust(prefs, :type_quota, {:fact, 1000})
      assert updated.type_quotas[:fact] == 1000
    end

    test "validates max_pins against tier max" do
      prefs = Preferences.new("agent_001")

      # Trusted: max_pins 15, so range is {1, 15}
      {:ok, updated} = Preferences.adjust(prefs, :max_pins, 10, trust_tier: :trusted)
      assert updated.max_pins == 10

      assert {:error, {:out_of_range, :max_pins, {1, 15}}} =
               Preferences.adjust(prefs, :max_pins, 20, trust_tier: :trusted)
    end

    test "veteran tier allows wider ranges" do
      prefs = Preferences.new("agent_001")

      # Veteran: decay {0.03, 0.20}, quota {5, 50}, max_pins 30
      {:ok, _} = Preferences.adjust(prefs, :decay_rate, 0.03, trust_tier: :veteran)
      {:ok, _} = Preferences.adjust(prefs, :type_quota, {:fact, 50}, trust_tier: :veteran)
      {:ok, _} = Preferences.adjust(prefs, :max_pins, 30, trust_tier: :veteran)
    end

    test "autonomous tier allows widest ranges" do
      prefs = Preferences.new("agent_001")

      # Autonomous: decay {0.01, 0.25}, quota {5, 60}, max_pins 50
      {:ok, _} = Preferences.adjust(prefs, :decay_rate, 0.01, trust_tier: :autonomous)
      {:ok, _} = Preferences.adjust(prefs, :type_quota, {:fact, 60}, trust_tier: :autonomous)
      {:ok, _} = Preferences.adjust(prefs, :max_pins, 50, trust_tier: :autonomous)
    end
  end

  describe "context_preferences" do
    test "set_context_preference updates a value" do
      prefs = Preferences.new("agent_001")

      {:ok, updated} = Preferences.set_context_preference(prefs, :include_goals, false)
      assert updated.context_preferences.include_goals == false
    end

    test "set_context_preference updates audit trail" do
      prefs = Preferences.new("agent_001")

      {:ok, updated} = Preferences.set_context_preference(prefs, :include_goals, false)
      assert updated.adjustment_count == 1
      assert %DateTime{} = updated.last_adjusted_at
    end

    test "get_context_preference returns existing value" do
      prefs = Preferences.new("agent_001")
      assert Preferences.get_context_preference(prefs, :include_goals) == true
      assert Preferences.get_context_preference(prefs, :max_context_nodes) == 50
    end

    test "get_context_preference returns default for missing key" do
      prefs = Preferences.new("agent_001")
      assert Preferences.get_context_preference(prefs, :nonexistent, :fallback) == :fallback
    end

    test "adjust with :context_preference works" do
      prefs = Preferences.new("agent_001")

      {:ok, updated} =
        Preferences.adjust(prefs, :context_preference, {:include_relationships, false})

      assert updated.context_preferences.include_relationships == false
    end

    test "set_context_preference adds custom keys" do
      prefs = Preferences.new("agent_001")

      {:ok, updated} = Preferences.set_context_preference(prefs, :custom_key, "custom_value")
      assert Preferences.get_context_preference(updated, :custom_key) == "custom_value"
    end
  end

  describe "bounds_for_tier/1" do
    test "returns bounds for valid tiers" do
      bounds = Preferences.bounds_for_tier(:trusted)
      assert bounds.decay_range == {0.05, 0.15}
      assert bounds.quota_range == {10, 35}
      assert bounds.max_pins == 15
      assert bounds.can_adjust == true
      assert bounds.can_pin == true
    end

    test "returns nil for unknown tier" do
      assert Preferences.bounds_for_tier(:invalid) == nil
    end

    test "untrusted tier has most restrictive bounds" do
      bounds = Preferences.bounds_for_tier(:untrusted)
      assert bounds.decay_range == {0.10, 0.10}
      assert bounds.quota_range == {20, 20}
      assert bounds.max_pins == 0
      assert bounds.can_adjust == false
      assert bounds.can_pin == false
    end

    test "higher tiers have progressively wider ranges" do
      prob = Preferences.bounds_for_tier(:probationary)
      trusted = Preferences.bounds_for_tier(:trusted)
      vet = Preferences.bounds_for_tier(:veteran)
      auto = Preferences.bounds_for_tier(:autonomous)

      assert prob.max_pins < trusted.max_pins
      assert trusted.max_pins < vet.max_pins
      assert vet.max_pins < auto.max_pins
    end
  end

  describe "valid_tiers/0" do
    test "returns list of all tier atoms" do
      tiers = Preferences.valid_tiers()
      assert :untrusted in tiers
      assert :probationary in tiers
      assert :trusted in tiers
      assert :veteran in tiers
      assert :autonomous in tiers
      assert length(tiers) == 5
    end
  end

  describe "inspect_preferences/1" do
    test "returns settings summary" do
      prefs =
        Preferences.new("agent_001")
        |> Preferences.pin("mem_1")
        |> Preferences.pin("mem_2")

      info = Preferences.inspect_preferences(prefs)

      assert info.agent_id == "agent_001"
      assert info.decay_rate == 0.10
      assert info.pinned_count == 2
      assert info.max_pins == 50
      assert info.pins_available == 48
      assert is_integer(info.consolidation_interval_minutes)
    end

    test "includes decay_interpretation" do
      prefs = Preferences.new("agent_001")
      info = Preferences.inspect_preferences(prefs)
      assert info.decay_interpretation == "Normal (balanced retention)"
    end

    test "includes context_preferences" do
      prefs = Preferences.new("agent_001")
      info = Preferences.inspect_preferences(prefs)
      assert is_map(info.context_preferences)
      assert info.context_preferences.include_goals == true
    end

    test "includes audit trail" do
      prefs = Preferences.new("agent_001")
      {:ok, prefs} = Preferences.adjust(prefs, :decay_rate, 0.15)

      info = Preferences.inspect_preferences(prefs)
      assert info.adjustment_count == 1
      assert %DateTime{} = info.last_adjusted_at
    end
  end

  describe "introspect/2" do
    test "returns trust-aware report for trusted tier" do
      prefs = Preferences.new("agent_001")
      report = Preferences.introspect(prefs, :trusted)

      assert report.agent_id == "agent_001"

      # Type quotas with range
      assert report.type_quotas.current == prefs.type_quotas
      assert report.type_quotas.allowed_range == {10, 35}
      assert report.type_quotas.can_adjust == true

      # Decay rate with range and interpretation
      assert report.decay_rate.current == 0.10
      assert report.decay_rate.allowed_range == {0.05, 0.15}
      assert report.decay_rate.interpretation == "Normal (balanced retention)"

      # Pinned memories with limits
      assert report.pinned_memories.count == 0
      assert report.pinned_memories.max_allowed == 15
      assert report.pinned_memories.can_pin == true
    end

    test "includes context_preferences" do
      prefs = Preferences.new("agent_001")
      report = Preferences.introspect(prefs, :trusted)
      assert is_map(report.context_preferences)
      assert report.context_preferences.include_goals == true
    end

    test "includes trust-arbor specific fields" do
      prefs = Preferences.new("agent_001", attention_focus: "testing")
      report = Preferences.introspect(prefs, :trusted)

      assert report.attention_focus == "testing"
      assert report.retrieval_threshold == 0.3
      assert report.consolidation_interval_minutes == 30
    end

    test "includes metadata with trust_tier" do
      prefs = Preferences.new("agent_001")
      report = Preferences.introspect(prefs, :trusted)

      assert report.metadata.trust_tier == :trusted
      assert report.metadata.adjustment_count == 0
      assert report.metadata.last_adjusted_at == nil
    end

    test "shows restricted ranges for untrusted tier" do
      prefs = Preferences.new("agent_001")
      report = Preferences.introspect(prefs, :untrusted)

      assert report.type_quotas.allowed_range == {20, 20}
      assert report.type_quotas.can_adjust == false
      assert report.decay_rate.allowed_range == {0.10, 0.10}
      assert report.pinned_memories.max_allowed == 0
      assert report.pinned_memories.can_pin == false
    end

    test "shows widest ranges for autonomous tier" do
      prefs = Preferences.new("agent_001")
      report = Preferences.introspect(prefs, :autonomous)

      assert report.type_quotas.allowed_range == {5, 60}
      assert report.decay_rate.allowed_range == {0.01, 0.25}
      assert report.pinned_memories.max_allowed == 50
    end

    test "reflects current pinned count" do
      prefs =
        Preferences.new("agent_001")
        |> Preferences.pin("mem_1")
        |> Preferences.pin("mem_2")

      report = Preferences.introspect(prefs, :trusted)
      assert report.pinned_memories.count == 2
      assert "mem_1" in report.pinned_memories.ids
      assert "mem_2" in report.pinned_memories.ids
    end
  end

  describe "serialization" do
    test "serialize/deserialize round-trip" do
      prefs =
        Preferences.new("agent_001")
        |> Preferences.pin("mem_1")
        |> Preferences.pin("mem_2")

      {:ok, prefs} = Preferences.adjust(prefs, :decay_rate, 0.2)
      {:ok, prefs} = Preferences.adjust(prefs, :attention_focus, "testing")
      {:ok, prefs} = Preferences.adjust(prefs, :type_quota, {:fact, 1000})

      serialized = Preferences.serialize(prefs)
      deserialized = Preferences.deserialize(serialized)

      assert deserialized.agent_id == prefs.agent_id
      assert deserialized.decay_rate == prefs.decay_rate
      assert deserialized.pinned_memories == prefs.pinned_memories
      assert deserialized.attention_focus == prefs.attention_focus
      assert deserialized.type_quotas[:fact] == 1000
    end

    test "deserialize handles :unlimited quota" do
      serialized = %{
        "agent_id" => "test",
        "type_quotas" => %{"relationship" => "unlimited"}
      }

      prefs = Preferences.deserialize(serialized)
      assert prefs.type_quotas[:relationship] == :unlimited
    end

    test "serialize/deserialize round-trip preserves audit trail" do
      prefs = Preferences.new("agent_001")
      {:ok, prefs} = Preferences.adjust(prefs, :decay_rate, 0.15)
      {:ok, prefs} = Preferences.adjust(prefs, :retrieval_threshold, 0.5)

      serialized = Preferences.serialize(prefs)
      deserialized = Preferences.deserialize(serialized)

      assert deserialized.adjustment_count == 2
      assert %DateTime{} = deserialized.last_adjusted_at
    end

    test "serialize/deserialize round-trip preserves context_preferences" do
      prefs = Preferences.new("agent_001")
      {:ok, prefs} = Preferences.set_context_preference(prefs, :include_goals, false)
      {:ok, prefs} = Preferences.set_context_preference(prefs, :max_context_nodes, 30)

      serialized = Preferences.serialize(prefs)
      deserialized = Preferences.deserialize(serialized)

      assert deserialized.context_preferences.include_goals == false
      assert deserialized.context_preferences.max_context_nodes == 30
    end

    test "deserialize handles missing new fields with defaults" do
      # Simulate old serialized data without new fields
      old_data = %{
        "agent_id" => "old_agent",
        "decay_rate" => 0.10,
        "type_quotas" => %{"fact" => 500},
        "pinned_memories" => [],
        "max_pins" => 50,
        "retrieval_threshold" => 0.3,
        "consolidation_interval" => 1_800_000
      }

      prefs = Preferences.deserialize(old_data)

      assert prefs.agent_id == "old_agent"
      assert prefs.context_preferences.include_goals == true
      assert prefs.context_preferences.max_context_nodes == 50
      assert prefs.last_adjusted_at == nil
      assert prefs.adjustment_count == 0
    end
  end
end
