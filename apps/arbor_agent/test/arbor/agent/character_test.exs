defmodule Arbor.Agent.CharacterTest do
  use ExUnit.Case, async: true

  alias Arbor.Agent.Character

  describe "new/1" do
    test "creates character from keyword list with required name" do
      char = Character.new(name: "Scout")
      assert char.name == "Scout"
      assert char.traits == []
      assert char.values == []
      assert char.knowledge == []
      assert char.instructions == []
    end

    test "creates character with all fields" do
      char =
        Character.new(
          name: "Researcher",
          description: "A careful analyst",
          role: "Code researcher",
          background: "Experienced in Elixir/OTP",
          traits: [%{name: "curious", intensity: 0.9}],
          values: ["accuracy", "thoroughness"],
          quirks: ["Uses bullet points everywhere"],
          tone: "analytical",
          style: "Clear and structured",
          knowledge: [%{content: "Expert in Elixir", category: "skills"}],
          instructions: ["Read before suggesting"]
        )

      assert char.name == "Researcher"
      assert char.description == "A careful analyst"
      assert char.role == "Code researcher"
      assert char.background == "Experienced in Elixir/OTP"
      assert length(char.traits) == 1
      assert length(char.values) == 2
      assert length(char.quirks) == 1
      assert char.tone == "analytical"
      assert char.style == "Clear and structured"
      assert length(char.knowledge) == 1
      assert length(char.instructions) == 1
    end

    test "creates character from map" do
      char = Character.new(%{name: "Scout", tone: "concise"})
      assert char.name == "Scout"
      assert char.tone == "concise"
    end

    test "raises on missing name" do
      assert_raise ArgumentError, fn ->
        Character.new(description: "No name given")
      end
    end
  end

  describe "to_system_prompt/1" do
    test "renders minimal character (name only)" do
      char = Character.new(name: "Scout")
      prompt = Character.to_system_prompt(char)

      assert prompt =~ "# Character: Scout"
      refute prompt =~ "## Identity"
      refute prompt =~ "## Personality"
      refute prompt =~ "## Voice"
      refute prompt =~ "## Knowledge"
      refute prompt =~ "## Instructions"
    end

    test "renders header with description" do
      char = Character.new(name: "Scout", description: "A fast explorer")
      prompt = Character.to_system_prompt(char)

      assert prompt =~ "# Character: Scout"
      assert prompt =~ "A fast explorer"
    end

    test "renders identity section" do
      char = Character.new(name: "Agent", role: "Analyst", background: "10 years experience")
      prompt = Character.to_system_prompt(char)

      assert prompt =~ "## Identity"
      assert prompt =~ "**Role:** Analyst"
      assert prompt =~ "**Background:** 10 years experience"
    end

    test "renders personality with traits at different intensities" do
      char =
        Character.new(
          name: "Agent",
          traits: [
            %{name: "curious", intensity: 0.9},
            %{name: "cautious", intensity: 0.5},
            %{name: "shy", intensity: 0.2}
          ],
          values: ["accuracy"],
          quirks: ["Hums while thinking"]
        )

      prompt = Character.to_system_prompt(char)

      assert prompt =~ "## Personality"
      assert prompt =~ "**curious** (high)"
      assert prompt =~ "**cautious** (moderate)"
      assert prompt =~ "**shy** (low)"
      assert prompt =~ "accuracy"
      assert prompt =~ "Hums while thinking"
    end

    test "renders voice section" do
      char = Character.new(name: "Agent", tone: "concise", style: "No fluff")
      prompt = Character.to_system_prompt(char)

      assert prompt =~ "## Voice"
      assert prompt =~ "**Tone:** concise"
      assert prompt =~ "**Style:** No fluff"
    end

    test "renders knowledge with categories" do
      char =
        Character.new(
          name: "Agent",
          knowledge: [
            %{content: "Expert in Elixir", category: "skills"},
            %{content: "General info"}
          ]
        )

      prompt = Character.to_system_prompt(char)

      assert prompt =~ "## Knowledge"
      assert prompt =~ "[skills] Expert in Elixir"
      assert prompt =~ "- General info"
    end

    test "renders instructions" do
      char =
        Character.new(
          name: "Agent",
          instructions: ["Read before changing", "Cite file:line references"]
        )

      prompt = Character.to_system_prompt(char)

      assert prompt =~ "## Instructions"
      assert prompt =~ "- Read before changing"
      assert prompt =~ "- Cite file:line references"
    end

    test "renders full character with all sections" do
      char =
        Character.new(
          name: "Researcher",
          description: "A methodical explorer",
          role: "Code analyst",
          background: "Elixir expert",
          traits: [%{name: "curious", intensity: 0.9}],
          values: ["accuracy"],
          quirks: ["Uses headings"],
          tone: "analytical",
          style: "Structured",
          knowledge: [%{content: "OTP patterns", category: "skills"}],
          instructions: ["Read first"]
        )

      prompt = Character.to_system_prompt(char)

      assert prompt =~ "# Character: Researcher"
      assert prompt =~ "## Identity"
      assert prompt =~ "## Personality"
      assert prompt =~ "## Voice"
      assert prompt =~ "## Knowledge"
      assert prompt =~ "## Instructions"
    end
  end

  describe "to_map/1 and from_map/1" do
    test "round-trips through map" do
      original =
        Character.new(
          name: "Scout",
          description: "Fast explorer",
          role: "Explorer",
          traits: [%{name: "efficient", intensity: 0.9}],
          values: ["speed"],
          tone: "concise"
        )

      map = Character.to_map(original)
      assert is_map(map)
      assert map.name == "Scout"

      restored = Character.from_map(map)
      assert restored.name == original.name
      assert restored.description == original.description
      assert restored.role == original.role
      assert restored.tone == original.tone
      assert restored.traits == original.traits
      assert restored.values == original.values
    end

    test "from_map handles string keys" do
      map = %{
        "name" => "Scout",
        "description" => "Fast",
        "traits" => [%{"name" => "efficient", "intensity" => 0.9}]
      }

      char = Character.from_map(map)
      assert char.name == "Scout"
      assert char.description == "Fast"
      assert length(char.traits) == 1
    end
  end
end
