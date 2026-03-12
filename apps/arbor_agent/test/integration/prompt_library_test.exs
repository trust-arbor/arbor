defmodule Arbor.Agent.Integration.PromptLibraryTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Arbor.Agent.{CognitivePrompts, HeartbeatPrompt}
  alias Arbor.Common.SkillLibrary
  alias Arbor.Contracts.Skill

  @skills_dir Path.expand("../../../../.arbor/skills", __DIR__)

  setup do
    # Ensure clean state
    if Process.whereis(SkillLibrary) do
      GenServer.stop(SkillLibrary)
      Process.sleep(10)
    end

    if :ets.whereis(:arbor_skill_library) != :undefined do
      :ets.delete(:arbor_skill_library)
    end

    :ok
  end

  describe "heartbeat skill indexing" do
    test "indexes all 12 heartbeat skills from .arbor/skills" do
      {:ok, pid} = SkillLibrary.start_link(dirs: [@skills_dir])
      Process.sleep(100)

      heartbeat_skills = SkillLibrary.list(category: "heartbeat")
      names = Enum.map(heartbeat_skills, &Map.get(&1, :name))

      expected = [
        "cognitive-goal-pursuit",
        "cognitive-plan-execution",
        "cognitive-introspection",
        "cognitive-consolidation",
        "cognitive-pattern-analysis",
        "cognitive-reflection",
        "cognitive-insight-detection",
        "heartbeat-system-prompt",
        "heartbeat-response-format",
        "directive-goal-pursuit",
        "directive-plan-execution",
        "directive-reflection"
      ]

      for name <- expected do
        assert name in names, "Expected skill #{name} to be indexed, got: #{inspect(names)}"
      end

      GenServer.stop(pid)
    end

    test "heartbeat skills have version field" do
      {:ok, pid} = SkillLibrary.start_link(dirs: [@skills_dir])
      Process.sleep(100)

      {:ok, skill} = SkillLibrary.get("cognitive-goal-pursuit")
      assert Map.get(skill, :version) == "1.0.0"

      GenServer.stop(pid)
    end

    test "heartbeat-system-prompt has template_vars" do
      {:ok, pid} = SkillLibrary.start_link(dirs: [@skills_dir])
      Process.sleep(100)

      {:ok, skill} = SkillLibrary.get("heartbeat-system-prompt")
      assert "nonce_preamble" in Map.get(skill, :template_vars, [])

      GenServer.stop(pid)
    end
  end

  describe "cognitive prompt loading from SkillLibrary" do
    test "loads cognitive prompts from skill files" do
      {:ok, pid} = SkillLibrary.start_link(dirs: [@skills_dir])
      Process.sleep(100)

      prompt = CognitivePrompts.prompt_for(:goal_pursuit)
      assert prompt =~ "Goal Pursuit"
      assert prompt =~ "Be proactive"

      prompt = CognitivePrompts.prompt_for(:introspection)
      assert prompt =~ "Introspection"

      prompt = CognitivePrompts.prompt_for(:consolidation)
      assert prompt =~ "Knowledge Consolidation"

      GenServer.stop(pid)
    end

    test "falls back to hardcoded prompts when SkillLibrary not running" do
      # SkillLibrary not started
      prompt = CognitivePrompts.prompt_for(:goal_pursuit)
      assert prompt =~ "Goal Pursuit"
      assert prompt =~ "Be proactive"
    end

    test "conversation mode always returns empty string" do
      assert CognitivePrompts.prompt_for(:conversation) == ""
    end
  end

  describe "heartbeat prompt loading from SkillLibrary" do
    test "system_prompt loads from skill file" do
      {:ok, pid} = SkillLibrary.start_link(dirs: [@skills_dir])
      Process.sleep(100)

      prompt = HeartbeatPrompt.system_prompt(%{})
      assert prompt =~ "autonomous AI agent"
      assert prompt =~ "valid JSON only"

      GenServer.stop(pid)
    end

    test "system_prompt renders nonce template var" do
      {:ok, pid} = SkillLibrary.start_link(dirs: [@skills_dir])
      Process.sleep(100)

      prompt = HeartbeatPrompt.system_prompt(%{nonce: "TEST_NONCE"})
      assert prompt =~ "TEST_NONCE"

      GenServer.stop(pid)
    end

    test "system_prompt falls back when SkillLibrary not running" do
      prompt = HeartbeatPrompt.system_prompt(%{})
      assert prompt =~ "autonomous AI agent"
    end

    test "response_format_section loads from skill file" do
      {:ok, pid} = SkillLibrary.start_link(dirs: [@skills_dir])
      Process.sleep(100)

      prompt = HeartbeatPrompt.build_prompt(%{enabled_prompt_sections: [:response_format]})
      assert prompt =~ "Response Format"
      assert prompt =~ "valid JSON only"

      GenServer.stop(pid)
    end
  end

  describe "override priority" do
    test "first-registered directory wins over later ones" do
      {:ok, pid} = SkillLibrary.start_link(dirs: [])

      # Register a custom override
      {:ok, override} =
        Skill.new(%{
          name: "cognitive-goal-pursuit",
          description: "Custom override",
          body: "CUSTOM OVERRIDE BODY",
          category: "heartbeat"
        })

      SkillLibrary.register(override)

      # Now index the standard skills — should NOT overwrite the already-registered one
      SkillLibrary.index(@skills_dir)

      {:ok, skill} = SkillLibrary.get("cognitive-goal-pursuit")
      assert Map.get(skill, :body) == "CUSTOM OVERRIDE BODY"

      GenServer.stop(pid)
    end
  end

  describe "prompt-aware capability discovery" do
    test "heartbeat skills get kind: :prompt and prompt: prefix" do
      {:ok, pid} = SkillLibrary.start_link(dirs: [@skills_dir])
      Process.sleep(100)

      provider = Arbor.Common.CapabilityProviders.SkillProvider

      {:ok, descriptor} = provider.describe("prompt:cognitive-goal-pursuit")
      assert descriptor.kind == :prompt
      assert descriptor.id == "prompt:cognitive-goal-pursuit"

      GenServer.stop(pid)
    end

    test "advisory skills also get kind: :prompt" do
      {:ok, pid} = SkillLibrary.start_link(dirs: [@skills_dir])
      Process.sleep(100)

      provider = Arbor.Common.CapabilityProviders.SkillProvider

      {:ok, descriptor} = provider.describe("prompt:security-perspective")
      assert descriptor.kind == :prompt

      GenServer.stop(pid)
    end

    test "non-prompt skills retain kind: :skill" do
      {:ok, pid} = SkillLibrary.start_link(dirs: [])

      {:ok, skill} =
        Skill.new(%{
          name: "custom-tool",
          description: "A custom tool",
          body: "Tool body",
          category: "tool"
        })

      SkillLibrary.register(skill)

      provider = Arbor.Common.CapabilityProviders.SkillProvider
      {:ok, descriptor} = provider.describe("skill:custom-tool")
      assert descriptor.kind == :skill

      GenServer.stop(pid)
    end

    test "execute with bindings renders template vars" do
      {:ok, pid} = SkillLibrary.start_link(dirs: [@skills_dir])
      Process.sleep(100)

      provider = Arbor.Common.CapabilityProviders.SkillProvider

      {:ok, result} =
        provider.execute(
          "prompt:heartbeat-system-prompt",
          %{bindings: %{"nonce_preamble" => "\n\nNONCE_HERE\n"}},
          []
        )

      assert result.body =~ "NONCE_HERE"

      GenServer.stop(pid)
    end
  end
end
