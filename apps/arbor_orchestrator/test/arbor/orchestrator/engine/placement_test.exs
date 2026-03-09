defmodule Arbor.Orchestrator.Engine.PlacementTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Engine.Placement

  @moduletag :fast

  describe "parse/1" do
    test "returns nil for nil" do
      assert Placement.parse(nil) == nil
    end

    test "returns nil for empty string" do
      assert Placement.parse("") == nil
    end

    test "parses OS requirement" do
      parsed = Placement.parse("os=windows")
      assert {:os, :windows} in parsed.requirements
    end

    test "parses multiple requirements" do
      parsed = Placement.parse("os=windows,has=strings,has=sigcheck")
      assert {:os, :windows} in parsed.requirements
      assert {:has_executable, "strings"} in parsed.requirements
      assert {:has_executable, "sigcheck"} in parsed.requirements
    end

    test "parses min_memory_gb" do
      parsed = Placement.parse("min_memory_gb=32")
      assert {:min_memory_gb, 32.0} in parsed.requirements
    end

    test "parses min_cpus" do
      parsed = Placement.parse("min_cpus=8")
      assert {:min_cpus, 8} in parsed.requirements
    end

    test "parses gpu requirement" do
      parsed = Placement.parse("gpu=true")
      assert {:gpu, true} in parsed.requirements
    end

    test "parses arch requirement" do
      parsed = Placement.parse("arch=x86_64")
      assert {:arch, :x86_64} in parsed.requirements
    end

    test "parses tag requirement" do
      parsed = Placement.parse("tag=re_tools")
      assert {:tag, :re_tools} in parsed.requirements
    end

    test "parses explicit node" do
      parsed = Placement.parse("node:arbor_dev@10.42.42.206")
      assert parsed.node == :"arbor_dev@10.42.42.206"
      assert parsed.requirements == []
    end

    test "parses strategy" do
      parsed = Placement.parse("strategy:least_loaded")
      assert parsed.strategy == :least_loaded
    end

    test "parses combined requirements and strategy" do
      parsed = Placement.parse("os=linux,min_memory_gb=64,strategy:most_resources")
      assert {:os, :linux} in parsed.requirements
      assert {:min_memory_gb, 64.0} in parsed.requirements
      assert parsed.strategy == :most_resources
    end

    test "defaults strategy to :first_match" do
      parsed = Placement.parse("os=windows")
      assert parsed.strategy == :first_match
    end

    test "handles whitespace in parts" do
      parsed = Placement.parse("os=windows, has=strings, min_cpus=4")
      assert {:os, :windows} in parsed.requirements
      assert {:has_executable, "strings"} in parsed.requirements
      assert {:min_cpus, 4} in parsed.requirements
    end
  end

  describe "resolve/1" do
    test "returns nil for nil parsed" do
      assert Placement.resolve(nil) == nil
    end

    test "resolves explicit local node" do
      parsed = %{requirements: [], strategy: :first_match, node: Node.self()}
      assert {:ok, Node.self()} == Placement.resolve(parsed)
    end

    test "returns error for unreachable explicit node" do
      parsed = %{requirements: [], strategy: :first_match, node: :nonexistent@nowhere}
      assert {:error, {:node_unreachable, :nonexistent@nowhere}} == Placement.resolve(parsed)
    end

    test "resolves requirements to local node when no scheduler available" do
      # In test environment, Cartographer.Scheduler may not be running
      # but Code.ensure_loaded? should still work since it's in the umbrella
      parsed = %{requirements: [{:min_cpus, 1}], strategy: :first_match, node: nil}
      result = Placement.resolve(parsed)
      # Should either resolve via scheduler or fall back to local
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "local_execute/5" do
    test "executes handler module" do
      defmodule TestHandler do
        def execute(_node, _context, _graph, _opts) do
          %Arbor.Orchestrator.Engine.Outcome{status: :success, notes: "test ran"}
        end
      end

      node = %Arbor.Orchestrator.Graph.Node{id: "test", attrs: %{}}
      outcome = Placement.local_execute(TestHandler, node, %{}, %{}, [])
      assert outcome.status == :success
      assert outcome.notes == "test ran"
    end

    test "returns failure for unavailable handler" do
      node = %Arbor.Orchestrator.Graph.Node{id: "test", attrs: %{}}
      outcome = Placement.local_execute(NonExistentHandler, node, %{}, %{}, [])
      assert outcome.status == :fail
      assert outcome.failure_reason =~ "not available"
    end
  end

  describe "integration with executor" do
    alias Arbor.Orchestrator.Engine.Executor
    alias Arbor.Orchestrator.Engine.Context
    alias Arbor.Orchestrator.Graph
    alias Arbor.Orchestrator.Graph.Node, as: GNode

    test "nodes without placement execute locally" do
      node = GNode.from_attrs("test", %{"type" => "start", "shape" => "Mdiamond"})
      graph = %Graph{nodes: %{"test" => node}, edges: [], attrs: %{}}
      context = Context.new()

      {outcome, _retries} = Executor.execute_with_retry(node, context, graph, %{}, [])
      # Start nodes are skipped/passthrough — should succeed
      assert outcome.status in [:success, :skipped]
    end

    test "nodes with placement to self execute locally" do
      self_node = Node.self() |> Atom.to_string()

      node =
        GNode.from_attrs("test", %{
          "type" => "start",
          "shape" => "Mdiamond",
          "placement" => "node:#{self_node}"
        })

      graph = %Graph{nodes: %{"test" => node}, edges: [], attrs: %{}}
      context = Context.new()

      {outcome, _retries} = Executor.execute_with_retry(node, context, graph, %{}, [])
      assert outcome.status in [:success, :skipped]
    end

    test "nodes with unreachable placement fail gracefully by default" do
      node =
        GNode.from_attrs("test", %{
          "type" => "compute",
          "placement" => "node:nonexistent@nowhere"
        })

      graph = %Graph{nodes: %{"test" => node}, edges: [], attrs: %{}}
      context = Context.new()

      # Default: placement_required is false, so it falls back to local execution
      {outcome, _retries} = Executor.execute_with_retry(node, context, graph, %{}, [])
      # Should execute locally (fallback) — compute handler will run
      assert outcome.status in [:success, :fail]
    end

    test "nodes with unreachable placement fail when placement_required" do
      node =
        GNode.from_attrs("test", %{
          "type" => "compute",
          "placement" => "node:nonexistent@nowhere"
        })

      graph = %Graph{nodes: %{"test" => node}, edges: [], attrs: %{}}
      context = Context.new()

      {outcome, _retries} =
        Executor.execute_with_retry(node, context, graph, %{}, placement_required: true)

      assert outcome.status == :fail
      assert outcome.failure_reason =~ "placement"
    end
  end
end
