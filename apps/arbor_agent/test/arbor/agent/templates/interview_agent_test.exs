defmodule Arbor.Agent.Templates.InterviewAgentTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Agent.Character
  alias Arbor.Agent.Template
  alias Arbor.Agent.Templates.InterviewAgent

  describe "Template behaviour implementation" do
    test "implements all required callbacks" do
      Code.ensure_loaded!(InterviewAgent)
      assert function_exported?(InterviewAgent, :character, 0)
      assert function_exported?(InterviewAgent, :trust_tier, 0)
      assert function_exported?(InterviewAgent, :initial_goals, 0)
      assert function_exported?(InterviewAgent, :required_capabilities, 0)
    end

    test "implements optional callbacks" do
      assert function_exported?(InterviewAgent, :description, 0)
      assert function_exported?(InterviewAgent, :nature, 0)
      assert function_exported?(InterviewAgent, :values, 0)
      assert function_exported?(InterviewAgent, :domain_context, 0)
    end
  end

  describe "character/0" do
    test "returns a valid Character struct" do
      char = InterviewAgent.character()
      assert %Character{} = char
      assert char.name == "Trust Interview Agent"
      assert char.role == "Trust mediator and relationship facilitator"
    end

    test "has empathetic and security-conscious traits" do
      char = InterviewAgent.character()
      trait_names = Enum.map(char.traits, & &1.name)
      assert "empathetic" in trait_names
      assert "security-conscious" in trait_names
      assert "clear-communicator" in trait_names
    end

    test "values human agency and informed consent" do
      char = InterviewAgent.character()
      assert "human agency" in char.values
      assert "informed consent" in char.values
    end

    test "has warm but precise tone" do
      char = InterviewAgent.character()
      assert char.tone == "warm but precise"
    end

    test "instructions cover onboarding and JIT decisions" do
      char = InterviewAgent.character()
      instructions_text = Enum.join(char.instructions, " ")
      assert instructions_text =~ "onboarding"
      assert instructions_text =~ "ProposeProfile"
      assert instructions_text =~ "ApplyProfile"
      assert instructions_text =~ "confirm"
    end

    test "renders to valid system prompt" do
      prompt = InterviewAgent.character() |> Character.to_system_prompt()
      assert prompt =~ "# Character: Trust Interview Agent"
      assert prompt =~ "## Identity"
      assert prompt =~ "## Personality"
    end
  end

  describe "trust_tier/0" do
    test "returns :trusted" do
      assert InterviewAgent.trust_tier() == :trusted
    end
  end

  describe "initial_goals/0" do
    test "has two maintain goals" do
      goals = InterviewAgent.initial_goals()
      assert length(goals) == 2
      assert Enum.all?(goals, &(&1.type == :maintain))
    end

    test "goals cover trust profiles and trust boundaries" do
      goals = InterviewAgent.initial_goals()
      descriptions = Enum.map(goals, & &1.description)
      assert Enum.any?(descriptions, &(&1 =~ "trust profile"))
      assert Enum.any?(descriptions, &(&1 =~ "trust boundar"))
    end
  end

  describe "required_capabilities/0" do
    test "has exactly 6 trust action capabilities" do
      caps = InterviewAgent.required_capabilities()
      assert length(caps) == 6
    end

    test "all capabilities are trust actions only" do
      caps = InterviewAgent.required_capabilities()
      resources = Enum.map(caps, & &1.resource)

      Enum.each(resources, fn uri ->
        assert uri =~ "arbor://actions/execute/trust.",
               "Expected trust action URI, got: #{uri}"
      end)
    end

    test "includes read, propose, apply, explain, list_presets, list_agents" do
      caps = InterviewAgent.required_capabilities()
      resources = Enum.map(caps, & &1.resource)

      assert Enum.any?(resources, &(&1 =~ "read_profile"))
      assert Enum.any?(resources, &(&1 =~ "propose_profile"))
      assert Enum.any?(resources, &(&1 =~ "apply_profile"))
      assert Enum.any?(resources, &(&1 =~ "explain_mode"))
      assert Enum.any?(resources, &(&1 =~ "list_presets"))
      assert Enum.any?(resources, &(&1 =~ "list_agents"))
    end

    test "does NOT include shell, fs, network, or code capabilities" do
      caps = InterviewAgent.required_capabilities()
      resources = Enum.map(caps, & &1.resource)

      Enum.each(resources, fn uri ->
        refute uri =~ "shell", "InterviewAgent must not have shell access"
        refute uri =~ "arbor://fs", "InterviewAgent must not have filesystem access"
        refute uri =~ "network", "InterviewAgent must not have network access"
        refute uri =~ "code/write", "InterviewAgent must not have code write access"
      end)
    end
  end

  describe "domain_context/0" do
    test "explains the trust system modes" do
      ctx = InterviewAgent.domain_context()
      assert ctx =~ ":block"
      assert ctx =~ ":ask"
      assert ctx =~ ":allow"
      assert ctx =~ ":auto"
    end

    test "explains security ceilings" do
      ctx = InterviewAgent.domain_context()
      assert ctx =~ "Security ceiling" or ctx =~ "security ceiling"
      assert ctx =~ "arbor://shell"
    end

    test "lists available presets" do
      ctx = InterviewAgent.domain_context()
      assert ctx =~ "Cautious"
      assert ctx =~ "Balanced"
      assert ctx =~ "Hands-off"
      assert ctx =~ "Full Trust"
    end
  end

  describe "values/0" do
    test "returns four values" do
      vals = InterviewAgent.values()
      assert length(vals) == 4
    end

    test "emphasizes human agency" do
      vals = InterviewAgent.values()
      assert Enum.any?(vals, &(&1 =~ "Human agency"))
    end
  end

  describe "Template.apply/1" do
    test "extracts all template data" do
      config = Template.apply(InterviewAgent)

      assert config[:name] == "Trust Interview Agent"
      assert %Character{} = config[:character]
      assert config[:trust_tier] == :trusted
      assert length(config[:initial_goals]) == 2
      assert length(config[:required_capabilities]) == 6
      assert config[:domain_context] =~ ":block"
      assert config[:description] =~ "trust"
      assert config[:nature] =~ "Relational"
      assert length(config[:values]) == 4
      assert config[:meta_awareness].grown_from_template == true
    end
  end
end
