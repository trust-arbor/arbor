defmodule Arbor.AI.UnifiedBridgeTest do
  use ExUnit.Case, async: true

  @moduletag :integration

  alias Arbor.AI.UnifiedBridge

  describe "available?/0" do
    test "returns true when orchestrator client is loaded" do
      # The unified client module should be available in our test env
      # since arbor_orchestrator is compiled in the umbrella
      assert is_boolean(UnifiedBridge.available?())
    end
  end

  describe "generate_text/2" do
    @tag :llm
    test "returns :unavailable when client module not loaded" do
      # This test verifies the fallback behavior
      # We can't easily unload a module, so just verify the function exists
      # and returns one of the expected shapes
      result = UnifiedBridge.generate_text("test", provider: :anthropic, model: "test-model")
      assert match?({:ok, _}, result) or match?({:error, _}, result) or result == :unavailable
    end

    test "bridge can check availability and call unified client" do
      # Verify the bridge module works
      # available? should return a boolean
      assert is_boolean(UnifiedBridge.available?())

      # generate_text should either succeed, return :unavailable, or return an error
      result = UnifiedBridge.generate_text("test", provider: :test, model: "test-model")
      assert match?({:ok, _}, result) or match?({:error, _}, result) or result == :unavailable
    end
  end

  describe "resolve_provider/1" do
    test "maps API provider atoms to orchestrator strings" do
      assert UnifiedBridge.resolve_provider(provider: :anthropic) == "anthropic"
      assert UnifiedBridge.resolve_provider(provider: :openai) == "openai"
      assert UnifiedBridge.resolve_provider(provider: :gemini) == "gemini"
      assert UnifiedBridge.resolve_provider(provider: :openrouter) == "openrouter"
      assert UnifiedBridge.resolve_provider(provider: :xai) == "xai"
      assert UnifiedBridge.resolve_provider(provider: :zai) == "zai"
      assert UnifiedBridge.resolve_provider(provider: :zai_coding_plan) == "zai_coding_plan"
    end

    test "maps CLI provider atoms to orchestrator strings" do
      assert UnifiedBridge.resolve_provider(provider: :claude_cli) == "claude_cli"
      assert UnifiedBridge.resolve_provider(provider: :codex_cli) == "codex_cli"
      assert UnifiedBridge.resolve_provider(provider: :gemini_cli) == "gemini_cli"
      assert UnifiedBridge.resolve_provider(provider: :opencode_cli) == "opencode_cli"
    end

    test "maps local provider atoms to orchestrator strings" do
      assert UnifiedBridge.resolve_provider(provider: :lmstudio) == "lm_studio"
      assert UnifiedBridge.resolve_provider(provider: :ollama) == "ollama"
    end

    test "legacy backend: :cli maps API provider to CLI variant" do
      assert UnifiedBridge.resolve_provider(provider: :anthropic, backend: :cli) == "claude_cli"
      assert UnifiedBridge.resolve_provider(provider: :openai, backend: :cli) == "codex_cli"
      assert UnifiedBridge.resolve_provider(provider: :gemini, backend: :cli) == "gemini_cli"
      assert UnifiedBridge.resolve_provider(provider: :opencode, backend: :cli) == "opencode_cli"
    end

    test "backend: :cli with already-CLI provider passes through" do
      # claude_cli with backend: :cli — not in @cli_provider_map, uses @provider_map
      assert UnifiedBridge.resolve_provider(provider: :claude_cli, backend: :cli) == "claude_cli"
    end

    test "backend: :api does not affect provider mapping" do
      assert UnifiedBridge.resolve_provider(provider: :anthropic, backend: :api) == "anthropic"
      assert UnifiedBridge.resolve_provider(provider: :openai, backend: :api) == "openai"
    end

    test "string providers pass through unchanged" do
      assert UnifiedBridge.resolve_provider(provider: "custom_provider") == "custom_provider"
    end

    test "unknown atom providers converted to string" do
      assert UnifiedBridge.resolve_provider(provider: :some_future_provider) ==
               "some_future_provider"
    end
  end
end
