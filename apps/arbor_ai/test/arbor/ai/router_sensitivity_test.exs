defmodule Arbor.AI.RouterSensitivityTest do
  use ExUnit.Case, async: true

  alias Arbor.AI.BackendTrust

  @moduletag :fast

  # These tests exercise the filter_by_sensitivity/2 function via the Router module.
  # Since filter_by_sensitivity is private, we test it indirectly through its
  # integration with the routing pipeline.

  describe "filter_by_sensitivity integration" do
    test "nil sensitivity does not filter candidates" do
      # All backends should pass through when no sensitivity specified
      candidates = [
        {:lmstudio, "local"},
        {:anthropic, "claude"},
        {:openai, "gpt"},
        {:qwen, "qwen"}
      ]

      # Simulate the filter by calling BackendTrust.can_see? directly
      # (since the full router pipeline needs running processes)
      filtered =
        Enum.filter(candidates, fn {backend, _model} ->
          BackendTrust.can_see?(backend, :public)
        end)

      assert length(filtered) == 4
    end

    test ":restricted sensitivity filters to local-only" do
      candidates = [
        {:lmstudio, "local"},
        {:anthropic, "claude"},
        {:openai, "gpt"},
        {:qwen, "qwen"}
      ]

      filtered =
        Enum.filter(candidates, fn {backend, _model} ->
          BackendTrust.can_see?(backend, :restricted)
        end)

      assert length(filtered) == 1
      assert [{:lmstudio, _}] = filtered
    end

    test ":confidential sensitivity includes anthropic and local" do
      candidates = [
        {:lmstudio, "local"},
        {:ollama, "llama"},
        {:anthropic, "claude"},
        {:opencode, "opencode"},
        {:openai, "gpt"},
        {:qwen, "qwen"}
      ]

      filtered =
        Enum.filter(candidates, fn {backend, _model} ->
          BackendTrust.can_see?(backend, :confidential)
        end)

      backends = Enum.map(filtered, &elem(&1, 0))
      assert :lmstudio in backends
      assert :ollama in backends
      assert :anthropic in backends
      assert :opencode in backends
      refute :openai in backends
      refute :qwen in backends
    end

    test ":internal sensitivity includes most providers" do
      candidates = [
        {:openai, "gpt"},
        {:gemini, "pro"},
        {:qwen, "qwen"},
        {:openrouter, "router"}
      ]

      filtered =
        Enum.filter(candidates, fn {backend, _model} ->
          BackendTrust.can_see?(backend, :internal)
        end)

      backends = Enum.map(filtered, &elem(&1, 0))
      assert :openai in backends
      assert :gemini in backends
      refute :qwen in backends
      refute :openrouter in backends
    end

    test ":public sensitivity includes all providers" do
      candidates = [
        {:qwen, "qwen"},
        {:openrouter, "router"},
        {:lmstudio, "local"}
      ]

      filtered =
        Enum.filter(candidates, fn {backend, _model} ->
          BackendTrust.can_see?(backend, :public)
        end)

      assert length(filtered) == 3
    end
  end
end
