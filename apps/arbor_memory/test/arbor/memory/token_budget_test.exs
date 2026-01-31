defmodule Arbor.Memory.TokenBudgetTest do
  use ExUnit.Case, async: true

  alias Arbor.Memory.TokenBudget

  @moduletag :fast

  describe "resolve/2" do
    test "resolves fixed budget" do
      assert TokenBudget.resolve({:fixed, 1000}, 100_000) == 1000
      assert TokenBudget.resolve({:fixed, 500}, 50_000) == 500
    end

    test "resolves percentage budget" do
      assert TokenBudget.resolve({:percentage, 0.10}, 100_000) == 10_000
      assert TokenBudget.resolve({:percentage, 0.25}, 100_000) == 25_000
      assert TokenBudget.resolve({:percentage, 0.0}, 100_000) == 0
      assert TokenBudget.resolve({:percentage, 1.0}, 100_000) == 100_000
    end

    test "resolves min_max budget with clamping" do
      # Normal case - percentage is within bounds
      assert TokenBudget.resolve({:min_max, 500, 5000, 0.10}, 20_000) == 2000

      # Hit max ceiling
      assert TokenBudget.resolve({:min_max, 500, 5000, 0.10}, 100_000) == 5000

      # Hit min floor
      assert TokenBudget.resolve({:min_max, 500, 5000, 0.10}, 1000) == 500
    end
  end

  describe "resolve_for_model/2" do
    test "resolves budget for known model" do
      # Claude 3.5 Sonnet has 200k context
      assert TokenBudget.resolve_for_model(
               {:percentage, 0.10},
               "anthropic:claude-3-5-sonnet-20241022"
             ) == 20_000
    end

    test "resolves budget for unknown model using default" do
      # Default is 100k
      assert TokenBudget.resolve_for_model({:percentage, 0.10}, "unknown:model") == 10_000
    end
  end

  describe "estimate_tokens/1" do
    test "estimates tokens from text" do
      # ~4 chars per token
      assert TokenBudget.estimate_tokens("Hello, world!") == 3
      assert TokenBudget.estimate_tokens(String.duplicate("x", 100)) == 25
    end

    test "returns at least 1 for non-empty text" do
      assert TokenBudget.estimate_tokens("hi") == 1
    end
  end

  describe "model_context_size/1" do
    test "returns correct size for known models" do
      assert TokenBudget.model_context_size("anthropic:claude-3-5-sonnet-20241022") == 200_000
      assert TokenBudget.model_context_size("openai:gpt-4o") == 128_000
      assert TokenBudget.model_context_size("google:gemini-1.5-pro") == 2_000_000
    end

    test "returns default for unknown models" do
      assert TokenBudget.model_context_size("unknown:model") == 100_000
    end
  end

  describe "fits?/3" do
    test "returns true when text fits within budget" do
      assert TokenBudget.fits?("Hello", {:fixed, 100}, "anthropic:claude-3-5-sonnet-20241022")
    end

    test "returns false when text exceeds budget" do
      long_text = String.duplicate("x", 1000)
      refute TokenBudget.fits?(long_text, {:fixed, 10}, "anthropic:claude-3-5-sonnet-20241022")
    end
  end

  describe "allocate/2" do
    test "allocates budgets across sections" do
      allocations = %{
        system: {:percentage, 0.05},
        memory: {:percentage, 0.15},
        context: {:percentage, 0.70},
        response: {:percentage, 0.10}
      }

      result = TokenBudget.allocate(allocations, 100_000)

      assert result.system == 5000
      assert result.memory == 15_000
      assert result.context == 70_000
      assert result.response == 10_000
    end
  end

  describe "truncate/3" do
    test "returns text unchanged if within budget" do
      text = "Hello, world!"
      assert TokenBudget.truncate(text, {:fixed, 100}) == text
    end

    test "truncates and adds ellipsis if over budget" do
      text = String.duplicate("word ", 100)
      truncated = TokenBudget.truncate(text, {:fixed, 10})

      assert String.ends_with?(truncated, "...")
      assert String.length(truncated) <= 10 * 4 + 3
    end
  end

  describe "known_models/0" do
    test "returns list of model tuples sorted by context size" do
      models = TokenBudget.known_models()

      assert is_list(models)
      assert length(models) > 0

      # First should be largest
      [{_first_model, first_size} | _] = models
      assert first_size >= 1_000_000
    end
  end
end
