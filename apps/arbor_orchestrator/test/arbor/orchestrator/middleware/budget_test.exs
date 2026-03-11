defmodule Arbor.Orchestrator.Middleware.BudgetTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Orchestrator.Engine.{Context, Outcome}
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Middleware.{Budget, Token}

  defmodule OkTracker do
    def check_budget, do: :ok
    def record_usage(_usage), do: :ok
  end

  defmodule OverBudgetTracker do
    def check_budget, do: {:over_budget, "token limit reached"}
    def record_usage(_usage), do: :ok
  end

  defmodule CrashingTracker do
    def check_budget, do: :ok
    def record_usage(_usage), do: raise("boom")
  end

  defp make_token(attrs \\ %{}, assigns \\ %{}) do
    node = %Node{id: "budget_node", attrs: Map.merge(%{"type" => "compute"}, attrs)}
    context = %Context{values: %{}}
    graph = %Graph{nodes: %{"budget_node" => node}, edges: [], attrs: %{}}
    %Token{node: node, context: context, graph: graph, assigns: assigns}
  end

  defp make_compiled_node(overrides) do
    defaults = %{
      id: "compiled_node",
      attrs: %{"type" => "compute"},
      type: "compute",
      capabilities_required: [],
      taint_profile: nil,
      llm_model: nil,
      llm_provider: nil,
      timeout_ms: nil,
      handler_module: nil
    }

    struct(Node, Map.merge(defaults, overrides))
  end

  defp make_token_with_tracker(tracker, outcome_updates) do
    token = make_token(%{}, %{budget_tracker: tracker})

    if outcome_updates do
      %{
        token
        | outcome: %Outcome{
            status: :success,
            notes: "ok",
            context_updates: outcome_updates
          }
      }
    else
      token
    end
  end

  # --- before_node ---

  describe "before_node/1" do
    test "passes through when skip_budget_check is set" do
      token = make_token(%{}, %{skip_budget_check: true, budget_tracker: OverBudgetTracker})
      result = Budget.before_node(token)
      refute result.halted
    end

    test "passes through when no budget tracker configured" do
      token = make_token()
      result = Budget.before_node(token)
      refute result.halted
    end

    test "passes through when budget tracker is nil" do
      token = make_token(%{}, %{budget_tracker: nil})
      result = Budget.before_node(token)
      refute result.halted
    end

    test "passes through when module tracker returns :ok" do
      token = make_token(%{}, %{budget_tracker: OkTracker})
      result = Budget.before_node(token)
      refute result.halted
    end

    test "halts when module tracker returns over_budget" do
      token = make_token(%{}, %{budget_tracker: OverBudgetTracker})
      result = Budget.before_node(token)
      assert result.halted
      assert result.halt_reason =~ "Budget exceeded"
      assert result.halt_reason =~ "token limit reached"
      assert result.outcome.status == :fail
    end

    test "passes through for non-existent tracker module" do
      token = make_token(%{}, %{budget_tracker: NonExistentModule})
      result = Budget.before_node(token)
      refute result.halted
    end

    test "passes through for dead pid tracker" do
      {:ok, pid} = Agent.start(fn -> :ok end)
      Agent.stop(pid)
      token = make_token(%{}, %{budget_tracker: pid})
      result = Budget.before_node(token)
      refute result.halted
    end
  end

  # --- after_node ---

  describe "after_node/1" do
    test "passes through when skip_budget_check is set" do
      token = make_token_with_tracker(OkTracker, %{"llm.tokens_used" => 100})
      token = %{token | assigns: Map.put(token.assigns, :skip_budget_check, true)}
      result = Budget.after_node(token)
      refute result.halted
    end

    test "passes through when no tracker configured" do
      token = make_token()
      token = %{token | outcome: %Outcome{status: :success, context_updates: %{}}}
      result = Budget.after_node(token)
      refute result.halted
    end

    test "records usage when tracker and outcome present" do
      token = make_token_with_tracker(OkTracker, %{"llm.tokens_used" => 500, "llm.cost" => 0.01})
      result = Budget.after_node(token)
      refute result.halted
    end

    test "survives crashing record_usage gracefully" do
      token =
        make_token_with_tracker(CrashingTracker, %{"llm.tokens_used" => 100})

      result = Budget.after_node(token)
      # Should not crash — rescued internally
      refute result.halted
    end

    test "passes through when no outcome" do
      token = make_token(%{}, %{budget_tracker: OkTracker})
      result = Budget.after_node(token)
      refute result.halted
    end
  end

  # --- build_cost_hint ---

  describe "build_cost_hint/1" do
    test "extracts model, timeout, and type from compiled node" do
      node =
        make_compiled_node(%{
          llm_model: "claude-opus-4-6",
          timeout_ms: 60_000,
          type: "codergen"
        })

      hint = Budget.build_cost_hint(node)
      assert hint[:model] == "claude-opus-4-6"
      assert hint[:timeout_ms] == 60_000
      assert hint[:handler_type] == "codergen"
    end

    test "omits nil model" do
      node = make_compiled_node(%{llm_model: nil, timeout_ms: 5000, type: "compute"})
      hint = Budget.build_cost_hint(node)
      refute Map.has_key?(hint, :model)
      assert hint[:timeout_ms] == 5000
    end

    test "omits nil timeout" do
      node = make_compiled_node(%{llm_model: "gpt-4", timeout_ms: nil, type: "compute"})
      hint = Budget.build_cost_hint(node)
      assert hint[:model] == "gpt-4"
      refute Map.has_key?(hint, :timeout_ms)
    end

    test "falls back to attrs type when node.type is nil" do
      node = make_compiled_node(%{type: nil, attrs: %{"type" => "shell"}})
      hint = Budget.build_cost_hint(node)
      assert hint[:handler_type] == "shell"
    end

    test "omits handler_type when both type and attrs type are nil" do
      node = make_compiled_node(%{type: nil, attrs: %{}})
      hint = Budget.build_cost_hint(node)
      refute Map.has_key?(hint, :handler_type)
    end

    test "returns empty map when all fields are nil" do
      node = make_compiled_node(%{llm_model: nil, timeout_ms: nil, type: nil, attrs: %{}})
      hint = Budget.build_cost_hint(node)
      assert hint == %{}
    end
  end
end
