defmodule Arbor.AI.BudgetTrackerTest do
  use ExUnit.Case, async: false

  alias Arbor.AI.BudgetTracker

  @moduletag :fast

  setup do
    # Ensure BudgetTracker is started
    unless BudgetTracker.started?() do
      {:ok, _} = BudgetTracker.start_link()
    end

    # Reset before each test
    BudgetTracker.reset()

    on_exit(fn ->
      if BudgetTracker.started?() do
        BudgetTracker.reset()
      end
    end)

    :ok
  end

  describe "record_usage/2" do
    test "records usage and accumulates cost" do
      BudgetTracker.record_usage(:anthropic, %{
        model: "claude-sonnet-4",
        input_tokens: 1_000_000,
        output_tokens: 0
      })

      # Wait for async cast
      :timer.sleep(10)

      {:ok, status} = BudgetTracker.get_status()
      assert status.spent_today > 0
      assert status.remaining < status.daily_budget
    end

    test "tracks per-backend usage" do
      BudgetTracker.record_usage(:anthropic, %{
        model: "claude-sonnet-4",
        input_tokens: 1_000_000,
        output_tokens: 500_000
      })

      BudgetTracker.record_usage(:openai, %{
        model: "gpt-4",
        input_tokens: 1_000_000,
        output_tokens: 500_000
      })

      :timer.sleep(10)

      stats = BudgetTracker.today_stats()
      assert Map.has_key?(stats.backends, :anthropic)
      assert Map.has_key?(stats.backends, :openai)
      assert stats.backends[:anthropic].requests == 1
      assert stats.backends[:openai].requests == 1
    end

    test "free backends have zero cost" do
      BudgetTracker.record_usage(:ollama, %{
        model: "llama3.2",
        input_tokens: 1_000_000,
        output_tokens: 500_000
      })

      :timer.sleep(10)

      spend = BudgetTracker.backend_spend(:ollama)
      assert spend == 0.0
    end
  end

  describe "budget_remaining/0" do
    test "returns full budget when no spend" do
      remaining = BudgetTracker.budget_remaining()
      {:ok, status} = BudgetTracker.get_status()
      assert remaining == status.daily_budget
    end

    test "decreases after usage" do
      initial = BudgetTracker.budget_remaining()

      BudgetTracker.record_usage(:anthropic, %{
        model: "claude-opus-4",
        input_tokens: 1_000_000,
        output_tokens: 1_000_000
      })

      :timer.sleep(10)

      after_usage = BudgetTracker.budget_remaining()
      assert after_usage < initial
    end
  end

  describe "should_prefer_free?/0" do
    test "returns false when budget is healthy" do
      assert BudgetTracker.should_prefer_free?() == false
    end

    test "returns true when budget is low" do
      original_budget = Application.get_env(:arbor_ai, :daily_api_budget_usd)
      original_threshold = Application.get_env(:arbor_ai, :budget_prefer_free_threshold)

      try do
        # Set a small budget so we can exceed threshold easily
        Application.put_env(:arbor_ai, :daily_api_budget_usd, 1.0)
        Application.put_env(:arbor_ai, :budget_prefer_free_threshold, 0.5)

        # Spend 60% of budget (opus is expensive)
        BudgetTracker.record_usage(:anthropic, %{
          model: "claude-opus-4",
          input_tokens: 100_000,
          output_tokens: 8_000
        })

        :timer.sleep(10)

        assert BudgetTracker.should_prefer_free?() == true
      after
        Application.put_env(:arbor_ai, :daily_api_budget_usd, original_budget || 10.0)

        if original_threshold do
          Application.put_env(:arbor_ai, :budget_prefer_free_threshold, original_threshold)
        else
          Application.delete_env(:arbor_ai, :budget_prefer_free_threshold)
        end
      end
    end
  end

  describe "over_budget?/0" do
    test "returns false when under budget" do
      assert BudgetTracker.over_budget?() == false
    end

    test "returns true when at or over budget" do
      original_budget = Application.get_env(:arbor_ai, :daily_api_budget_usd)

      try do
        # Set tiny budget
        Application.put_env(:arbor_ai, :daily_api_budget_usd, 0.01)

        # Spend more than budget
        BudgetTracker.record_usage(:anthropic, %{
          model: "claude-opus-4",
          input_tokens: 10_000,
          output_tokens: 10_000
        })

        :timer.sleep(10)

        assert BudgetTracker.over_budget?() == true
      after
        Application.put_env(:arbor_ai, :daily_api_budget_usd, original_budget || 10.0)
      end
    end
  end

  describe "get_status/0" do
    test "returns complete status map" do
      {:ok, status} = BudgetTracker.get_status()

      assert is_float(status.daily_budget)
      assert is_float(status.spent_today)
      assert is_float(status.remaining)
      assert is_float(status.percent_remaining)
      assert is_map(status.backends)
    end

    test "percent_remaining is between 0 and 1" do
      {:ok, status} = BudgetTracker.get_status()
      assert status.percent_remaining >= 0.0
      assert status.percent_remaining <= 1.0
    end
  end

  describe "backend_spend/1" do
    test "returns 0 for unused backend" do
      spend = BudgetTracker.backend_spend(:unused_backend)
      assert spend == 0.0
    end

    test "returns accumulated spend for used backend" do
      BudgetTracker.record_usage(:anthropic, %{
        model: "claude-sonnet-4",
        input_tokens: 1_000_000,
        output_tokens: 0
      })

      :timer.sleep(10)

      spend = BudgetTracker.backend_spend(:anthropic)
      assert spend > 0.0
    end
  end

  describe "today_stats/0" do
    test "returns complete stats" do
      BudgetTracker.record_usage(:anthropic, %{
        model: "claude-sonnet-4",
        input_tokens: 1000,
        output_tokens: 500
      })

      :timer.sleep(10)

      stats = BudgetTracker.today_stats()
      assert stats.requests == 1
      assert stats.total_tokens == 1500
      assert is_float(stats.total_cost)
      assert is_map(stats.backends)
    end
  end

  describe "reset/0" do
    test "clears all tracking data" do
      BudgetTracker.record_usage(:anthropic, %{
        model: "claude-sonnet-4",
        input_tokens: 1_000_000,
        output_tokens: 500_000
      })

      :timer.sleep(10)

      # Verify there was spending
      {:ok, before} = BudgetTracker.get_status()
      assert before.spent_today > 0

      # Reset
      BudgetTracker.reset()
      :timer.sleep(10)

      # Verify cleared
      {:ok, after_reset} = BudgetTracker.get_status()
      assert after_reset.spent_today == 0.0
      assert after_reset.remaining == after_reset.daily_budget
    end
  end

  describe "free_backend?/1" do
    test "identifies free backends" do
      assert BudgetTracker.free_backend?(:ollama) == true
      assert BudgetTracker.free_backend?(:lmstudio) == true
      assert BudgetTracker.free_backend?(:opencode) == true
    end

    test "identifies paid backends" do
      assert BudgetTracker.free_backend?(:anthropic) == false
      assert BudgetTracker.free_backend?(:openai) == false
      assert BudgetTracker.free_backend?(:gemini) == false
    end
  end

  describe "started?/0" do
    test "returns true when running" do
      assert BudgetTracker.started?() == true
    end
  end

  describe "cost calculation" do
    test "opus is more expensive than sonnet" do
      BudgetTracker.record_usage(:anthropic, %{
        model: "claude-opus-4",
        input_tokens: 100_000,
        output_tokens: 0
      })

      :timer.sleep(10)
      opus_cost = BudgetTracker.backend_spend(:anthropic)

      BudgetTracker.reset()
      :timer.sleep(10)

      BudgetTracker.record_usage(:anthropic, %{
        model: "claude-sonnet-4",
        input_tokens: 100_000,
        output_tokens: 0
      })

      :timer.sleep(10)
      sonnet_cost = BudgetTracker.backend_spend(:anthropic)

      assert opus_cost > sonnet_cost
    end

    test "output tokens cost more than input tokens" do
      BudgetTracker.record_usage(:anthropic, %{
        model: "claude-sonnet-4",
        input_tokens: 1_000_000,
        output_tokens: 0
      })

      :timer.sleep(10)
      input_only_cost = BudgetTracker.backend_spend(:anthropic)

      BudgetTracker.reset()
      :timer.sleep(10)

      BudgetTracker.record_usage(:anthropic, %{
        model: "claude-sonnet-4",
        input_tokens: 0,
        output_tokens: 1_000_000
      })

      :timer.sleep(10)
      output_only_cost = BudgetTracker.backend_spend(:anthropic)

      assert output_only_cost > input_only_cost
    end
  end
end
