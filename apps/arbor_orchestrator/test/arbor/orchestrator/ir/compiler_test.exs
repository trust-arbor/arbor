defmodule Arbor.Orchestrator.IR.CompilerTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.{Node, Edge}
  alias Arbor.Orchestrator.IR.{Compiler, TypedGraph, TypedNode, TypedEdge}

  defp simple_graph do
    %Graph{id: "Test"}
    |> Graph.add_node(%Node{id: "start", attrs: %{"shape" => "Mdiamond"}})
    |> Graph.add_node(%Node{id: "work", attrs: %{"prompt" => "Do something"}})
    |> Graph.add_node(%Node{id: "done", attrs: %{"shape" => "Msquare"}})
    |> Graph.add_edge(%Edge{from: "start", to: "work"})
    |> Graph.add_edge(%Edge{from: "work", to: "done"})
  end

  defp tool_graph do
    %Graph{id: "ToolPipeline"}
    |> Graph.add_node(%Node{id: "start", attrs: %{"shape" => "Mdiamond"}})
    |> Graph.add_node(%Node{id: "run_tests", attrs: %{"type" => "tool", "tool_command" => "mix test", "max_retries" => 3}})
    |> Graph.add_node(%Node{id: "done", attrs: %{"shape" => "Msquare"}})
    |> Graph.add_edge(%Edge{from: "start", to: "run_tests"})
    |> Graph.add_edge(%Edge{from: "run_tests", to: "done"})
  end

  defp classified_graph do
    %Graph{id: "Classified"}
    |> Graph.add_node(%Node{id: "start", attrs: %{"shape" => "Mdiamond"}})
    |> Graph.add_node(%Node{id: "secret_work", attrs: %{"prompt" => "Handle secrets", "data_class" => "secret"}})
    |> Graph.add_node(%Node{id: "public_output", attrs: %{"prompt" => "Publish", "data_class" => "public"}})
    |> Graph.add_node(%Node{id: "done", attrs: %{"shape" => "Msquare"}})
    |> Graph.add_edge(%Edge{from: "start", to: "secret_work"})
    |> Graph.add_edge(%Edge{from: "secret_work", to: "public_output"})
    |> Graph.add_edge(%Edge{from: "public_output", to: "done"})
  end

  defp conditional_graph do
    %Graph{id: "Conditional"}
    |> Graph.add_node(%Node{id: "start", attrs: %{"shape" => "Mdiamond"}})
    |> Graph.add_node(%Node{id: "check", attrs: %{"shape" => "diamond"}})
    |> Graph.add_node(%Node{id: "yes_path", attrs: %{"prompt" => "Yes"}})
    |> Graph.add_node(%Node{id: "no_path", attrs: %{"prompt" => "No"}})
    |> Graph.add_node(%Node{id: "done", attrs: %{"shape" => "Msquare"}})
    |> Graph.add_edge(%Edge{from: "start", to: "check"})
    |> Graph.add_edge(%Edge{from: "check", to: "yes_path", attrs: %{"condition" => "outcome=success"}})
    |> Graph.add_edge(%Edge{from: "check", to: "no_path", attrs: %{"condition" => "outcome=fail"}})
    |> Graph.add_edge(%Edge{from: "yes_path", to: "done"})
    |> Graph.add_edge(%Edge{from: "no_path", to: "done"})
  end

  describe "compile/1" do
    test "compiles a simple graph successfully" do
      assert {:ok, %TypedGraph{} = typed} = Compiler.compile(simple_graph())
      assert typed.id == "Test"
      assert map_size(typed.nodes) == 3
      assert length(typed.edges) == 2
    end

    test "resolves handler types correctly" do
      {:ok, typed} = Compiler.compile(simple_graph())
      assert typed.nodes["start"].handler_type == "start"
      assert typed.nodes["work"].handler_type == "codergen"
      assert typed.nodes["done"].handler_type == "exit"
    end

    test "resolves handler modules" do
      {:ok, typed} = Compiler.compile(simple_graph())
      assert typed.nodes["start"].handler_module == Arbor.Orchestrator.Handlers.StartHandler
      assert typed.nodes["work"].handler_module == Arbor.Orchestrator.Handlers.CodergenHandler
      assert typed.nodes["done"].handler_module == Arbor.Orchestrator.Handlers.ExitHandler
    end

    test "resolves idempotency from handler module" do
      {:ok, typed} = Compiler.compile(simple_graph())
      assert typed.nodes["start"].idempotency == :idempotent
      assert typed.nodes["work"].idempotency == :idempotent_with_key
      assert typed.nodes["done"].idempotency == :idempotent
    end

    test "aggregates capabilities" do
      {:ok, typed} = Compiler.compile(simple_graph())
      assert MapSet.member?(typed.capabilities_required, "llm_query")

      {:ok, tool_typed} = Compiler.compile(tool_graph())
      assert MapSet.member?(tool_typed.capabilities_required, "shell_exec")
    end

    test "builds handler_types map" do
      {:ok, typed} = Compiler.compile(simple_graph())
      assert typed.handler_types["start"] == "start"
      assert typed.handler_types["work"] == "codergen"
      assert typed.handler_types["done"] == "exit"
    end

    test "builds typed adjacency maps" do
      {:ok, typed} = Compiler.compile(simple_graph())
      assert [%TypedEdge{to: "work"}] = TypedGraph.outgoing_edges(typed, "start")
      assert [%TypedEdge{from: "work"}] = TypedGraph.incoming_edges(typed, "done")
    end

    test "preserves original attrs" do
      {:ok, typed} = Compiler.compile(simple_graph())
      assert typed.nodes["work"].attrs["prompt"] == "Do something"
    end
  end

  describe "compile/1 — data classification" do
    test "uses schema default when no data_class attr" do
      {:ok, typed} = Compiler.compile(simple_graph())
      assert typed.nodes["start"].data_classification == :public
      assert typed.nodes["work"].data_classification == :internal
    end

    test "uses explicit data_class attr" do
      {:ok, typed} = Compiler.compile(classified_graph())
      assert typed.nodes["secret_work"].data_classification == :secret
      assert typed.nodes["public_output"].data_classification == :public
    end

    test "computes max_data_classification" do
      {:ok, typed} = Compiler.compile(classified_graph())
      assert typed.max_data_classification == :secret
    end
  end

  describe "compile/1 — edge conditions" do
    test "parses condition strings into typed conditions" do
      {:ok, typed} = Compiler.compile(conditional_graph())

      success_edge = Enum.find(typed.edges, fn e -> e.from == "check" and e.to == "yes_path" end)
      assert success_edge.condition == {:eq, "outcome", "success"}

      fail_edge = Enum.find(typed.edges, fn e -> e.from == "check" and e.to == "no_path" end)
      assert fail_edge.condition == {:eq, "outcome", "fail"}
    end

    test "unconditional edges have nil condition" do
      {:ok, typed} = Compiler.compile(simple_graph())
      edge = Enum.find(typed.edges, fn e -> e.from == "start" end)
      assert edge.condition == nil
      assert TypedEdge.unconditional?(edge)
    end
  end

  describe "compile/1 — schema validation" do
    test "detects missing required attrs" do
      graph =
        %Graph{id: "Bad"}
        |> Graph.add_node(%Node{id: "start", attrs: %{"shape" => "Mdiamond"}})
        |> Graph.add_node(%Node{id: "no_prompt", attrs: %{}})
        |> Graph.add_node(%Node{id: "done", attrs: %{"shape" => "Msquare"}})
        |> Graph.add_edge(%Edge{from: "start", to: "no_prompt"})
        |> Graph.add_edge(%Edge{from: "no_prompt", to: "done"})

      {:ok, typed} = Compiler.compile(graph)
      assert TypedNode.has_errors?(typed.nodes["no_prompt"])
      assert TypedGraph.has_schema_errors?(typed)
    end

    test "valid nodes have no schema errors" do
      {:ok, typed} = Compiler.compile(simple_graph())
      assert not TypedGraph.has_schema_errors?(typed)
    end
  end

  describe "compile/1 — resource bounds" do
    test "extracts max_retries from attrs" do
      {:ok, typed} = Compiler.compile(tool_graph())
      assert typed.nodes["run_tests"].resource_bounds.max_retries == 3
    end

    test "nil for unset resource bounds" do
      {:ok, typed} = Compiler.compile(simple_graph())
      assert typed.nodes["work"].resource_bounds.max_retries == nil
    end
  end

  describe "compile!/1" do
    test "returns typed graph directly" do
      typed = Compiler.compile!(simple_graph())
      assert %TypedGraph{} = typed
    end
  end

  describe "compile/1 — capabilities attr" do
    test "merges explicit capabilities with schema defaults" do
      graph =
        %Graph{id: "ExplicitCaps"}
        |> Graph.add_node(%Node{id: "start", attrs: %{"shape" => "Mdiamond"}})
        |> Graph.add_node(%Node{id: "work", attrs: %{"prompt" => "x", "capabilities" => "custom_cap,another_cap"}})
        |> Graph.add_node(%Node{id: "done", attrs: %{"shape" => "Msquare"}})
        |> Graph.add_edge(%Edge{from: "start", to: "work"})
        |> Graph.add_edge(%Edge{from: "work", to: "done"})

      {:ok, typed} = Compiler.compile(graph)
      caps = typed.nodes["work"].capabilities_required
      assert "llm_query" in caps
      assert "custom_cap" in caps
      assert "another_cap" in caps
    end
  end
end
