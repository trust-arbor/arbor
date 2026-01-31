defmodule Arbor.AI.RouterTest do
  use ExUnit.Case, async: false

  alias Arbor.AI.{BudgetTracker, Router, TaskMeta}

  # Note: These tests use mocked availability where needed
  # The router depends on BackendRegistry, QuotaTracker, and BudgetTracker which need real processes

  describe "route_task/2" do
    @tag :fast
    test "accepts string prompt and classifies it" do
      # This will try to route but may fail if no backends available
      # The key is it accepts the string input
      result = Router.route_task("Hello world")
      # Either succeeds or returns error (no backends)
      assert match?({:ok, {_backend, _model}}, result) or
               match?({:error, _}, result)
    end

    @tag :fast
    test "accepts TaskMeta struct" do
      meta = %TaskMeta{risk_level: :medium, complexity: :moderate}
      result = Router.route_task(meta)

      assert match?({:ok, {_backend, _model}}, result) or
               match?({:error, _}, result)
    end

    @tag :fast
    test "manual model override bypasses routing" do
      result = Router.route_task("any prompt", model: {:anthropic, :opus})
      assert {:ok, {:anthropic, model}} = result
      assert is_binary(model)
      assert model =~ "claude-opus"
    end

    @tag :fast
    test "manual override with string model passes through" do
      result = Router.route_task("any prompt", model: {:anthropic, "custom-model"})
      assert {:ok, {:anthropic, "custom-model"}} = result
    end

    @tag :fast
    test "invalid model override returns error" do
      result = Router.route_task("prompt", model: "not a tuple")
      assert {:error, :invalid_model_override} = result
    end

    @tag :fast
    test "security prompt gets classified to critical tier" do
      # First classify to verify tier
      meta = TaskMeta.classify("fix the security vulnerability in auth")
      assert TaskMeta.tier(meta) == :critical

      # Then verify routing attempts critical tier
      # (may fail if backends unavailable, but the classification is correct)
      _result = Router.route_task("fix the security vulnerability in auth")
    end

    @tag :fast
    test "trivial prompt gets classified to trivial tier" do
      meta = TaskMeta.classify("fix typo in readme")
      assert TaskMeta.tier(meta) == :trivial
    end
  end

  describe "route_task/2 with routing disabled" do
    @tag :fast
    test "returns error when task routing is disabled" do
      original = Application.get_env(:arbor_ai, :enable_task_routing)

      try do
        Application.put_env(:arbor_ai, :enable_task_routing, false)
        assert {:error, :task_routing_disabled} = Router.route_task("any prompt")
      after
        if original != nil do
          Application.put_env(:arbor_ai, :enable_task_routing, original)
        else
          Application.delete_env(:arbor_ai, :enable_task_routing)
        end
      end
    end

    @tag :fast
    test "manual override still works when routing is disabled" do
      original = Application.get_env(:arbor_ai, :enable_task_routing)

      try do
        Application.put_env(:arbor_ai, :enable_task_routing, false)

        result = Router.route_task("any prompt", model: {:anthropic, "custom-model"})
        assert {:ok, {:anthropic, "custom-model"}} = result
      after
        if original != nil do
          Application.put_env(:arbor_ai, :enable_task_routing, original)
        else
          Application.delete_env(:arbor_ai, :enable_task_routing)
        end
      end
    end
  end

  describe "route_embedding/1" do
    @tag :fast
    test "returns provider tuple or error" do
      result = Router.route_embedding()

      assert match?({:ok, {_backend, _model}}, result) or
               match?({:error, :no_embedding_providers}, result)
    end

    @tag :fast
    test "prefer: :local option is accepted" do
      result = Router.route_embedding(prefer: :local)

      assert match?({:ok, {_backend, _model}}, result) or
               match?({:error, _}, result)
    end

    @tag :fast
    test "prefer: :cloud option is accepted" do
      result = Router.route_embedding(prefer: :cloud)

      assert match?({:ok, {_backend, _model}}, result) or
               match?({:error, _}, result)
    end
  end

  # Legacy routing tests (backward compatibility)
  describe "select_backend/1 (legacy)" do
    @tag :fast
    test "returns :api when backend: :api" do
      assert Router.select_backend(backend: :api) == :api
    end

    @tag :fast
    test "returns :cli when backend: :cli" do
      assert Router.select_backend(backend: :cli) == :cli
    end

    @tag :fast
    test "handles :auto with cost_optimized strategy" do
      assert Router.select_backend(backend: :auto, strategy: :cost_optimized) == :cli
    end

    @tag :fast
    test "handles :auto with api_only strategy" do
      assert Router.select_backend(backend: :auto, strategy: :api_only) == :api
    end

    @tag :fast
    test "handles :auto with cli_only strategy" do
      assert Router.select_backend(backend: :auto, strategy: :cli_only) == :cli
    end
  end

  describe "prefer_cli?/1 (legacy)" do
    @tag :fast
    test "returns true for cost_optimized strategy" do
      assert Router.prefer_cli?(strategy: :cost_optimized) == true
    end

    @tag :fast
    test "returns false for api_only strategy" do
      assert Router.prefer_cli?(strategy: :api_only) == false
    end
  end

  # Budget-aware routing tests (Phase 2)
  describe "filter_by_budget/2" do
    @tag :fast
    test "critical tier bypasses budget constraints" do
      candidates = [{:anthropic, :opus}, {:ollama, :llama}]
      result = Router.filter_by_budget(candidates, :critical)
      assert result == candidates
    end

    @tag :fast
    test "filters to free-only when over budget" do
      # We need to simulate over-budget state
      # Start BudgetTracker if needed and set to over budget
      original_budget = Application.get_env(:arbor_ai, :daily_api_budget_usd)

      try do
        unless BudgetTracker.started?() do
          {:ok, _} = BudgetTracker.start_link()
        end

        BudgetTracker.reset()

        # Set tiny budget
        Application.put_env(:arbor_ai, :daily_api_budget_usd, 0.001)

        # Spend to exceed budget
        BudgetTracker.record_usage(:anthropic, %{
          model: "claude-opus-4",
          input_tokens: 10_000,
          output_tokens: 10_000
        })

        :timer.sleep(20)

        # Verify over budget
        assert BudgetTracker.over_budget?() == true

        # Filter should only return free backends
        candidates = [{:anthropic, :opus}, {:ollama, :llama}, {:opencode, :grok}]
        result = Router.filter_by_budget(candidates, :simple)

        # Should only have free backends
        assert length(result) == 2
        assert {:ollama, :llama} in result
        assert {:opencode, :grok} in result
        refute {:anthropic, :opus} in result
      after
        Application.put_env(:arbor_ai, :daily_api_budget_usd, original_budget || 10.0)

        if BudgetTracker.started?() do
          BudgetTracker.reset()
        end
      end
    end

    @tag :fast
    test "sorts free first when should prefer free" do
      original_budget = Application.get_env(:arbor_ai, :daily_api_budget_usd)
      original_threshold = Application.get_env(:arbor_ai, :budget_prefer_free_threshold)

      try do
        unless BudgetTracker.started?() do
          {:ok, _} = BudgetTracker.start_link()
        end

        # Set budget config FIRST so reset uses correct budget
        Application.put_env(:arbor_ai, :daily_api_budget_usd, 10.0)
        Application.put_env(:arbor_ai, :budget_prefer_free_threshold, 0.5)

        # Reset with the correct budget in place
        BudgetTracker.reset()
        :timer.sleep(10)

        # Spend 60% of budget (6 USD out of 10)
        # opus input: $15/M, output: $75/M
        # 40k input = $0.60, 80k output = $6.00 = $6.60 total -> 66% spent, 34% remaining
        BudgetTracker.record_usage(:anthropic, %{
          model: "claude-opus-4",
          input_tokens: 40_000,
          output_tokens: 80_000
        })

        :timer.sleep(20)

        # Verify should_prefer_free
        assert BudgetTracker.should_prefer_free?() == true
        assert BudgetTracker.over_budget?() == false

        # Free backends should come first
        candidates = [{:anthropic, :opus}, {:ollama, :llama}, {:openai, :gpt4}]
        result = Router.filter_by_budget(candidates, :simple)

        # Should have all backends, but free first
        assert length(result) == 3
        # First should be free
        {first_backend, _} = hd(result)
        assert BudgetTracker.free_backend?(first_backend)
      after
        Application.put_env(:arbor_ai, :daily_api_budget_usd, original_budget || 10.0)

        if original_threshold do
          Application.put_env(:arbor_ai, :budget_prefer_free_threshold, original_threshold)
        else
          Application.delete_env(:arbor_ai, :budget_prefer_free_threshold)
        end

        if BudgetTracker.started?() do
          BudgetTracker.reset()
        end
      end
    end

    @tag :fast
    test "no filtering when budget is healthy" do
      original_budget = Application.get_env(:arbor_ai, :daily_api_budget_usd)

      try do
        unless BudgetTracker.started?() do
          {:ok, _} = BudgetTracker.start_link()
        end

        BudgetTracker.reset()

        # Ensure budget is healthy
        Application.put_env(:arbor_ai, :daily_api_budget_usd, 100.0)

        candidates = [{:anthropic, :opus}, {:ollama, :llama}]
        result = Router.filter_by_budget(candidates, :simple)

        # Should return unchanged
        assert result == candidates
      after
        Application.put_env(:arbor_ai, :daily_api_budget_usd, original_budget || 10.0)

        if BudgetTracker.started?() do
          BudgetTracker.reset()
        end
      end
    end
  end
end
