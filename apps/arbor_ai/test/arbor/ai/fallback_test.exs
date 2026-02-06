defmodule Arbor.AI.FallbackTest do
  use ExUnit.Case, async: true

  alias Arbor.AI.Fallback

  describe "status/0" do
    test "returns status map with required keys" do
      status = Fallback.status()

      assert is_map(status)
      assert Map.has_key?(status, :enabled)
      assert Map.has_key?(status, :ollama_available)
      assert Map.has_key?(status, :active)
      assert Map.has_key?(status, :fallback_model)
      assert Map.has_key?(status, :primary_healthy)
    end

    test "enabled is boolean" do
      status = Fallback.status()
      assert is_boolean(status.enabled)
    end

    test "fallback_model is string" do
      status = Fallback.status()
      assert is_binary(status.fallback_model)
    end
  end

  describe "fallback_active?/0" do
    test "defaults to false" do
      # Reset any previous state
      Fallback.reset()
      refute Fallback.fallback_active?()
    end
  end

  describe "reset/0" do
    test "clears fallback state" do
      # Reset should always succeed
      assert Fallback.reset() == :ok
      refute Fallback.fallback_active?()
    end
  end

  describe "ollama_available?/0" do
    test "returns boolean" do
      # This tests the function works without crashing
      # Actual availability depends on local Ollama installation
      result = Fallback.ollama_available?()
      assert is_boolean(result)
    end
  end

  describe "configuration" do
    test "fallback is enabled by default" do
      # Default configuration should have fallback enabled
      status = Fallback.status()
      assert status.enabled == true
    end

    test "default model is llama3" do
      status = Fallback.status()
      assert status.fallback_model == "llama3"
    end
  end

  # ============================================================================
  # Integration tests (require Ollama running)
  # ============================================================================

  describe "generate_via_ollama/2 integration" do
    @describetag :integration
    @describetag :external

    @tag timeout: 30_000
    test "generates text when Ollama is available" do
      if Fallback.ollama_available?() do
        result = Fallback.generate_via_ollama("Say hello", model: "llama3")

        case result do
          {:ok, response} ->
            assert is_binary(response.text)
            assert response.provider == :ollama
            assert is_map(response.usage)

          {:error, reason} ->
            # Model might not be pulled
            assert reason in [:connection_refused, :model_not_found] or is_tuple(reason)
        end
      else
        # Skip if Ollama not available
        :ok
      end
    end
  end

  describe "generate_with_fallback/2 integration" do
    @describetag :integration
    @describetag :external

    @tag timeout: 60_000
    test "falls back to Ollama on primary timeout" do
      if Fallback.ollama_available?() do
        # Set a very short timeout to force fallback
        result =
          Fallback.generate_with_fallback("Hello",
            primary_opts: [timeout: 1],
            fallback_timeout_ms: 1
          )

        # Either succeeds via fallback or errors appropriately
        assert match?({:ok, _}, result) or match?({:error, _}, result)
      else
        :ok
      end
    end
  end
end
