defmodule Arbor.Orchestrator.Validation.RulesTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.{Edge, Node}
  alias Arbor.Orchestrator.Validation.Rules
  alias Arbor.Orchestrator.Validation.Validator

  # Helper to build a minimal valid graph
  defp valid_graph do
    %Graph{
      id: "Test",
      nodes: %{
        "start" => Node.from_attrs("start", %{"shape" => "Mdiamond"}),
        "work" => Node.from_attrs("work", %{"shape" => "box", "prompt" => "do stuff"}),
        "done" => Node.from_attrs("done", %{"shape" => "Msquare"})
      },
      edges: [
        Edge.from_attrs("start", "work", %{}),
        Edge.from_attrs("work", "done", %{})
      ]
    }
    |> rebuild_adjacency()
  end

  defp rebuild_adjacency(graph) do
    Enum.reduce(graph.edges, %{graph | adjacency: %{}, reverse_adjacency: %{}}, fn edge, g ->
      %{
        g
        | adjacency: Map.update(g.adjacency, edge.from, [edge], &[edge | &1]),
          reverse_adjacency: Map.update(g.reverse_adjacency, edge.to, [edge], &[edge | &1])
      }
    end)
  end

  describe "individual rules" do
    test "StartNode passes with exactly one start" do
      assert Rules.StartNode.validate(valid_graph()) == []
    end

    test "StartNode fails with no start" do
      graph = %Graph{
        nodes: %{"a" => Node.from_attrs("a", %{"shape" => "box"})},
        edges: []
      }

      diags = Rules.StartNode.validate(graph)
      assert length(diags) == 1
      assert hd(diags).rule == "start_node"
    end

    test "TerminalNode passes with exactly one terminal" do
      assert Rules.TerminalNode.validate(valid_graph()) == []
    end

    test "TerminalNode fails with no terminal" do
      graph = %Graph{
        nodes: %{"start" => Node.from_attrs("start", %{"shape" => "Mdiamond"})},
        edges: []
      }

      diags = Rules.TerminalNode.validate(graph)
      assert length(diags) == 1
      assert hd(diags).rule == "terminal_node"
    end

    test "EdgeTargetExists catches missing targets" do
      graph = %Graph{
        nodes: %{"start" => Node.from_attrs("start", %{"shape" => "Mdiamond"})},
        edges: [Edge.from_attrs("start", "missing", %{})]
      }

      diags = Rules.EdgeTargetExists.validate(graph)
      assert length(diags) == 1
      assert hd(diags).rule == "edge_target_exists"
    end

    test "CodergenPrompt warns on missing prompt" do
      graph = %Graph{
        nodes: %{
          "start" => Node.from_attrs("start", %{"shape" => "Mdiamond"}),
          "no_prompt" => Node.from_attrs("no_prompt", %{"shape" => "box"}),
          "done" => Node.from_attrs("done", %{"shape" => "Msquare"})
        },
        edges: []
      }

      diags = Rules.CodergenPrompt.validate(graph)
      assert length(diags) == 1
      assert hd(diags).rule == "codergen_prompt"
      assert hd(diags).severity == :warning
    end

    test "GoalGateRetry warns when goal_gate has no retry_target" do
      graph = %Graph{
        nodes: %{
          "gate" => Node.from_attrs("gate", %{"goal_gate" => "true"})
        },
        edges: []
      }

      diags = Rules.GoalGateRetry.validate(graph)
      assert length(diags) == 1
      assert hd(diags).rule == "goal_gate_has_retry"
    end

    test "each rule reports its name" do
      assert Rules.StartNode.name() == "start_node"
      assert Rules.TerminalNode.name() == "terminal_node"
      assert Rules.StartNoIncoming.name() == "start_no_incoming"
      assert Rules.ExitNoOutgoing.name() == "exit_no_outgoing"
      assert Rules.EdgeTargetExists.name() == "edge_target_exists"
      assert Rules.Reachability.name() == "reachability"
      assert Rules.ConditionSyntax.name() == "condition_syntax"
      assert Rules.RetryTargetExists.name() == "retry_target_exists"
      assert Rules.GoalGateRetry.name() == "goal_gate_has_retry"
      assert Rules.CodergenPrompt.name() == "codergen_prompt"
    end
  end

  describe "Validator with opts" do
    test "validate/1 (no opts) runs all rules" do
      diags = Validator.validate(valid_graph())
      # valid_graph has work node with prompt, so only codergen_prompt would skip
      # But work node has prompt="do stuff", so no warnings
      assert diags == []
    end

    test "validate/2 with :exclude skips named rules" do
      graph =
        %Graph{
          nodes: %{
            "start" => Node.from_attrs("start", %{"shape" => "Mdiamond"}),
            "no_prompt" => Node.from_attrs("no_prompt", %{"shape" => "box"}),
            "done" => Node.from_attrs("done", %{"shape" => "Msquare"})
          },
          edges: [
            Edge.from_attrs("start", "no_prompt", %{}),
            Edge.from_attrs("no_prompt", "done", %{})
          ]
        }
        |> rebuild_adjacency()

      # Without exclusion, codergen_prompt should warn
      diags_all = Validator.validate(graph)
      assert Enum.any?(diags_all, &(&1.rule == "codergen_prompt"))

      # With exclusion, codergen_prompt is skipped
      diags_excluded = Validator.validate(graph, exclude: ["codergen_prompt"])
      refute Enum.any?(diags_excluded, &(&1.rule == "codergen_prompt"))
    end

    test "validate/2 with :rules uses only specified rules" do
      graph = valid_graph()

      diags = Validator.validate(graph, rules: [Rules.StartNode])
      # Only start_node rule runs, graph is valid, so empty
      assert diags == []
    end

    test "validate/2 with custom rules catches issues" do
      graph = %Graph{nodes: %{}, edges: []}
      diags = Validator.validate(graph, rules: [Rules.StartNode])
      assert length(diags) == 1
      assert hd(diags).rule == "start_node"
    end
  end

  describe "LlmSimulate — run-blocking require-explicit-simulate" do
    alias Arbor.Orchestrator.IR.Compiler

    # The rule reads node.schema_errors (populated by IR.Compiler), so graphs
    # must be COMPILED — mirrors the run path (ensure_graph always compiles).
    defp compiled_with(node_attrs) do
      {:ok, g} =
        %Graph{
          id: "SimGate",
          nodes: %{
            "start" => Node.from_attrs("start", %{"shape" => "Mdiamond"}),
            "n" => Node.from_attrs("n", node_attrs),
            "done" => Node.from_attrs("done", %{"shape" => "Msquare"})
          },
          edges: [Edge.from_attrs("start", "n", %{}), Edge.from_attrs("n", "done", %{})]
        }
        |> rebuild_adjacency()
        |> Compiler.compile()

      g
    end

    test "flags a bare compute (purpose=llm) node missing simulate as :error" do
      diags = Rules.LlmSimulate.validate(compiled_with(%{"type" => "compute", "prompt" => "x"}))

      assert [%Arbor.Orchestrator.Validation.Diagnostic{severity: :error, rule: "llm_simulate"}] =
               diags
    end

    test "flags a bare-prompt codergen node (no type, box shape) missing simulate" do
      assert [%{severity: :error}] =
               Rules.LlmSimulate.validate(compiled_with(%{"shape" => "box", "prompt" => "x"}))
    end

    test "passes when simulate is explicitly declared" do
      assert Rules.LlmSimulate.validate(
               compiled_with(%{"type" => "compute", "prompt" => "x", "simulate" => "false"})
             ) == []
    end

    test "ignores a non-LLM compute purpose (routing) — no friction off the LLM path" do
      assert Rules.LlmSimulate.validate(
               compiled_with(%{"type" => "compute", "purpose" => "routing", "prompt" => "x"})
             ) == []
    end

    test "validate_or_error REJECTS a graph with a bare LLM node (run() won't execute it)" do
      assert {:error, diags} =
               Validator.validate_or_error(compiled_with(%{"type" => "compute", "prompt" => "x"}))

      assert Enum.any?(diags, &(&1.rule == "llm_simulate" and &1.severity == :error))
    end
  end
end
