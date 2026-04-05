defmodule Arbor.Agent.SpecTest do
  use ExUnit.Case, async: true

  alias Arbor.Agent.Spec
  alias Arbor.Contracts.Agent.Spec, as: AgentSpec
  alias Arbor.Agent.{Character, Profile}

  describe "new/1" do
    test "creates spec with display_name" do
      assert {:ok, %AgentSpec{display_name: "test"}} = Spec.new(display_name: "test")
    end

    test "returns error without display_name" do
      assert {:error, :missing_display_name} = Spec.new([])
    end

    test "defaults trust_tier to :untrusted" do
      {:ok, spec} = Spec.new(display_name: "test")
      assert spec.trust_tier == :untrusted
    end

    test "applies explicit trust_tier" do
      {:ok, spec} = Spec.new(display_name: "test", trust_tier: :veteran)
      assert spec.trust_tier == :veteran
    end

    test "applies model_config" do
      {:ok, spec} =
        Spec.new(
          display_name: "test",
          model_config: %{id: "arcee-ai/trinity-large-thinking", provider: :openrouter}
        )

      assert spec.model == "arcee-ai/trinity-large-thinking"
      assert spec.provider == :openrouter
    end

    test "applies model_config with string keys" do
      {:ok, spec} =
        Spec.new(
          display_name: "test",
          model_config: %{"llm_model" => "gpt-4", "llm_provider" => "openai"}
        )

      assert spec.model == "gpt-4"
      assert spec.provider == :openai
    end

    test "applies explicit character" do
      char = Character.new(name: "TestBot")
      {:ok, spec} = Spec.new(display_name: "test", character: char)
      assert spec.character.name == "TestBot"
    end

    test "applies initial_goals" do
      goals = [%{type: :achieve, description: "Do the thing"}]
      {:ok, spec} = Spec.new(display_name: "test", initial_goals: goals)
      assert spec.initial_goals == goals
    end

    test "applies capabilities" do
      caps = [%{resource: "arbor://fs/read"}]
      {:ok, spec} = Spec.new(display_name: "test", capabilities: caps)
      assert spec.initial_capabilities == caps
    end

    test "applies auto_start" do
      {:ok, spec} = Spec.new(display_name: "test", auto_start: true)
      assert spec.auto_start == true
    end

    test "applies delegator_id" do
      {:ok, spec} = Spec.new(display_name: "test", delegator_id: "agent_parent")
      assert spec.delegator_id == "agent_parent"
    end

    test "explicit trust_tier overrides template default" do
      {:ok, spec} =
        Spec.new(
          display_name: "test",
          trust_tier: :autonomous,
          character: Character.new(name: "test")
        )

      assert spec.trust_tier == :autonomous
    end

    test "applies metadata" do
      {:ok, spec} = Spec.new(display_name: "test", metadata: %{custom: "value"})
      assert spec.metadata.custom == "value"
    end
  end

  describe "from_profile/2" do
    test "reconstructs spec from profile" do
      profile = %Profile{
        agent_id: "agent_123",
        display_name: "test",
        character: Character.new(name: "TestBot"),
        trust_tier: :veteran,
        template: "diagnostician",
        initial_goals: [%{type: :maintain, description: "monitor"}],
        initial_capabilities: [],
        auto_start: true,
        metadata: %{version: 1}
      }

      model_config = %{"llm_model" => "arcee-ai/trinity-large-thinking", "llm_provider" => "openrouter"}
      {:ok, spec} = Spec.from_profile(profile, model_config)

      assert spec.display_name == "test"
      assert spec.trust_tier == :veteran
      assert spec.model == "arcee-ai/trinity-large-thinking"
      assert spec.provider == :openrouter
      assert spec.template == "diagnostician"
      assert spec.auto_start == true
    end

    test "handles nil trust_tier in profile" do
      profile = %Profile{
        agent_id: "agent_123",
        display_name: "test",
        character: Character.new(name: "test"),
        trust_tier: nil,
        metadata: %{}
      }

      {:ok, spec} = Spec.from_profile(profile)
      assert spec.trust_tier == :untrusted
    end
  end

  describe "to_profile/3" do
    test "converts spec to profile" do
      {:ok, spec} =
        Spec.new(
          display_name: "test",
          trust_tier: :veteran,
          character: Character.new(name: "TestBot"),
          model_config: %{id: "model-1", provider: :openrouter}
        )

      identity = %{
        agent_id: "agent_abc",
        public_key: :crypto.strong_rand_bytes(32),
        endorsement: %{authority_id: "system"}
      }

      profile = Spec.to_profile(spec, "agent_abc", identity)

      assert profile.agent_id == "agent_abc"
      assert profile.display_name == "test"
      assert profile.trust_tier == :veteran
      assert profile.character.name == "TestBot"
      assert profile.metadata.last_model_config == spec.model_config
    end
  end

  describe "to_session_opts/3" do
    test "converts spec to session opts" do
      {:ok, spec} =
        Spec.new(
          display_name: "test",
          trust_tier: :established,
          model_config: %{id: "model-1", provider: :openrouter}
        )

      opts = Spec.to_session_opts(spec, "agent_abc")

      assert Keyword.get(opts, :session_id) == "agent-session-agent_abc"
      assert Keyword.get(opts, :agent_id) == "agent_abc"
      assert Keyword.get(opts, :trust_tier) == :established
      assert opts[:config]["llm_model"] == "model-1"
      assert opts[:config]["llm_provider"] == "openrouter"
    end
  end

  describe "to_lifecycle_opts/1" do
    test "converts spec to lifecycle opts" do
      {:ok, spec} =
        Spec.new(
          display_name: "test",
          trust_tier: :veteran,
          template: "diagnostician",
          character: Character.new(name: "Diag"),
          capabilities: [%{resource: "arbor://monitor/read"}]
        )

      opts = Spec.to_lifecycle_opts(spec)

      assert Keyword.get(opts, :trust_tier) == :veteran
      assert Keyword.get(opts, :template) == "diagnostician"
      assert Keyword.get(opts, :character) != nil
      assert length(Keyword.get(opts, :capabilities)) == 1
    end
  end
end
