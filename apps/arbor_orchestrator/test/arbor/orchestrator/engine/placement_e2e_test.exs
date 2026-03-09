defmodule Arbor.Orchestrator.Engine.PlacementE2ETest do
  @moduledoc """
  End-to-end tests for DOT placement feature: compilation -> placement resolution -> execution.
  """
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Test.DotTestHelper
  alias Arbor.Orchestrator.Engine.Placement
  alias Arbor.Orchestrator.Graph.Node, as: GNode

  @moduletag :fast

  describe "DOT parsing with placement attribute" do
    test "placement attribute is parsed into graph node struct" do
      dot = """
      digraph pipeline {
        start [shape=Mdiamond type="start"]
        analyze [type="compute" placement="os=linux,min_cpus=4" simulate="true"]
        done [shape=Msquare type="exit"]
        start -> analyze -> done
      }
      """

      {:ok, graph} = Arbor.Orchestrator.parse(dot)

      analyze_node = graph.nodes["analyze"]
      assert analyze_node.placement == "os=linux,min_cpus=4"
      assert Map.get(analyze_node.attrs, "placement") == "os=linux,min_cpus=4"

      # Verify the placement string can be parsed into structured requirements
      parsed = Placement.parse(analyze_node.placement)
      assert {:os, :linux} in parsed.requirements
      assert {:min_cpus, 4} in parsed.requirements
      assert parsed.strategy == :first_match
      assert parsed.node == nil
    end

    test "explicit node placement is parsed correctly" do
      dot = """
      digraph pipeline {
        start [shape=Mdiamond type="start"]
        deploy [type="compute" placement="node:worker@10.0.0.1" simulate="true"]
        done [shape=Msquare type="exit"]
        start -> deploy -> done
      }
      """

      {:ok, graph} = Arbor.Orchestrator.parse(dot)

      deploy_node = graph.nodes["deploy"]
      assert deploy_node.placement == "node:worker@10.0.0.1"

      parsed = Placement.parse(deploy_node.placement)
      assert parsed.node == :"worker@10.0.0.1"
      assert parsed.requirements == []
    end

    test "nodes without placement have nil placement field" do
      dot = """
      digraph pipeline {
        start [shape=Mdiamond type="start"]
        step [type="compute" simulate="true"]
        done [shape=Msquare type="exit"]
        start -> step -> done
      }
      """

      {:ok, graph} = Arbor.Orchestrator.parse(dot)
      assert graph.nodes["step"].placement == nil
    end
  end

  describe "self-targeting placement executes locally" do
    test "placement targeting Node.self() executes successfully" do
      self_node = Node.self() |> Atom.to_string()

      dot = """
      digraph pipeline {
        start [shape=Mdiamond type="start"]
        local_task [type="compute" placement="node:#{self_node}" simulate="true"]
        done [shape=Msquare type="exit"]
        start -> local_task -> done
      }
      """

      {:ok, result} = DotTestHelper.run_dot(dot, simulate_compute: false, skip_validation: true)

      assert DotTestHelper.visited?(result, "local_task")
      assert DotTestHelper.visited?(result, "start")
      assert result.final_outcome.status in [:success, :partial_success]
    end
  end

  describe "requirement-based placement resolves via scheduler or falls back to local" do
    test "pipeline with capability requirements executes (scheduler fallback to local)" do
      dot = """
      digraph pipeline {
        start [shape=Mdiamond type="start"]
        process [type="compute" placement="os=linux,min_cpus=1" simulate="true"]
        done [shape=Msquare type="exit"]
        start -> process -> done
      }
      """

      # Without Cartographer.Scheduler running, this should fall back to local execution
      {:ok, result} = DotTestHelper.run_dot(dot, simulate_compute: false, skip_validation: true)

      assert DotTestHelper.visited?(result, "process")
      assert result.final_outcome.status in [:success, :partial_success]
    end
  end

  describe "unreachable node with placement_required: false falls back to local" do
    test "gracefully falls back when target node is unreachable" do
      dot = """
      digraph pipeline {
        start [shape=Mdiamond type="start"]
        remote_task [type="compute" placement="node:unreachable@nowhere" simulate="true"]
        done [shape=Msquare type="exit"]
        start -> remote_task -> done
      }
      """

      # Default placement_required is false, so unreachable node should fall back to local
      {:ok, result} =
        DotTestHelper.run_dot(dot,
          simulate_compute: false,
          skip_validation: true,
          placement_required: false
        )

      assert DotTestHelper.visited?(result, "remote_task")
      assert result.final_outcome.status in [:success, :partial_success]
    end
  end

  describe "unreachable node with placement_required: true fails" do
    test "fails with placement error when target is unreachable and placement is required" do
      dot = """
      digraph pipeline {
        start [shape=Mdiamond type="start"]
        remote_task [type="compute" placement="node:unreachable@nowhere" simulate="true"]
        done [shape=Msquare type="exit"]
        start -> remote_task -> done
      }
      """

      {:ok, result} =
        DotTestHelper.run_dot(dot,
          simulate_compute: false,
          skip_validation: true,
          placement_required: true
        )

      # The pipeline should complete but the placed node should fail
      assert DotTestHelper.visited?(result, "remote_task")
      assert result.final_outcome.status == :fail
      assert result.final_outcome.failure_reason =~ "placement"
    end
  end

  describe "multi-node pipeline with different placement requirements" do
    test "nodes with mixed placement execute in correct order" do
      self_node = Node.self() |> Atom.to_string()

      dot = """
      digraph pipeline {
        start [shape=Mdiamond type="start"]
        step_a [type="compute" placement="node:#{self_node}" simulate="true"]
        step_b [type="compute" simulate="true"]
        step_c [type="compute" placement="os=linux,min_cpus=1" simulate="true"]
        done [shape=Msquare type="exit"]
        start -> step_a -> step_b -> step_c -> done
      }
      """

      {:ok, result} = DotTestHelper.run_dot(dot, simulate_compute: false, skip_validation: true)

      # All nodes should be visited in order
      assert DotTestHelper.visited?(result, "step_a")
      assert DotTestHelper.visited?(result, "step_b")
      assert DotTestHelper.visited?(result, "step_c")

      # Verify ordering: step_a before step_b before step_c
      assert DotTestHelper.visited_in_order?(result, ["step_a", "step_b", "step_c"])

      assert result.final_outcome.status in [:success, :partial_success]
    end

    test "pipeline continues past a locally-placed node to subsequent nodes" do
      self_node = Node.self() |> Atom.to_string()

      dot = """
      digraph pipeline {
        start [shape=Mdiamond type="start"]
        placed [type="compute" placement="node:#{self_node}" simulate="true"]
        unplaced [type="compute" simulate="true"]
        done [shape=Msquare type="exit"]
        start -> placed -> unplaced -> done
      }
      """

      {:ok, result} = DotTestHelper.run_dot(dot, simulate_compute: false, skip_validation: true)

      assert DotTestHelper.visited_in_order?(result, ["placed", "unplaced"])
      assert result.final_outcome.status in [:success, :partial_success]
    end
  end

  describe "placement parsing round-trip through graph node" do
    test "from_attrs preserves placement and it round-trips through parse" do
      attrs = %{
        "type" => "compute",
        "placement" => "gpu=true,min_memory_gb=64,strategy:most_resources"
      }

      node = GNode.from_attrs("inference", attrs)
      assert node.placement == "gpu=true,min_memory_gb=64,strategy:most_resources"

      parsed = Placement.parse(node.placement)
      assert {:gpu, true} in parsed.requirements
      assert {:min_memory_gb, 64.0} in parsed.requirements
      assert parsed.strategy == :most_resources
      assert parsed.node == nil
    end
  end
end
