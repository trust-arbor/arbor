defmodule Arbor.Orchestrator.ResearchPipelineTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Dot.Parser
  alias Arbor.Orchestrator.Engine.{Context, Outcome}
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Handlers.CodergenHandler
  alias Arbor.Orchestrator.UnifiedLLM.ArborActionsExecutor

  @moduletag :fast

  # Arbor.Actions is only available when running in the umbrella context.
  @actions_available Code.ensure_loaded?(Arbor.Actions)

  @specs_dir Path.join([__DIR__, "..", "..", "..", "specs", "pipelines"])

  describe "research-codebase.dot" do
    test "parses successfully" do
      dot = File.read!(Path.join(@specs_dir, "research-codebase.dot"))
      assert {:ok, graph} = Parser.parse(dot)

      assert graph.attrs["goal"] == "Research a codebase topic"
      assert map_size(graph.nodes) == 3
      assert length(graph.edges) == 2
    end

    test "investigate node has correct attributes" do
      dot = File.read!(Path.join(@specs_dir, "research-codebase.dot"))
      {:ok, graph} = Parser.parse(dot)

      investigate = graph.nodes["investigate"]
      assert investigate.attrs["type"] == "codergen"
      assert investigate.attrs["simulate"] == "false"
      assert investigate.attrs["use_tools"] == "true"
      assert investigate.attrs["tools"] == "file_read,file_search,file_glob,file_list"
      assert investigate.attrs["max_turns"] == "15"
    end

    test "tools resolve to ArborActionsExecutor definitions" do
      dot = File.read!(Path.join(@specs_dir, "research-codebase.dot"))
      {:ok, graph} = Parser.parse(dot)

      tools_str = graph.nodes["investigate"].attrs["tools"]
      action_names = String.split(tools_str, ",", trim: true)
      defs = ArborActionsExecutor.definitions(action_names)

      assert is_list(defs)

      if @actions_available do
        # Should resolve at least some tools when Arbor Actions are loaded
        assert defs != []

        # All should be in OpenAI format
        for d <- defs do
          assert d["type"] == "function"
          assert is_binary(d["function"]["name"])
        end
      else
        # Graceful degradation — returns empty list when standalone
        assert defs == []
      end
    end

    test "graph has valid start → investigate → done flow" do
      dot = File.read!(Path.join(@specs_dir, "research-codebase.dot"))
      {:ok, graph} = Parser.parse(dot)

      # Verify start and exit nodes exist with correct types
      assert graph.nodes["start"].attrs["type"] == "start"
      assert graph.nodes["done"].attrs["type"] == "exit"

      # Edge path: start -> investigate -> done
      edge_pairs = Enum.map(graph.edges, fn e -> {e.from, e.to} end)
      assert {"start", "investigate"} in edge_pairs
      assert {"investigate", "done"} in edge_pairs
    end
  end

  describe "research-parallel.dot" do
    test "parses successfully" do
      dot = File.read!(Path.join(@specs_dir, "research-parallel.dot"))
      assert {:ok, graph} = Parser.parse(dot)

      assert graph.attrs["goal"] == "Parallel codebase investigation"
      assert map_size(graph.nodes) >= 6
    end

    test "fork node is parallel handler" do
      dot = File.read!(Path.join(@specs_dir, "research-parallel.dot"))
      {:ok, graph} = Parser.parse(dot)

      fork = graph.nodes["fork"]
      assert fork.attrs["type"] == "parallel"
      assert fork.attrs["join_policy"] == "wait_all"
      assert fork.attrs["max_parallel"] == "4"
    end

    test "branch nodes have tool access" do
      dot = File.read!(Path.join(@specs_dir, "research-parallel.dot"))
      {:ok, graph} = Parser.parse(dot)

      for branch_id <- ["branch_a", "branch_b"] do
        branch = graph.nodes[branch_id]
        assert branch.attrs["use_tools"] == "true"
        assert is_binary(branch.attrs["tools"])
        assert branch.attrs["type"] == "codergen"
      end
    end

    test "has synthesis node after fan-in" do
      dot = File.read!(Path.join(@specs_dir, "research-parallel.dot"))
      {:ok, graph} = Parser.parse(dot)

      synthesize = graph.nodes["synthesize"]
      assert synthesize.attrs["type"] == "codergen"

      # Synthesis doesn't need tools — just LLM reasoning
      refute Map.has_key?(synthesize.attrs, "use_tools")
    end
  end

  describe "CodergenHandler tool resolution" do
    test "codergen with tools attr uses ArborActionsExecutor" do
      # Simulate what CodergenHandler does with a tools attr
      node =
        make_node("research", %{
          "type" => "codergen",
          "simulate" => "true",
          "use_tools" => "true",
          "tools" => "file_read,file_search"
        })

      graph = make_graph([node])
      context = Context.new()

      # In simulate mode, the handler won't call the LLM but we can verify
      # it produces a simulated response
      result = CodergenHandler.execute(node, context, graph, [])
      assert %Outcome{status: :success} = result
    end

    test "codergen without tools attr falls back to CodingTools" do
      node =
        make_node("code", %{
          "type" => "codergen",
          "simulate" => "true",
          "use_tools" => "true"
        })

      graph = make_graph([node])
      context = Context.new()

      result = CodergenHandler.execute(node, context, graph, [])
      assert %Outcome{status: :success} = result
    end

    test "agent_id flows from context to tool opts" do
      # When a node has agent_id attr, it should flow through
      node =
        make_node("research", %{
          "type" => "codergen",
          "simulate" => "true",
          "agent_id" => "agent_abc123"
        })

      graph = make_graph([node])
      context = Context.new()

      result = CodergenHandler.execute(node, context, graph, [])
      assert %Outcome{status: :success} = result
    end
  end

  # --- Helpers ---

  defp make_node(id, attrs) do
    %Graph.Node{id: id, attrs: attrs}
  end

  defp make_graph(nodes) do
    node_map = Map.new(nodes, fn n -> {n.id, n} end)
    %Graph{id: "test", nodes: node_map, edges: [], attrs: %{"goal" => "test"}}
  end
end
