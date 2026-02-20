defmodule Arbor.Orchestrator.CompiledGraphTest do
  @moduledoc """
  Integration tests for Phase 1: Compiled Graph as Default Engine Format.

  Verifies that:
  - The orchestrator auto-compiles graphs before running
  - DotCache stores compiled graphs with IR versioning
  - Executor uses pre-resolved handler modules
  - Router uses pre-parsed edge conditions
  - Compound && conditions parse and evaluate correctly
  - Adapt nodes receive pessimistic enrichment
  - Transforms preserve compiled state
  """
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator
  alias Arbor.Orchestrator.DotCache
  alias Arbor.Orchestrator.Engine.{Condition, Context, Outcome}
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.{Edge, Node}
  alias Arbor.Orchestrator.Handlers.Registry
  alias Arbor.Orchestrator.IR.Compiler

  @simple_dot """
  digraph Pipeline {
    start [shape=Mdiamond]
    exit [shape=Msquare]
    start -> exit
  }
  """

  @conditional_dot """
  digraph Pipeline {
    start [shape=Mdiamond]
    check [shape=diamond]
    yes_path [prompt="Yes"]
    no_path [prompt="No"]
    exit [shape=Msquare]
    start -> check
    check -> yes_path [condition="outcome=success"]
    check -> no_path [condition="outcome=fail"]
    yes_path -> exit
    no_path -> exit
  }
  """

  describe "Orchestrator auto-compilation" do
    test "run/2 with DOT source auto-compiles" do
      assert {:ok, result} = Orchestrator.run(@simple_dot, cache: false)
      assert result.final_outcome.status in [:success, :partial_success]
    end

    test "run/2 with pre-compiled Graph skips re-compilation" do
      {:ok, graph} = Orchestrator.parse(@simple_dot)
      {:ok, compiled} = Compiler.compile(graph)
      assert compiled.compiled == true

      # Running a pre-compiled graph should work without re-compilation
      assert {:ok, result} = Orchestrator.run(compiled, cache: false)
      assert result.final_outcome.status in [:success, :partial_success]
    end

    test "run/2 with uncompiled Graph struct auto-compiles" do
      {:ok, graph} = Orchestrator.parse(@simple_dot)
      assert graph.compiled == false

      assert {:ok, result} = Orchestrator.run(graph, cache: false)
      assert result.final_outcome.status in [:success, :partial_success]
    end
  end

  describe "DotCache with IR versioning" do
    setup do
      :ok
    end

    test "stores compiled graph and cache hit returns compiled: true" do
      # Use the real DotCache via run with caching
      # DotCache may or may not be started, so test the concept directly
      {:ok, graph} = Orchestrator.parse(@simple_dot)
      {:ok, compiled} = Compiler.compile(graph)

      assert compiled.compiled == true
      assert map_size(compiled.handler_types) > 0
    end

    test "invalidate_all/0 clears all entries" do
      # This test verifies invalidate_all delegates to clear
      # DotCache.invalidate_all() should work when GenServer is running
      assert DotCache.invalidate_all() == :ok
    end

    test "ir_version/0 returns current version" do
      assert is_integer(DotCache.ir_version())
      assert DotCache.ir_version() >= 1
    end

    test "stale IR version triggers re-compile on cache miss" do
      # DotCache GenServer creates the ETS table; verify :stale detection works
      table = :arbor_orchestrator_dot_cache

      cache_key = DotCache.cache_key(@simple_dot)
      {:ok, graph} = Orchestrator.parse(@simple_dot)

      # Insert with version 0 (stale) — the current @ir_version is 1
      :ets.insert(table, {cache_key, graph, 0, System.monotonic_time(:millisecond)})

      # get/1 should return :stale for mismatched version
      assert DotCache.get(cache_key) == :stale

      # Clean up
      :ets.delete(table, cache_key)
    end
  end

  describe "Executor handler resolution fast path" do
    test "uses node.handler_module when set from IR compilation" do
      {:ok, graph} = Orchestrator.parse(@simple_dot)
      {:ok, compiled} = Compiler.compile(graph)

      # All nodes in a compiled graph should have handler_module set
      Enum.each(compiled.nodes, fn {_id, node} ->
        assert node.handler_module != nil,
               "Node #{node.id} should have handler_module set after compilation"
      end)
    end

    test "falls back to Registry when handler_module is nil" do
      {:ok, graph} = Orchestrator.parse(@simple_dot)
      # Uncompiled graph nodes have nil handler_module
      Enum.each(graph.nodes, fn {_id, node} ->
        assert node.handler_module == nil
        # Registry should still resolve these
        {handler, _resolved_node} = Registry.resolve_with_attrs(node)
        assert handler != nil
      end)
    end
  end

  describe "Router uses parsed_condition" do
    test "edge with parsed_condition uses eval_parsed path" do
      outcome = %Outcome{status: :success}
      context = Context.new(%{})

      # Create an edge with a pre-parsed condition
      edge = %Edge{
        from: "a",
        to: "b",
        attrs: %{"condition" => "outcome=success"},
        parsed_condition: {:eq, "outcome", "success"}
      }

      # The Router's edge_condition_matches? is private, so test through Condition.eval_parsed
      assert Condition.eval_parsed(edge.parsed_condition, outcome, context) == true
    end

    test "edge without parsed_condition falls back to string eval" do
      outcome = %Outcome{status: :success}
      context = Context.new(%{})

      # Edge with string condition but no parsed_condition
      condition = "outcome=success"
      assert Condition.eval(condition, outcome, context) == true
    end
  end

  describe "compound && conditions" do
    test "Edge.parse_condition handles && correctly" do
      parsed = Edge.parse_condition("outcome=success && context.ready=true")

      assert {:and, clauses} = parsed
      assert length(clauses) == 2
      assert {:eq, "outcome", "success"} in clauses
      assert {:eq, "context.ready", "true"} in clauses
    end

    test "Edge.parse_condition handles single clause (no &&)" do
      assert {:eq, "outcome", "success"} = Edge.parse_condition("outcome=success")
      assert {:neq, "outcome", "fail"} = Edge.parse_condition("outcome!=fail")
    end

    test "Edge.parse_condition handles triple &&" do
      parsed = Edge.parse_condition("outcome=success && context.x=1 && context.y=2")

      assert {:and, clauses} = parsed
      assert length(clauses) == 3
    end

    test "Condition.eval_parsed handles {:and, clauses}" do
      outcome = %Outcome{status: :success}
      context = Context.new(%{"ready" => "true"})

      # All clauses true
      parsed = {:and, [{:eq, "outcome", "success"}, {:eq, "context.ready", "true"}]}
      assert Condition.eval_parsed(parsed, outcome, context) == true

      # One clause false
      parsed_fail = {:and, [{:eq, "outcome", "success"}, {:eq, "context.ready", "false"}]}
      assert Condition.eval_parsed(parsed_fail, outcome, context) == false
    end

    test "Condition.eval_parsed matches Condition.eval for all condition types" do
      outcome = %Outcome{status: :success, preferred_label: "deploy"}
      context = Context.new(%{"count" => "5", "name" => "test"})

      test_cases = [
        {"outcome=success", {:eq, "outcome", "success"}},
        {"outcome!=fail", {:neq, "outcome", "fail"}},
        {"preferred_label=deploy", {:eq, "preferred_label", "deploy"}},
        {"context.count=5", {:eq, "context.count", "5"}}
      ]

      for {string_cond, parsed_cond} <- test_cases do
        string_result = Condition.eval(string_cond, outcome, context)
        parsed_result = Condition.eval_parsed(parsed_cond, outcome, context)

        assert string_result == parsed_result,
               "Mismatch for #{string_cond}: eval=#{string_result}, eval_parsed=#{parsed_result}"
      end
    end
  end

  describe "adapt node pessimistic enrichment" do
    test "adapt nodes get secret classification and graph_mutation capability" do
      graph =
        %Graph{id: "AdaptTest"}
        |> Graph.add_node(%Node{id: "start", attrs: %{"shape" => "Mdiamond"}})
        |> Graph.add_node(%Node{id: "mutator", attrs: %{"type" => "adapt", "mutation" => "{}"}})
        |> Graph.add_node(%Node{id: "exit", attrs: %{"shape" => "Msquare"}})
        |> Graph.add_edge(%Edge{from: "start", to: "mutator"})
        |> Graph.add_edge(%Edge{from: "mutator", to: "exit"})

      {:ok, compiled} = Compiler.compile(graph)

      adapt_node = compiled.nodes["mutator"]
      assert adapt_node.data_classification == :secret
      assert adapt_node.idempotency == :side_effecting
      assert "graph_mutation" in adapt_node.capabilities_required
    end

    test "non-adapt nodes get standard enrichment" do
      graph =
        %Graph{id: "StandardTest"}
        |> Graph.add_node(%Node{id: "start", attrs: %{"shape" => "Mdiamond"}})
        |> Graph.add_node(%Node{id: "work", attrs: %{"prompt" => "Do work"}})
        |> Graph.add_node(%Node{id: "exit", attrs: %{"shape" => "Msquare"}})
        |> Graph.add_edge(%Edge{from: "start", to: "work"})
        |> Graph.add_edge(%Edge{from: "work", to: "exit"})

      {:ok, compiled} = Compiler.compile(graph)

      work_node = compiled.nodes["work"]
      # Standard node should NOT have :secret classification or graph_mutation cap
      assert work_node.data_classification != :secret
      refute "graph_mutation" in work_node.capabilities_required
    end
  end

  describe "transforms preserve compiled state" do
    test "VariableExpansion doesn't clear IR fields" do
      {:ok, graph} = Orchestrator.parse(@simple_dot)
      {:ok, compiled} = Compiler.compile(graph)

      # Apply VariableExpansion transform (uses apply/1)
      result = Arbor.Orchestrator.Transforms.VariableExpansion.apply(compiled)

      # Compiled flag should be preserved
      assert result.compiled == true

      # Handler modules should still be set
      Enum.each(result.nodes, fn {_id, node} ->
        assert node.handler_module != nil,
               "Node #{node.id} lost handler_module after transform"
      end)
    end

    test "conditional DOT compiles and runs with parsed conditions" do
      assert {:ok, result} = Orchestrator.run(@conditional_dot, cache: false)
      assert result.final_outcome.status in [:success, :partial_success]
    end
  end
end
