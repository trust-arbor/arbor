defmodule Arbor.Orchestrator.Handlers.AdaptHandlerTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Engine
  alias Arbor.Orchestrator.Engine.Context
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.{Edge, Node}
  alias Arbor.Orchestrator.Handlers.AdaptHandler

  @moduletag :adapt_handler

  # --- Helpers ---

  defp make_adapt_node(mutations_json, extra_attrs \\ %{}) do
    base = %{
      "type" => "graph.adapt",
      "shape" => "octagon",
      "mutations" => mutations_json
    }

    %Node{id: "adapt_node", attrs: Map.merge(base, extra_attrs)}
  end

  defp build_test_graph do
    %Graph{
      id: "test_graph",
      nodes: %{
        "start" => %Node{id: "start", attrs: %{"shape" => "Mdiamond", "label" => "Start"}},
        "impl_1" => %Node{id: "impl_1", attrs: %{"shape" => "box", "label" => "Implement 1"}},
        "impl_2" => %Node{id: "impl_2", attrs: %{"shape" => "box", "label" => "Implement 2"}},
        "done" => %Node{id: "done", attrs: %{"shape" => "Msquare", "label" => "Done"}}
      },
      edges: [
        %Edge{from: "start", to: "impl_1", attrs: %{}},
        %Edge{from: "impl_1", to: "impl_2", attrs: %{}},
        %Edge{from: "impl_2", to: "done", attrs: %{}}
      ],
      attrs: %{}
    }
  end

  defp run(node, context_values \\ %{}, graph \\ nil) do
    graph = graph || build_test_graph()
    context = Context.new(context_values)
    AdaptHandler.execute(node, context, graph, [])
  end

  # ==============================
  # Static mutations attribute
  # ==============================

  describe "static mutations" do
    test "executes mutation from static mutations attribute" do
      mutations =
        Jason.encode!([
          %{"op" => "add_node", "id" => "review", "attrs" => %{"shape" => "box"}}
        ])

      node = make_adapt_node(mutations)
      outcome = run(node)

      assert outcome.status == :success
      assert %Graph{} = outcome.context_updates["__adapted_graph__"]
      adapted = outcome.context_updates["__adapted_graph__"]
      assert Map.has_key?(adapted.nodes, "review")
      assert outcome.context_updates["adapt.adapt_node.version"] == 1
      assert outcome.context_updates["adapt.adapt_node.applied_ops"] == 1
    end
  end

  # ==============================
  # Dynamic mutations_key
  # ==============================

  describe "dynamic mutations_key" do
    test "executes mutation from dynamic context key" do
      mutations =
        Jason.encode!([
          %{"op" => "add_node", "id" => "dynamic_step", "attrs" => %{"shape" => "box"}}
        ])

      node = %Node{
        id: "adapt_dyn",
        attrs: %{
          "type" => "graph.adapt",
          "shape" => "octagon",
          "mutations_key" => "my_mutations"
        }
      }

      outcome = run(node, %{"my_mutations" => mutations})

      assert outcome.status == :success
      adapted = outcome.context_updates["__adapted_graph__"]
      assert %Graph{} = adapted
      assert Map.has_key?(adapted.nodes, "dynamic_step")
    end
  end

  # ==============================
  # Failure cases
  # ==============================

  describe "failure cases" do
    test "fails when no mutations provided" do
      node = %Node{
        id: "adapt_empty",
        attrs: %{"type" => "graph.adapt", "shape" => "octagon"}
      }

      outcome = run(node)

      assert outcome.status == :fail
      assert outcome.failure_reason =~ "no mutations provided"
    end

    test "fails when mutations JSON is invalid" do
      node = make_adapt_node("{not valid json!!")
      outcome = run(node)

      assert outcome.status == :fail
      assert outcome.failure_reason =~ "JSON decode error"
    end

    test "fails when max_mutations exceeded" do
      ops =
        Enum.map(1..5, fn i ->
          %{"op" => "add_node", "id" => "n#{i}", "attrs" => %{"shape" => "box"}}
        end)

      mutations = Jason.encode!(ops)
      node = make_adapt_node(mutations, %{"max_mutations" => "3"})
      outcome = run(node)

      assert outcome.status == :fail
      assert outcome.failure_reason =~ "too many mutations"
      assert outcome.failure_reason =~ "5"
      assert outcome.failure_reason =~ "3"
    end

    test "fails when validation fails (remove start node)" do
      mutations = Jason.encode!([%{"op" => "remove_node", "id" => "start"}])
      node = make_adapt_node(mutations)
      outcome = run(node)

      assert outcome.status == :fail
      assert outcome.failure_reason =~ "cannot remove start node"
    end

    test "fails when mutations is empty string" do
      node = make_adapt_node("")
      outcome = run(node)

      assert outcome.status == :fail
      assert outcome.failure_reason =~ "no mutations provided"
    end
  end

  # ==============================
  # dry_run
  # ==============================

  describe "dry_run" do
    test "validates without applying" do
      mutations =
        Jason.encode!([
          %{"op" => "add_node", "id" => "phantom", "attrs" => %{"shape" => "box"}}
        ])

      node = make_adapt_node(mutations, %{"dry_run" => "true"})
      outcome = run(node)

      assert outcome.status == :success
      assert outcome.notes =~ "dry run"
      assert outcome.notes =~ "1 mutation(s) validated"
      assert outcome.context_updates == %{}
    end

    test "still fails on invalid mutations in dry_run" do
      mutations = Jason.encode!([%{"op" => "remove_node", "id" => "start"}])
      node = make_adapt_node(mutations, %{"dry_run" => "true"})
      outcome = run(node)

      assert outcome.status == :fail
      assert outcome.failure_reason =~ "cannot remove start node"
    end
  end

  # ==============================
  # Context updates / metadata
  # ==============================

  describe "metadata" do
    test "stores version and applied_ops in context_updates" do
      mutations =
        Jason.encode!([
          %{"op" => "add_node", "id" => "step_a", "attrs" => %{"shape" => "box"}},
          %{"op" => "add_edge", "from" => "impl_1", "to" => "impl_2"}
        ])

      node = make_adapt_node(mutations)
      outcome = run(node)

      assert outcome.status == :success
      assert outcome.context_updates["adapt.adapt_node.version"] == 1
      assert outcome.context_updates["adapt.adapt_node.applied_ops"] == 2
    end

    test "stores adapted graph in context_updates" do
      mutations =
        Jason.encode!([
          %{"op" => "add_node", "id" => "new_one", "attrs" => %{"shape" => "box"}}
        ])

      node = make_adapt_node(mutations)
      outcome = run(node)

      assert outcome.status == :success
      adapted = outcome.context_updates["__adapted_graph__"]
      assert %Graph{} = adapted
      assert Map.has_key?(adapted.nodes, "new_one")
      # Original nodes should still be present
      assert Map.has_key?(adapted.nodes, "start")
      assert Map.has_key?(adapted.nodes, "impl_1")
      assert Map.has_key?(adapted.nodes, "impl_2")
      assert Map.has_key?(adapted.nodes, "done")
    end
  end

  # ==============================
  # Completed nodes interaction
  # ==============================

  describe "completed nodes" do
    test "respects completed nodes from context" do
      mutations = Jason.encode!([%{"op" => "remove_node", "id" => "impl_1"}])
      node = make_adapt_node(mutations)
      outcome = run(node, %{"__completed_nodes__" => ["impl_1"]})

      assert outcome.status == :fail
      assert outcome.failure_reason =~ "already completed"
    end
  end

  # ==============================
  # Multiple operations
  # ==============================

  describe "multiple operations" do
    test "applies multiple operations in a single adapt call" do
      mutations =
        Jason.encode!([
          %{
            "op" => "add_node",
            "id" => "review",
            "attrs" => %{"shape" => "box", "label" => "Review"}
          },
          %{"op" => "remove_edge", "from" => "impl_2", "to" => "done"},
          %{"op" => "add_edge", "from" => "impl_1", "to" => "done"}
        ])

      node = make_adapt_node(mutations)
      outcome = run(node)

      assert outcome.status == :success
      assert outcome.context_updates["adapt.adapt_node.applied_ops"] == 3

      adapted = outcome.context_updates["__adapted_graph__"]
      assert adapted != nil
      assert Map.has_key?(adapted.nodes, "review")
      refute Enum.any?(adapted.edges, fn e -> e.from == "impl_2" and e.to == "done" end)
      assert Enum.any?(adapted.edges, fn e -> e.from == "impl_1" and e.to == "done" end)
    end
  end

  # ==============================
  # Trust-tier constraints
  # ==============================

  # The trust-tier band was retired (tiers-retirement phase 3c). The adapt
  # node's `trust_tier` attribute is now a no-op — mutations are governed by
  # the agent's granular baseline/rules + capability checks, not by a tier.
  describe "trust_tier attr is ignored (no-op)" do
    test "an add_node mutation succeeds regardless of the trust_tier attr" do
      mutations = Jason.encode!([%{"op" => "add_node", "id" => "new"}])

      # Previously a "probationary" node + "untrusted" session was rejected.
      node = make_adapt_node(mutations, %{"trust_tier" => "probationary"})
      outcome = run(node, %{"session.trust_tier" => "untrusted"})

      assert outcome.status == :success
    end

    test "all operations succeed irrespective of the trust_tier attr" do
      mutations =
        Jason.encode!([
          %{"op" => "add_node", "id" => "new", "attrs" => %{"shape" => "box"}},
          %{"op" => "add_edge", "from" => "impl_1", "to" => "new"}
        ])

      node = make_adapt_node(mutations, %{"trust_tier" => "trusted"})
      outcome = run(node, %{"session.trust_tier" => "trusted"})

      assert outcome.status == :success
    end

    test "no trust_tier attr also allows everything" do
      mutations =
        Jason.encode!([
          %{"op" => "add_node", "id" => "anything", "attrs" => %{"shape" => "box"}}
        ])

      node = make_adapt_node(mutations)
      outcome = run(node)

      assert outcome.status == :success
    end
  end

  # ==============================
  # Idempotency
  # ==============================

  describe "idempotency" do
    test "is side_effecting" do
      assert AdaptHandler.idempotency() == :side_effecting
    end
  end

  # ==============================
  # Engine integration (graph swap)
  # ==============================

  describe "engine integration" do
    test "engine swaps graph when __adapted_graph__ is in context" do
      # Build a graph that has an adapt node which adds a new step
      mutations =
        Jason.encode!([
          %{
            "op" => "add_node",
            "id" => "injected",
            "attrs" => %{"shape" => "box", "type" => "start"}
          },
          %{"op" => "add_edge", "from" => "adapt_step", "to" => "injected"},
          %{"op" => "remove_edge", "from" => "adapt_step", "to" => "done"},
          %{"op" => "add_edge", "from" => "injected", "to" => "done"}
        ])

      graph = %Graph{
        id: "adapt_integration",
        nodes: %{
          "start" => %Node{id: "start", attrs: %{"shape" => "Mdiamond"}},
          "adapt_step" => %Node{
            id: "adapt_step",
            attrs: %{
              "type" => "graph.adapt",
              "shape" => "octagon",
              "mutations" => mutations
            }
          },
          "done" => %Node{id: "done", attrs: %{"shape" => "Msquare"}}
        },
        edges: [
          %Edge{from: "start", to: "adapt_step", attrs: %{}},
          %Edge{from: "adapt_step", to: "done", attrs: %{}}
        ],
        attrs: %{"goal" => "test adapt"}
      }

      assert {:ok, result} = Engine.run(graph)

      # The injected node should have been reached
      assert "injected" in result.completed_nodes
      assert "adapt_step" in result.completed_nodes
      assert "done" in result.completed_nodes
    end
  end
end
