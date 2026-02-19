defmodule Arbor.Agent.Templates.DiagnosticianTest do
  use ExUnit.Case, async: true

  alias Arbor.Agent.Character
  alias Arbor.Agent.Templates.Diagnostician

  describe "Template behaviour implementation" do
    test "implements all required callbacks" do
      Code.ensure_loaded!(Diagnostician)
      assert function_exported?(Diagnostician, :character, 0)
      assert function_exported?(Diagnostician, :trust_tier, 0)
      assert function_exported?(Diagnostician, :initial_goals, 0)
      assert function_exported?(Diagnostician, :required_capabilities, 0)
    end

    test "implements optional callbacks" do
      assert function_exported?(Diagnostician, :description, 0)
      assert function_exported?(Diagnostician, :metadata, 0)
    end
  end

  describe "character/0" do
    test "returns a valid Character struct" do
      char = Diagnostician.character()
      assert %Character{} = char
      assert char.name == "Diagnostician"
      assert char.role == "BEAM SRE / Runtime Diagnostician"
    end

    test "has analytical personality traits" do
      char = Diagnostician.character()
      assert length(char.traits) == 3

      trait_names = Enum.map(char.traits, & &1.name)
      assert "analytical" in trait_names
      assert "systematic" in trait_names
      assert "cautious" in trait_names

      # Analytical should be high intensity
      analytical = Enum.find(char.traits, &(&1.name == "analytical"))
      assert analytical.intensity >= 0.8
    end

    test "values reliability, safety, and transparency" do
      char = Diagnostician.character()
      assert "reliability" in char.values
      assert "safety" in char.values
      assert "transparency" in char.values
    end

    test "has clinical tone and structured style" do
      char = Diagnostician.character()
      assert char.tone == "clinical"
      assert char.style =~ "Structured"
    end

    test "has BEAM runtime knowledge" do
      char = Diagnostician.character()
      assert length(char.knowledge) >= 3

      categories = Enum.map(char.knowledge, & &1.category)
      assert "runtime" in categories
      assert "supervision" in categories
    end

    test "instructions emphasize evidence-based diagnosis" do
      char = Diagnostician.character()
      assert length(char.instructions) >= 4

      instructions_text = Enum.join(char.instructions, " ")
      assert instructions_text =~ "Monitor"
      assert instructions_text =~ "governance"
    end

    test "renders to valid system prompt" do
      prompt = Diagnostician.character() |> Character.to_system_prompt()
      assert prompt =~ "# Character: Diagnostician"
      assert prompt =~ "## Identity"
      assert prompt =~ "## Personality"
      assert prompt =~ "## Knowledge"
      assert prompt =~ "## Instructions"
    end
  end

  describe "trust_tier/0" do
    test "returns :established" do
      assert Diagnostician.trust_tier() == :established
    end
  end

  describe "initial_goals/0" do
    test "has three goals" do
      goals = Diagnostician.initial_goals()
      assert length(goals) == 3
    end

    test "goals are well-formed maps" do
      goals = Diagnostician.initial_goals()
      assert Enum.all?(goals, &is_map/1)
      assert Enum.all?(goals, &Map.has_key?(&1, :type))
      assert Enum.all?(goals, &Map.has_key?(&1, :description))
    end

    test "includes maintain goal for health monitoring" do
      goals = Diagnostician.initial_goals()
      maintain_goals = Enum.filter(goals, &(&1.type == :maintain))
      assert maintain_goals != []

      descriptions = Enum.map(maintain_goals, & &1.description)
      assert Enum.any?(descriptions, &(&1 =~ "health" or &1 =~ "Monitor"))
    end

    test "includes achieve goals for diagnosis and proposals" do
      goals = Diagnostician.initial_goals()
      achieve_goals = Enum.filter(goals, &(&1.type == :achieve))
      # Need at least 2 achieve goals
      assert [_ | [_ | _]] = achieve_goals

      descriptions = Enum.map(achieve_goals, & &1.description)
      assert Enum.any?(descriptions, &(&1 =~ "Diagnose" or &1 =~ "root cause"))
      assert Enum.any?(descriptions, &(&1 =~ "Propose" or &1 =~ "governance"))
    end
  end

  describe "required_capabilities/0" do
    test "includes monitor read access" do
      caps = Diagnostician.required_capabilities()
      resources = Enum.map(caps, & &1.resource)
      assert Enum.any?(resources, &(&1 =~ "monitor.read"))
    end

    test "includes AI analysis capability" do
      caps = Diagnostician.required_capabilities()
      resources = Enum.map(caps, & &1.resource)
      assert Enum.any?(resources, &(&1 =~ "ai.analyze"))
    end

    test "includes proposal submission capability" do
      caps = Diagnostician.required_capabilities()
      resources = Enum.map(caps, & &1.resource)
      assert Enum.any?(resources, &(&1 =~ "proposal.submit"))
    end

    test "includes code hot load capability" do
      caps = Diagnostician.required_capabilities()
      resources = Enum.map(caps, & &1.resource)
      assert Enum.any?(resources, &(&1 =~ "code.hot_load"))
    end

    test "includes file read/write capabilities" do
      caps = Diagnostician.required_capabilities()
      resources = Enum.map(caps, & &1.resource)
      assert Enum.any?(resources, &(&1 =~ "file.read"))
      assert Enum.any?(resources, &(&1 =~ "file.write"))
    end

    test "all capabilities use canonical URI format" do
      caps = Diagnostician.required_capabilities()

      Enum.each(caps, fn cap ->
        assert cap.resource =~ "arbor://actions/execute/",
               "Expected canonical URI, got: #{cap.resource}"
      end)
    end
  end

  describe "description/0" do
    test "returns a non-empty string" do
      desc = Diagnostician.description()
      assert is_binary(desc)
      assert String.length(desc) > 20
    end

    test "mentions key concepts" do
      desc = Diagnostician.description()
      assert desc =~ "BEAM" or desc =~ "runtime" or desc =~ "SRE"
      assert desc =~ "diagnos" or desc =~ "anomal"
    end
  end

  describe "metadata/0" do
    test "includes version" do
      meta = Diagnostician.metadata()
      assert Map.has_key?(meta, :version)
    end

    test "is demo compatible" do
      meta = Diagnostician.metadata()
      assert meta[:demo_compatible] == true
    end

    test "category is operations" do
      meta = Diagnostician.metadata()
      assert meta[:category] == :operations
    end
  end
end
