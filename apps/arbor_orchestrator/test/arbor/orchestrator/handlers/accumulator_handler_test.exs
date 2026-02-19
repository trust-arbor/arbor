defmodule Arbor.Orchestrator.Handlers.AccumulatorHandlerTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Engine.Context
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Handlers.AccumulatorHandler

  @graph %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

  defp make_node(id, attrs) do
    %Node{id: id, attrs: Map.merge(%{"type" => "accumulator"}, attrs)}
  end

  describe "execute/4 — numeric operations" do
    test "sum accumulates numbers" do
      node = make_node("s1", %{"operation" => "sum", "input_key" => "val"})
      context = Context.new(%{"val" => 5})

      outcome = AccumulatorHandler.execute(node, context, @graph, [])
      assert outcome.status == :success
      assert outcome.context_updates["accumulator.s1"] == "5"

      # Second accumulation
      context2 = Context.new(%{"val" => 3, "accumulator.s1" => "5"})
      outcome2 = AccumulatorHandler.execute(node, context2, @graph, [])
      assert outcome2.status == :success
      assert outcome2.context_updates["accumulator.s1"] == "8"
    end

    test "count increments regardless of input value" do
      node = make_node("c1", %{"operation" => "count", "input_key" => "item"})
      context = Context.new(%{"item" => "anything"})

      outcome = AccumulatorHandler.execute(node, context, @graph, [])
      assert outcome.status == :success
      assert outcome.context_updates["accumulator.c1"] == "1"

      context2 = Context.new(%{"item" => "other", "accumulator.c1" => "1"})
      outcome2 = AccumulatorHandler.execute(node, context2, @graph, [])
      assert outcome2.context_updates["accumulator.c1"] == "2"
    end

    test "min tracks minimum value" do
      node = make_node("m1", %{"operation" => "min", "input_key" => "val"})

      outcome1 = AccumulatorHandler.execute(node, Context.new(%{"val" => 10}), @graph, [])
      assert outcome1.status == :success

      context2 = Context.new(%{"val" => 3, "accumulator.m1" => "10"})
      outcome2 = AccumulatorHandler.execute(node, context2, @graph, [])
      assert outcome2.context_updates["accumulator.m1"] == "3"

      context3 = Context.new(%{"val" => 7, "accumulator.m1" => "3"})
      outcome3 = AccumulatorHandler.execute(node, context3, @graph, [])
      assert outcome3.context_updates["accumulator.m1"] == "3"
    end

    test "max tracks maximum value" do
      node = make_node("mx", %{"operation" => "max", "input_key" => "val"})

      context1 = Context.new(%{"val" => 5, "accumulator.mx" => "-1.0e308"})
      outcome1 = AccumulatorHandler.execute(node, context1, @graph, [])
      assert outcome1.context_updates["accumulator.mx"] == "5"

      context2 = Context.new(%{"val" => 2, "accumulator.mx" => "5"})
      outcome2 = AccumulatorHandler.execute(node, context2, @graph, [])
      assert outcome2.context_updates["accumulator.mx"] == "5"
    end

    test "product multiplies values" do
      node = make_node("p1", %{"operation" => "product", "input_key" => "val"})

      outcome1 = AccumulatorHandler.execute(node, Context.new(%{"val" => 3}), @graph, [])
      assert outcome1.context_updates["accumulator.p1"] == "3"

      context2 = Context.new(%{"val" => 4, "accumulator.p1" => "3"})
      outcome2 = AccumulatorHandler.execute(node, context2, @graph, [])
      assert outcome2.context_updates["accumulator.p1"] == "12"
    end

    test "avg computes running average" do
      node = make_node("a1", %{"operation" => "avg", "input_key" => "val"})

      outcome1 = AccumulatorHandler.execute(node, Context.new(%{"val" => 10}), @graph, [])
      assert outcome1.status == :success
      assert outcome1.context_updates["accumulator.a1.avg"] == "10.0"

      context2 =
        Context.new(%{
          "val" => 20,
          "accumulator.a1" => outcome1.context_updates["accumulator.a1"]
        })

      outcome2 = AccumulatorHandler.execute(node, context2, @graph, [])
      assert outcome2.context_updates["accumulator.a1.avg"] == "15.0"
    end
  end

  describe "execute/4 — collection operations" do
    test "append adds to end of list" do
      node = make_node("ap", %{"operation" => "append", "input_key" => "item"})

      outcome1 = AccumulatorHandler.execute(node, Context.new(%{"item" => "a"}), @graph, [])
      assert outcome1.status == :success
      assert Jason.decode!(outcome1.context_updates["accumulator.ap"]) == ["a"]

      context2 =
        Context.new(%{
          "item" => "b",
          "accumulator.ap" => outcome1.context_updates["accumulator.ap"]
        })

      outcome2 = AccumulatorHandler.execute(node, context2, @graph, [])
      assert Jason.decode!(outcome2.context_updates["accumulator.ap"]) == ["a", "b"]
    end

    test "prepend adds to front of list" do
      node = make_node("pr", %{"operation" => "prepend", "input_key" => "item"})

      outcome1 = AccumulatorHandler.execute(node, Context.new(%{"item" => "a"}), @graph, [])
      assert Jason.decode!(outcome1.context_updates["accumulator.pr"]) == ["a"]

      context2 =
        Context.new(%{
          "item" => "b",
          "accumulator.pr" => outcome1.context_updates["accumulator.pr"]
        })

      outcome2 = AccumulatorHandler.execute(node, context2, @graph, [])
      assert Jason.decode!(outcome2.context_updates["accumulator.pr"]) == ["b", "a"]
    end

    test "merge deep-merges maps" do
      node = make_node("mg", %{"operation" => "merge", "input_key" => "data"})
      input = Jason.encode!(%{"a" => 1, "b" => %{"x" => 1}})

      outcome1 = AccumulatorHandler.execute(node, Context.new(%{"data" => input}), @graph, [])
      assert outcome1.status == :success

      input2 = Jason.encode!(%{"b" => %{"y" => 2}, "c" => 3})

      context2 =
        Context.new(%{
          "data" => input2,
          "accumulator.mg" => outcome1.context_updates["accumulator.mg"]
        })

      outcome2 = AccumulatorHandler.execute(node, context2, @graph, [])
      merged = Jason.decode!(outcome2.context_updates["accumulator.mg"])
      assert merged["a"] == 1
      assert merged["b"]["x"] == 1
      assert merged["b"]["y"] == 2
      assert merged["c"] == 3
    end

    test "concat joins strings" do
      node = make_node("cc", %{"operation" => "concat", "input_key" => "text"})

      outcome1 = AccumulatorHandler.execute(node, Context.new(%{"text" => "hello"}), @graph, [])
      assert outcome1.context_updates["accumulator.cc"] == "hello"

      context2 = Context.new(%{"text" => " world", "accumulator.cc" => "hello"})
      outcome2 = AccumulatorHandler.execute(node, context2, @graph, [])
      assert outcome2.context_updates["accumulator.cc"] == "hello world"
    end
  end

  describe "execute/4 — custom accumulator_key" do
    test "uses custom key instead of default" do
      node =
        make_node("ck", %{
          "operation" => "sum",
          "input_key" => "val",
          "accumulator_key" => "my_total"
        })

      context = Context.new(%{"val" => 7})
      outcome = AccumulatorHandler.execute(node, context, @graph, [])
      assert outcome.context_updates["my_total"] == "7"
      refute Map.has_key?(outcome.context_updates, "accumulator.ck")
    end
  end

  describe "execute/4 — limits" do
    test "limit with fail action stops on exceed" do
      node =
        make_node("lf", %{
          "operation" => "sum",
          "input_key" => "val",
          "limit" => "10",
          "limit_action" => "fail"
        })

      context = Context.new(%{"val" => 15})
      outcome = AccumulatorHandler.execute(node, context, @graph, [])
      assert outcome.status == :fail
      assert String.contains?(outcome.failure_reason, "exceeded limit")
    end

    test "limit with warn action succeeds with warning" do
      node =
        make_node("lw", %{
          "operation" => "sum",
          "input_key" => "val",
          "limit" => "10",
          "limit_action" => "warn"
        })

      context = Context.new(%{"val" => 15})
      outcome = AccumulatorHandler.execute(node, context, @graph, [])
      assert outcome.status == :success
      assert outcome.context_updates["accumulator.lw.limit_exceeded"] == "true"
    end

    test "limit with cap action caps numeric value" do
      node =
        make_node("lc", %{
          "operation" => "sum",
          "input_key" => "val",
          "limit" => "10",
          "limit_action" => "cap"
        })

      context = Context.new(%{"val" => 15})
      outcome = AccumulatorHandler.execute(node, context, @graph, [])
      assert outcome.status == :success
      assert outcome.context_updates["accumulator.lc"] == "10"
    end

    test "list limit with cap truncates" do
      node =
        make_node("llc", %{
          "operation" => "append",
          "input_key" => "item",
          "limit" => "2",
          "limit_action" => "cap"
        })

      context =
        Context.new(%{
          "item" => "c",
          "accumulator.llc" => Jason.encode!(["a", "b"])
        })

      outcome = AccumulatorHandler.execute(node, context, @graph, [])
      assert outcome.status == :success
      assert length(Jason.decode!(outcome.context_updates["accumulator.llc"])) <= 2
    end
  end

  describe "execute/4 — error handling" do
    test "missing operation fails" do
      node = make_node("e1", %{"input_key" => "val"})
      outcome = AccumulatorHandler.execute(node, Context.new(%{"val" => 1}), @graph, [])
      assert outcome.status == :fail
      assert String.contains?(outcome.failure_reason, "requires 'operation'")
    end

    test "missing input_key fails" do
      node = make_node("e2", %{"operation" => "sum"})
      outcome = AccumulatorHandler.execute(node, Context.new(), @graph, [])
      assert outcome.status == :fail
      assert String.contains?(outcome.failure_reason, "requires 'input_key'")
    end

    test "unknown operation fails" do
      node = make_node("e3", %{"operation" => "divide", "input_key" => "val"})
      outcome = AccumulatorHandler.execute(node, Context.new(%{"val" => 1}), @graph, [])
      assert outcome.status == :fail
      assert String.contains?(outcome.failure_reason, "unknown accumulator operation")
    end

    test "non-numeric input for sum fails gracefully" do
      node = make_node("e4", %{"operation" => "sum", "input_key" => "val"})

      outcome =
        AccumulatorHandler.execute(node, Context.new(%{"val" => "not_a_number"}), @graph, [])

      assert outcome.status == :fail
      assert String.contains?(outcome.failure_reason, "cannot convert")
    end
  end

  describe "execute/4 — metadata" do
    test "stores operation metadata in context" do
      node = make_node("md", %{"operation" => "sum", "input_key" => "val"})
      context = Context.new(%{"val" => 5})

      outcome = AccumulatorHandler.execute(node, context, @graph, [])
      assert outcome.context_updates["accumulator.md.operation"] == "sum"
      assert outcome.context_updates["accumulator.md.input"] == "5"
      assert outcome.context_updates["accumulator.md.previous"] == ""
    end
  end

  describe "idempotency/0" do
    test "returns :idempotent" do
      assert AccumulatorHandler.idempotency() == :idempotent
    end
  end

  describe "registry" do
    test "accumulator type resolves to WriteHandler (Phase 4 delegation)" do
      node = make_node("reg", %{})

      assert Arbor.Orchestrator.Handlers.Registry.resolve(node) ==
               Arbor.Orchestrator.Handlers.WriteHandler
    end

    test "accumulator type injects target attribute via resolve_with_attrs" do
      node = make_node("reg", %{})
      {handler, resolved_node} = Arbor.Orchestrator.Handlers.Registry.resolve_with_attrs(node)
      assert handler == Arbor.Orchestrator.Handlers.WriteHandler
      assert resolved_node.attrs["target"] == "accumulator"
      assert resolved_node.attrs["mode"] == "append"
    end
  end
end
