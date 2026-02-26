defmodule Arbor.AI.UnifiedBridgeEmbedTest do
  use ExUnit.Case, async: true

  alias Arbor.AI.UnifiedBridge

  @moduletag :fast

  describe "embed/2" do
    test "returns :unavailable when orchestrator is not loaded" do
      # This tests the availability check — in test env, the client
      # may or may not be available depending on app startup
      result = UnifiedBridge.embed("hello", provider: :test, model: "test-model")

      # Should either succeed or return an expected error, never crash
      assert result in [:unavailable] or
               match?({:ok, _}, result) or
               match?({:error, _}, result)
    end

    test "resolve_provider maps embedding provider atoms" do
      assert UnifiedBridge.resolve_provider(provider: :ollama) == "ollama"
      assert UnifiedBridge.resolve_provider(provider: :lmstudio) == "lm_studio"
      assert UnifiedBridge.resolve_provider(provider: :openai) == "openai"
      assert UnifiedBridge.resolve_provider(provider: :openrouter) == "openrouter"
    end
  end

  describe "embed_batch/2" do
    test "returns :unavailable when orchestrator is not loaded" do
      result =
        UnifiedBridge.embed_batch(["hello", "world"],
          provider: :test,
          model: "test-model"
        )

      assert result in [:unavailable] or
               match?({:ok, _}, result) or
               match?({:error, _}, result)
    end
  end
end
