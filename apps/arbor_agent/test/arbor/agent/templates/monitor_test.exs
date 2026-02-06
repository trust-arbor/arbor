defmodule Arbor.Agent.Templates.MonitorTest do
  use ExUnit.Case, async: true

  alias Arbor.Agent.Character
  alias Arbor.Agent.Templates.Monitor

  describe "Template behaviour implementation" do
    test "implements all required callbacks" do
      Code.ensure_loaded!(Monitor)
      assert function_exported?(Monitor, :character, 0)
      assert function_exported?(Monitor, :trust_tier, 0)
      assert function_exported?(Monitor, :initial_goals, 0)
      assert function_exported?(Monitor, :required_capabilities, 0)
    end

    test "implements optional callbacks" do
      assert function_exported?(Monitor, :description, 0)
      assert function_exported?(Monitor, :metadata, 0)
    end
  end

  describe "character/0" do
    test "returns a valid Character struct" do
      char = Monitor.character()
      assert %Character{} = char
      assert char.name == "Sentinel"
      assert char.role == "BEAM Runtime Sentinel / Watchdog"
    end

    test "has vigilant personality traits" do
      char = Monitor.character()
      assert length(char.traits) == 3

      trait_names = Enum.map(char.traits, & &1.name)
      assert "vigilant" in trait_names
      assert "analytical" in trait_names
      assert "precise" in trait_names

      # Vigilant should be highest intensity
      vigilant = Enum.find(char.traits, &(&1.name == "vigilant"))
      assert vigilant.intensity >= 0.9
    end

    test "values reliability and early warning" do
      char = Monitor.character()
      assert "reliability" in char.values
      assert "early_warning" in char.values
    end

    test "has alert tone" do
      char = Monitor.character()
      assert char.tone == "alert"
    end

    test "has BEAM runtime knowledge" do
      char = Monitor.character()
      assert length(char.knowledge) >= 3

      categories = Enum.map(char.knowledge, & &1.category)
      assert "runtime" in categories
      assert "supervision" in categories
    end

    test "instructions emphasize monitoring and escalation" do
      char = Monitor.character()
      assert length(char.instructions) >= 4

      instructions_text = Enum.join(char.instructions, " ")
      assert instructions_text =~ "Monitor"
      assert instructions_text =~ "anomal"
      assert instructions_text =~ "Escalate"
    end

    test "renders to valid system prompt" do
      prompt = Monitor.character() |> Character.to_system_prompt()
      assert prompt =~ "# Character: Sentinel"
      assert prompt =~ "## Identity"
      assert prompt =~ "## Personality"
      assert prompt =~ "## Knowledge"
      assert prompt =~ "## Instructions"
    end
  end

  describe "trust_tier/0" do
    test "returns :probationary" do
      assert Monitor.trust_tier() == :probationary
    end
  end

  describe "initial_goals/0" do
    test "has three goals" do
      goals = Monitor.initial_goals()
      assert length(goals) == 3
    end

    test "goals are well-formed maps" do
      goals = Monitor.initial_goals()
      assert Enum.all?(goals, &is_map/1)
      assert Enum.all?(goals, &Map.has_key?(&1, :type))
      assert Enum.all?(goals, &Map.has_key?(&1, :description))
    end

    test "includes maintain goal for health monitoring" do
      goals = Monitor.initial_goals()
      maintain_goals = Enum.filter(goals, &(&1.type == :maintain))
      assert maintain_goals != []

      descriptions = Enum.map(maintain_goals, & &1.description)
      assert Enum.any?(descriptions, &(&1 =~ "monitor" or &1 =~ "Monitor" or &1 =~ "health"))
    end

    test "includes achieve goals for detection and escalation" do
      goals = Monitor.initial_goals()
      achieve_goals = Enum.filter(goals, &(&1.type == :achieve))
      assert [_ | [_ | _]] = achieve_goals

      descriptions = Enum.map(achieve_goals, & &1.description)
      assert Enum.any?(descriptions, &(&1 =~ "Detect" or &1 =~ "anomal"))
      assert Enum.any?(descriptions, &(&1 =~ "Escalate" or &1 =~ "DebugAgent"))
    end
  end

  describe "required_capabilities/0" do
    test "includes monitor read access" do
      caps = Monitor.required_capabilities()
      resources = Enum.map(caps, & &1.resource)
      assert Enum.any?(resources, &(&1 =~ "monitor"))
    end

    test "includes signal emit capability" do
      caps = Monitor.required_capabilities()
      resources = Enum.map(caps, & &1.resource)
      assert Enum.any?(resources, &(&1 =~ "signals/emit"))
    end

    test "includes signal subscribe capability" do
      caps = Monitor.required_capabilities()
      resources = Enum.map(caps, & &1.resource)
      assert Enum.any?(resources, &(&1 =~ "signals/subscribe"))
    end
  end

  describe "description/0" do
    test "returns a non-empty string" do
      desc = Monitor.description()
      assert is_binary(desc)
      assert String.length(desc) > 20
    end

    test "mentions key concepts" do
      desc = Monitor.description()
      assert desc =~ "BEAM" or desc =~ "runtime" or desc =~ "monitor"
      assert desc =~ "anomal" or desc =~ "detect"
    end
  end

  describe "metadata/0" do
    test "includes version" do
      meta = Monitor.metadata()
      assert Map.has_key?(meta, :version)
    end

    test "is demo compatible" do
      meta = Monitor.metadata()
      assert meta[:demo_compatible] == true
    end

    test "category is operations" do
      meta = Monitor.metadata()
      assert meta[:category] == :operations
    end
  end
end
