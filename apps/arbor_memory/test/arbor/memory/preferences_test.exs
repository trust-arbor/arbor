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
  end

  describe "adjust/3" do
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
  end
end
