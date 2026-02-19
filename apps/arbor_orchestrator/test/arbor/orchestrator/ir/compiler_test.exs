defmodule Arbor.Orchestrator.IR.CompilerTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.{Edge, Node}
  alias Arbor.Orchestrator.IR.Compiler

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
    |> Graph.add_node(%Node{
      id: "run_tests",
      attrs: %{"type" => "tool", "tool_command" => "mix test", "max_retries" => 3}
    })
    |> Graph.add_node(%Node{id: "done", attrs: %{"shape" => "Msquare"}})
    |> Graph.add_edge(%Edge{from: "start", to: "run_tests"})
    |> Graph.add_edge(%Edge{from: "run_tests", to: "done"})
  end

  defp classified_graph do
    %Graph{id: "Classified"}
    |> Graph.add_node(%Node{id: "start", attrs: %{"shape" => "Mdiamond"}})
    |> Graph.add_node(%Node{
      id: "secret_work",
      attrs: %{"prompt" => "Handle secrets", "data_class" => "secret"}
    })
    |> Graph.add_node(%Node{
      id: "public_output",
      attrs: %{"prompt" => "Publish", "data_class" => "public"}
    })
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
    |> Graph.add_edge(%Edge{
      from: "check",
      to: "yes_path",
      attrs: %{"condition" => "outcome=success"}
    })
    |> Graph.add_edge(%Edge{
      from: "check",
      to: "no_path",
      attrs: %{"condition" => "outcome=fail"}
    })
    |> Graph.add_edge(%Edge{from: "yes_path", to: "done"})
    |> Graph.add_edge(%Edge{from: "no_path", to: "done"})
  end

  describe "compile/1" do
    test "compiles a simple graph successfully" do
      assert {:ok, %Graph{compiled: true} = compiled} = Compiler.compile(simple_graph())
      assert compiled.id == "Test"
      assert map_size(compiled.nodes) == 3
      assert length(compiled.edges) == 2
    end

    test "resolves handler types correctly" do
      {:ok, compiled} = Compiler.compile(simple_graph())
      assert compiled.handler_types["start"] == "start"
      assert compiled.handler_types["work"] == "codergen"
      assert compiled.handler_types["done"] == "exit"
    end

    test "resolves handler modules" do
      {:ok, compiled} = Compiler.compile(simple_graph())
      assert compiled.nodes["start"].handler_module == Arbor.Orchestrator.Handlers.StartHandler
      assert compiled.nodes["work"].handler_module == Arbor.Orchestrator.Handlers.ComputeHandler
      assert compiled.nodes["done"].handler_module == Arbor.Orchestrator.Handlers.ExitHandler
    end

    test "resolves idempotency from handler module" do
      {:ok, compiled} = Compiler.compile(simple_graph())
      assert compiled.nodes["start"].idempotency == :idempotent
      assert compiled.nodes["work"].idempotency == :idempotent_with_key
      assert compiled.nodes["done"].idempotency == :idempotent
    end

    test "aggregates capabilities" do
      {:ok, compiled} = Compiler.compile(simple_graph())
      assert MapSet.member?(compiled.capabilities_required, "llm_query")

      {:ok, tool_compiled} = Compiler.compile(tool_graph())
      assert MapSet.member?(tool_compiled.capabilities_required, "shell_exec")
    end

    test "builds handler_types map" do
      {:ok, compiled} = Compiler.compile(simple_graph())
      assert compiled.handler_types["start"] == "start"
      assert compiled.handler_types["work"] == "codergen"
      assert compiled.handler_types["done"] == "exit"
    end

    test "builds enriched adjacency maps" do
      {:ok, compiled} = Compiler.compile(simple_graph())
      assert [%Edge{to: "work"}] = Graph.outgoing_edges(compiled, "start")
      assert [%Edge{from: "work"}] = Graph.incoming_edges(compiled, "done")
    end

    test "preserves original attrs" do
      {:ok, compiled} = Compiler.compile(simple_graph())
      assert compiled.nodes["work"].attrs["prompt"] == "Do something"
    end
  end

  describe "compile/1 — data classification" do
    test "uses schema default when no data_class attr" do
      {:ok, compiled} = Compiler.compile(simple_graph())
      assert compiled.nodes["start"].data_classification == :public
      assert compiled.nodes["work"].data_classification == :internal
    end

    test "uses explicit data_class attr" do
      {:ok, compiled} = Compiler.compile(classified_graph())
      assert compiled.nodes["secret_work"].data_classification == :secret
      assert compiled.nodes["public_output"].data_classification == :public
    end

    test "computes max_data_classification" do
      {:ok, compiled} = Compiler.compile(classified_graph())
      assert compiled.max_data_classification == :secret
    end
  end

  describe "compile/1 — edge conditions" do
    test "parses condition strings into typed conditions" do
      {:ok, compiled} = Compiler.compile(conditional_graph())

      success_edge =
        Enum.find(compiled.edges, fn e -> e.from == "check" and e.to == "yes_path" end)

      assert success_edge.parsed_condition == {:eq, "outcome", "success"}

      fail_edge =
        Enum.find(compiled.edges, fn e -> e.from == "check" and e.to == "no_path" end)

      assert fail_edge.parsed_condition == {:eq, "outcome", "fail"}
    end

    test "unconditional edges have nil parsed_condition" do
      {:ok, compiled} = Compiler.compile(simple_graph())
      edge = Enum.find(compiled.edges, fn e -> e.from == "start" end)
      assert edge.parsed_condition == nil
      assert Edge.unconditional?(edge)
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

      {:ok, compiled} = Compiler.compile(graph)
      assert Node.has_schema_errors?(compiled.nodes["no_prompt"])
      assert Graph.has_schema_errors?(compiled)
    end

    test "valid nodes have no schema errors" do
      {:ok, compiled} = Compiler.compile(simple_graph())
      assert not Graph.has_schema_errors?(compiled)
    end
  end

  describe "compile/1 — resource bounds" do
    test "extracts max_retries from attrs" do
      {:ok, compiled} = Compiler.compile(tool_graph())
      assert compiled.nodes["run_tests"].max_retries == 3
    end

    test "nil for unset resource bounds" do
      {:ok, compiled} = Compiler.compile(simple_graph())
      assert compiled.nodes["work"].max_retries == nil
    end
  end

  describe "compile!/1" do
    test "returns compiled graph directly" do
      compiled = Compiler.compile!(simple_graph())
      assert %Graph{compiled: true} = compiled
    end
  end

  describe "compile/1 — capabilities attr" do
    test "merges explicit capabilities with schema defaults" do
      graph =
        %Graph{id: "ExplicitCaps"}
        |> Graph.add_node(%Node{id: "start", attrs: %{"shape" => "Mdiamond"}})
        |> Graph.add_node(%Node{
          id: "work",
          attrs: %{"prompt" => "x", "capabilities" => "custom_cap,another_cap"}
        })
        |> Graph.add_node(%Node{id: "done", attrs: %{"shape" => "Msquare"}})
        |> Graph.add_edge(%Edge{from: "start", to: "work"})
        |> Graph.add_edge(%Edge{from: "work", to: "done"})

      {:ok, compiled} = Compiler.compile(graph)
      caps = compiled.nodes["work"].capabilities_required
      assert "llm_query" in caps
      assert "custom_cap" in caps
      assert "another_cap" in caps
    end
  end
end
