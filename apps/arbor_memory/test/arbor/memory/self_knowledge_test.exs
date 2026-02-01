defmodule Arbor.Memory.SelfKnowledgeTest do
  use ExUnit.Case, async: true

  alias Arbor.Memory.SelfKnowledge

  @moduletag :fast

  describe "new/2" do
    test "creates with agent_id" do
      sk = SelfKnowledge.new("agent_001")

      assert sk.agent_id == "agent_001"
      assert sk.capabilities == []
      assert sk.personality_traits == []
      assert sk.values == []
      assert sk.preferences == []
      assert sk.growth_log == []
      assert sk.architecture == %{}
      assert sk.version == 1
      assert sk.version_history == []
    end

    test "accepts initial options" do
      sk =
        SelfKnowledge.new("agent_001",
          architecture: %{memory_system: "arbor_memory"}
        )

      assert sk.architecture == %{memory_system: "arbor_memory"}
    end
  end

  describe "capabilities" do
    test "add_capability creates new capability" do
      sk =
        SelfKnowledge.new("agent_001")
        |> SelfKnowledge.add_capability("elixir", 0.8, "multiple projects")

      assert length(sk.capabilities) == 1
      [cap] = sk.capabilities
      assert cap.name == "elixir"
      assert cap.proficiency == 0.8
      assert cap.evidence == "multiple projects"
      assert cap.added_at != nil
    end

    test "add_capability replaces existing capability" do
      sk =
        SelfKnowledge.new("agent_001")
        |> SelfKnowledge.add_capability("elixir", 0.6)
        |> SelfKnowledge.add_capability("elixir", 0.9, "improved")

      assert length(sk.capabilities) == 1
      [cap] = sk.capabilities
      assert cap.proficiency == 0.9
      assert cap.evidence == "improved"
    end

    test "add_capability clamps proficiency to 0.0-1.0" do
      sk =
        SelfKnowledge.new("agent_001")
        |> SelfKnowledge.add_capability("over", 1.5)
        |> SelfKnowledge.add_capability("under", -0.5)

      over_cap = Enum.find(sk.capabilities, &(&1.name == "over"))
      under_cap = Enum.find(sk.capabilities, &(&1.name == "under"))
      assert over_cap.proficiency == 1.0
      assert under_cap.proficiency == 0.0
    end

    test "update_capability updates proficiency" do
      sk =
        SelfKnowledge.new("agent_001")
        |> SelfKnowledge.add_capability("elixir", 0.6)
        |> SelfKnowledge.update_capability("elixir", proficiency: 0.9)

      [cap] = sk.capabilities
      assert cap.proficiency == 0.9
    end

    test "get_capabilities with proficiency filter" do
      sk =
        SelfKnowledge.new("agent_001")
        |> SelfKnowledge.add_capability("beginner", 0.3)
        |> SelfKnowledge.add_capability("expert", 0.9)
        |> SelfKnowledge.add_capability("intermediate", 0.6)

      expert_caps = SelfKnowledge.get_capabilities(sk, min_proficiency: 0.8)
      assert length(expert_caps) == 1
      assert hd(expert_caps).name == "expert"

      mid_caps = SelfKnowledge.get_capabilities(sk, min_proficiency: 0.5, max_proficiency: 0.7)
      assert length(mid_caps) == 1
      assert hd(mid_caps).name == "intermediate"
    end
  end

  describe "personality traits and values" do
    test "add_trait creates new trait" do
      sk =
        SelfKnowledge.new("agent_001")
        |> SelfKnowledge.add_trait(:curious, 0.9, "asks many questions")

      assert length(sk.personality_traits) == 1
      [trait] = sk.personality_traits
      assert trait.trait == :curious
      assert trait.strength == 0.9
      assert trait.evidence == "asks many questions"
    end

    test "add_trait replaces existing trait" do
      sk =
        SelfKnowledge.new("agent_001")
        |> SelfKnowledge.add_trait(:curious, 0.5)
        |> SelfKnowledge.add_trait(:curious, 0.9, "more evidence")

      assert length(sk.personality_traits) == 1
      [trait] = sk.personality_traits
      assert trait.strength == 0.9
    end

    test "add_value creates new value" do
      sk =
        SelfKnowledge.new("agent_001")
        |> SelfKnowledge.add_value(:honesty, 0.95, "core principle")

      assert length(sk.values) == 1
      [value] = sk.values
      assert value.value == :honesty
      assert value.importance == 0.95
      assert value.evidence == "core principle"
    end

    test "add_value clamps importance" do
      sk =
        SelfKnowledge.new("agent_001")
        |> SelfKnowledge.add_value(:test, 1.5)

      [value] = sk.values
      assert value.importance == 1.0
    end
  end

  describe "growth tracking" do
    test "record_growth adds entry" do
      sk =
        SelfKnowledge.new("agent_001")
        |> SelfKnowledge.record_growth(:debugging, "improved by 20%")

      assert length(sk.growth_log) == 1
      [entry] = sk.growth_log
      assert entry.area == :debugging
      assert entry.change == "improved by 20%"
      assert entry.timestamp != nil
    end

    test "growth_log is capped at 100 entries" do
      sk = SelfKnowledge.new("agent_001")

      sk =
        Enum.reduce(1..110, sk, fn i, acc ->
          SelfKnowledge.record_growth(acc, :area, "change #{i}")
        end)

      assert length(sk.growth_log) == 100
      # Most recent should be first
      assert hd(sk.growth_log).change == "change 110"
    end

    test "growth_summary groups by area" do
      sk =
        SelfKnowledge.new("agent_001")
        |> SelfKnowledge.record_growth(:coding, "learned elixir")
        |> SelfKnowledge.record_growth(:coding, "learned OTP")
        |> SelfKnowledge.record_growth(:writing, "improved docs")

      summary = SelfKnowledge.growth_summary(sk)

      assert length(summary[:coding]) == 2
      assert length(summary[:writing]) == 1
    end
  end

  describe "query/2" do
    test "query :identity returns traits and values" do
      sk =
        SelfKnowledge.new("agent_001")
        |> SelfKnowledge.add_trait(:curious, 0.8)
        |> SelfKnowledge.add_value(:honesty, 0.9)

      result = SelfKnowledge.query(sk, :identity)

      assert result.agent_id == "agent_001"
      assert result.traits == [{:curious, 0.8}]
      assert result.values == [{:honesty, 0.9}]
    end

    test "query :capabilities returns skills" do
      sk =
        SelfKnowledge.new("agent_001")
        |> SelfKnowledge.add_capability("elixir", 0.8)

      result = SelfKnowledge.query(sk, :capabilities)

      assert result.capabilities == [{"elixir", 0.8}]
    end

    test "query :cognition returns preferences" do
      sk =
        SelfKnowledge.new("agent_001")
        |> SelfKnowledge.add_preference(:concise, 0.7)

      result = SelfKnowledge.query(sk, :cognition)

      assert result.preferences == [{:concise, 0.7}]
    end

    test "query :all returns everything" do
      sk = SelfKnowledge.new("agent_001")
      result = SelfKnowledge.query(sk, :all)

      assert result.agent_id == "agent_001"
      assert is_list(result.capabilities)
      assert is_list(result.personality_traits)
      assert is_list(result.values)
    end

    test "query unknown aspect returns empty map" do
      sk = SelfKnowledge.new("agent_001")
      result = SelfKnowledge.query(sk, :unknown)
      assert result == %{}
    end
  end

  describe "versioning" do
    test "snapshot saves current state" do
      sk =
        SelfKnowledge.new("agent_001")
        |> SelfKnowledge.add_trait(:curious, 0.8)
        |> SelfKnowledge.snapshot()

      assert sk.version == 2
      assert length(sk.version_history) == 1
      [snapshot] = sk.version_history
      assert snapshot.version == 1
    end

    test "rollback restores previous state" do
      sk =
        SelfKnowledge.new("agent_001")
        |> SelfKnowledge.add_trait(:curious, 0.8)
        |> SelfKnowledge.snapshot()
        |> SelfKnowledge.add_trait(:methodical, 0.9)

      assert length(sk.personality_traits) == 2

      sk = SelfKnowledge.rollback(sk, :previous)

      assert length(sk.personality_traits) == 1
      assert hd(sk.personality_traits).trait == :curious
      assert sk.version == 1
    end

    test "rollback returns error when no history" do
      sk = SelfKnowledge.new("agent_001")
      result = SelfKnowledge.rollback(sk, :previous)
      assert result == {:error, :no_history}
    end

    test "version_history max 10" do
      sk = SelfKnowledge.new("agent_001")

      sk =
        Enum.reduce(1..15, sk, fn _i, acc ->
          SelfKnowledge.snapshot(acc)
        end)

      assert length(sk.version_history) == 10
    end
  end

  describe "serialization" do
    test "summarize produces readable text" do
      sk =
        SelfKnowledge.new("agent_001")
        |> SelfKnowledge.add_capability("elixir", 0.8)
        |> SelfKnowledge.add_trait(:curious, 0.9)
        |> SelfKnowledge.add_value(:honesty, 0.95)

      summary = SelfKnowledge.summarize(sk)

      assert String.contains?(summary, "agent_001")
      assert String.contains?(summary, "elixir")
      assert String.contains?(summary, "curious")
      assert String.contains?(summary, "honesty")
    end

    test "serialize/deserialize round-trip" do
      sk =
        SelfKnowledge.new("agent_001")
        |> SelfKnowledge.add_capability("elixir", 0.8, "evidence")
        |> SelfKnowledge.add_trait(:curious, 0.9, "asks questions")
        |> SelfKnowledge.add_value(:honesty, 0.95)
        |> SelfKnowledge.add_preference(:concise, 0.7)
        |> SelfKnowledge.record_growth(:coding, "improved")

      serialized = SelfKnowledge.serialize(sk)
      deserialized = SelfKnowledge.deserialize(serialized)

      assert deserialized.agent_id == sk.agent_id
      assert length(deserialized.capabilities) == length(sk.capabilities)
      assert length(deserialized.personality_traits) == length(sk.personality_traits)
      assert length(deserialized.values) == length(sk.values)
      assert length(deserialized.preferences) == length(sk.preferences)
      assert length(deserialized.growth_log) == length(sk.growth_log)
    end
  end
end
