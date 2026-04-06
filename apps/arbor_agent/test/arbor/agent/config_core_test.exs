defmodule Arbor.Agent.ConfigCoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Agent.ConfigCore
  alias Arbor.Contracts.Agent.Config

  describe "resolve_model_profile/1" do
    test "returns defaults for nil" do
      profile = ConfigCore.resolve_model_profile(nil)
      assert is_integer(profile.context_size)
    end

    test "returns defaults for unknown model" do
      profile = ConfigCore.resolve_model_profile("nonexistent/model")
      assert is_integer(profile.context_size)
    end
  end

  describe "from_spec/1" do
    test "builds Config from spec-like map" do
      spec = %{
        provider: :openrouter,
        model: "arcee-ai/trinity-large-thinking",
        system_prompt: "You are a helpful agent.",
        tools: ["file_read", "memory_recall"],
        heartbeat: %{enabled: true, interval_ms: 30_000, model: nil},
        execution_mode: :session,
        auto_start: false
      }

      config = ConfigCore.from_spec(spec)
      assert config.provider == :openrouter
      assert config.model == "arcee-ai/trinity-large-thinking"
      assert length(config.tools) == 2
      assert config.execution_mode == :session
    end
  end

  describe "update_model/3" do
    test "updates provider and model" do
      config = %Config{provider: :openrouter, model: "old-model"}
      updated = ConfigCore.update_model(config, :anthropic, "claude-sonnet-4-6")
      assert updated.provider == :anthropic
      assert updated.model == "claude-sonnet-4-6"
      assert updated.model_profile != nil
    end
  end

  describe "update_tools/2" do
    test "replaces tool list" do
      config = %Config{provider: :openrouter, model: "m", tools: ["old"]}
      updated = ConfigCore.update_tools(config, ["new_a", "new_b"])
      assert updated.tools == ["new_a", "new_b"]
    end
  end

  describe "update_generation_params/2" do
    test "merges params" do
      config = %Config{provider: :openrouter, model: "m", generation_params: %{temperature: 0.7}}
      updated = ConfigCore.update_generation_params(config, %{top_p: 0.9})
      assert updated.generation_params.temperature == 0.7
      assert updated.generation_params.top_p == 0.9
    end
  end

  describe "show_config/1" do
    test "formats for display" do
      config = %Config{
        provider: :openrouter,
        model: "test-model",
        tools: ["a", "b", "c"],
        heartbeat: %{enabled: true},
        execution_mode: :session,
        model_profile: %{context_size: 128_000}
      }

      display = ConfigCore.show_config(config)
      assert display.provider == :openrouter
      assert display.tool_count == 3
      assert display.heartbeat_enabled == true
    end
  end

  describe "for_llm/1" do
    test "formats for LLM call" do
      config = %Config{
        provider: :openrouter,
        model: "test-model",
        system_prompt: "Be helpful.",
        generation_params: %{temperature: 0.7}
      }

      llm_config = ConfigCore.for_llm(config)
      assert llm_config["llm_provider"] == "openrouter"
      assert llm_config["llm_model"] == "test-model"
      assert llm_config["system_prompt"] == "Be helpful."
      assert llm_config["temperature"] == 0.7
    end
  end

  describe "format_model/1" do
    test "formats provider:model" do
      config = %Config{provider: :openrouter, model: "test-model"}
      assert ConfigCore.format_model(config) == "openrouter:test-model"
    end

    test "handles nil provider" do
      config = %Config{provider: nil, model: nil}
      assert ConfigCore.format_model(config) == "not configured"
    end
  end
end
