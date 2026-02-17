defmodule Arbor.Orchestrator.Engine.GoalGateTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Engine.GoalGate
  alias Arbor.Orchestrator.Engine.Outcome
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.{Edge, Node}

  @moduletag :fast

  defp make_graph(nodes, edges \\ []) do
    graph = %Graph{}

    graph =
      Enum.reduce(nodes, graph, fn {id, attrs}, g ->
        Graph.add_node(g, Node.from_attrs(id, attrs))
      end)

    Enum.reduce(edges, graph, fn {from, to}, g ->
      Graph.add_edge(g, Edge.from_attrs(from, to, %{}))
    end)
  end

  describe "resolve_retry_target/2" do
    test "returns {:ok, nil} when no goal gates exist" do
      graph = make_graph([{"start", %{}}, {"task", %{}}, {"exit", %{}}])
      outcomes = %{"task" => %Outcome{status: :success}}

      assert {:ok, nil} = GoalGate.resolve_retry_target(graph, outcomes)
    end

    test "returns {:ok, nil} when goal gate succeeds" do
      graph =
        make_graph([
          {"start", %{}},
          {"gate", %{"goal_gate" => "true", "retry_target" => "start"}},
          {"exit", %{}}
        ])

      outcomes = %{"gate" => %Outcome{status: :success}}

      assert {:ok, nil} = GoalGate.resolve_retry_target(graph, outcomes)
    end

    test "returns {:ok, target} when goal gate fails with node-level retry_target" do
      graph =
        make_graph(
          [
            {"start", %{}},
            {"task", %{}},
            {"gate", %{"goal_gate" => "true", "retry_target" => "task"}}
          ],
          [{"start", "task"}, {"task", "gate"}]
        )

      outcomes = %{"gate" => %Outcome{status: :fail}}

      assert {:ok, "task"} = GoalGate.resolve_retry_target(graph, outcomes)
    end

    test "falls back to fallback_retry_target" do
      graph =
        make_graph(
          [
            {"start", %{}},
            {"gate", %{"goal_gate" => "true", "fallback_retry_target" => "start"}}
          ],
          [{"start", "gate"}]
        )

      outcomes = %{"gate" => %Outcome{status: :fail}}

      assert {:ok, "start"} = GoalGate.resolve_retry_target(graph, outcomes)
    end

    test "returns error when no valid retry target exists" do
      graph =
        make_graph([
          {"start", %{}},
          {"gate", %{"goal_gate" => "true"}}
        ])

      outcomes = %{"gate" => %Outcome{status: :fail}}

      assert {:error, :goal_gate_unsatisfied_no_retry_target} =
               GoalGate.resolve_retry_target(graph, outcomes)
    end

    test "partial_success passes the gate" do
      graph =
        make_graph([
          {"gate", %{"goal_gate" => "true", "retry_target" => "start"}}
        ])

      outcomes = %{"gate" => %Outcome{status: :partial_success}}

      assert {:ok, nil} = GoalGate.resolve_retry_target(graph, outcomes)
    end
  end

  describe "find_failed_gate/2" do
    test "returns nil when no gates exist" do
      graph = make_graph([{"task", %{}}])
      assert nil == GoalGate.find_failed_gate(graph, %{"task" => %Outcome{status: :fail}})
    end

    test "returns the failed gate node" do
      graph = make_graph([{"gate", %{"goal_gate" => "true"}}])
      result = GoalGate.find_failed_gate(graph, %{"gate" => %Outcome{status: :fail}})
      assert result.id == "gate"
    end

    test "ignores successful gates" do
      graph = make_graph([{"gate", %{"goal_gate" => "true"}}])
      assert nil == GoalGate.find_failed_gate(graph, %{"gate" => %Outcome{status: :success}})
    end
  end
end
