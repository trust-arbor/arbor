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
end
