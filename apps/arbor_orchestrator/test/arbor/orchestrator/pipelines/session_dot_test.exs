defmodule Arbor.Orchestrator.Pipelines.SessionDotTest do
  @moduledoc """
  Structural verification tests for session DOT pipelines.

  Session DOTs use exec nodes calling Jido actions not available in test context,
  so these are Tier 1.5 tests: parse + verify graph structure, edge conditions,
  node types, and reachability without running the engine.
  """
  use ExUnit.Case, async: true

  @moduletag :dot_execution

  defp parse_pipeline(filename) do
    candidates = [
      Path.join([File.cwd!(), "specs", "pipelines", filename]),
      Path.join([File.cwd!(), "apps", "arbor_orchestrator", "specs", "pipelines", filename])
    ]

    path = Enum.find(candidates, List.first(candidates), &File.exists?/1)
    dot = File.read!(path)
    {:ok, graph} = Arbor.Orchestrator.parse(dot)
    graph
  end

  defp edges_from(graph, id) do
    Enum.filter(graph.edges, &(&1.from == id))
  end

  defp edge_condition(edge) do
    Map.get(edge.attrs, "condition", "")
  end

  defp reachable_from(graph, start_id) do
    do_reachable(graph, [start_id], MapSet.new())
  end

  defp do_reachable(_graph, [], visited), do: visited

  defp do_reachable(graph, [id | rest], visited) do
    if MapSet.member?(visited, id) do
      do_reachable(graph, rest, visited)
    else
      next = edges_from(graph, id) |> Enum.map(& &1.to)
      do_reachable(graph, rest ++ next, MapSet.put(visited, id))
    end
  end

  describe "session/turn.dot structure" do
    setup do
      %{graph: parse_pipeline("session/turn.dot")}
    end

    test "has all expected nodes", %{graph: graph} do
      expected = ~w(start classify check_auth recall select_mode build_prompt
                    call_llm format format_error update_memory checkpoint done)

      for node_id <- expected do
        assert Map.has_key?(graph.nodes, node_id),
               "Missing node: #{node_id}"
      end
    end

    test "exec nodes have correct action attributes", %{graph: graph} do
      exec_actions = %{
        "classify" => "session.classify",
        "recall" => "session_memory.recall",
        "select_mode" => "session.mode_select",
        "build_prompt" => "session_llm.build_prompt",
        "update_memory" => "session_memory.update",
        "checkpoint" => "session_memory.checkpoint"
      }

      for {node_id, expected_action} <- exec_actions do
        node = graph.nodes[node_id]
        assert node.attrs["type"] == "exec", "#{node_id} should be exec type"
        assert node.attrs["action"] == expected_action, "#{node_id} action mismatch"
      end
    end

    test "call_llm is compute type with tool support", %{graph: graph} do
      llm = graph.nodes["call_llm"]
      assert llm.attrs["type"] == "compute"
      assert llm.attrs["use_tools"] == "true"
    end

    test "check_auth diamond has conditional routing", %{graph: graph} do
      edges = edges_from(graph, "check_auth")
      assert length(edges) == 2

      targets = Enum.map(edges, & &1.to) |> Enum.sort()
      assert targets == ["format_error", "recall"]

      # Verify conditions
      conditions = Enum.map(edges, &edge_condition/1) |> Enum.sort()
      assert "context.session.input_type!=blocked" in conditions
      assert "context.session.input_type=blocked" in conditions
    end

    test "both paths converge at update_memory", %{graph: graph} do
      # Normal path: format -> update_memory
      format_edges = edges_from(graph, "format")
      assert Enum.any?(format_edges, &(&1.to == "update_memory"))

      # Error path: format_error -> update_memory
      error_edges = edges_from(graph, "format_error")
      assert Enum.any?(error_edges, &(&1.to == "update_memory"))
    end

    test "all nodes reachable from start", %{graph: graph} do
      reachable = reachable_from(graph, "start")

      for {id, _node} <- graph.nodes do
        assert MapSet.member?(reachable, id),
               "Node #{id} not reachable from start"
      end
    end

    test "done is terminal (no outgoing edges)", %{graph: graph} do
      assert edges_from(graph, "done") == []
    end
  end

  describe "session/heartbeat.dot structure" do
    setup do
      %{graph: parse_pipeline("session/heartbeat.dot")}
    end

    test "has all expected nodes", %{graph: graph} do
      expected = ~w(start bg_checks select_mode mode_router build_prompt llm_call
                    consolidate process store_decompositions process_proposals
                    update_wm execute_actions update_goals check_loop
                    build_followup llm_followup done)

      for node_id <- expected do
        assert Map.has_key?(graph.nodes, node_id),
               "Missing node: #{node_id}"
      end
    end

    test "mode_router has 4-way conditional routing", %{graph: graph} do
      edges = edges_from(graph, "mode_router")
      assert length(edges) == 4

      conditions = Enum.map(edges, &edge_condition/1)

      assert "context.session.cognitive_mode=goal_pursuit" in conditions
      assert "context.session.cognitive_mode=reflection" in conditions
      assert "context.session.cognitive_mode=plan_execution" in conditions
      assert "context.session.cognitive_mode=consolidation" in conditions
    end

    test "3 LLM modes route to build_prompt, consolidation routes separately", %{graph: graph} do
      router_edges = edges_from(graph, "mode_router")

      llm_targets =
        router_edges
        |> Enum.filter(
          &(edge_condition(&1) =~ "goal_pursuit" or
              edge_condition(&1) =~ "reflection" or
              edge_condition(&1) =~ "plan_execution")
        )
        |> Enum.map(& &1.to)

      assert Enum.all?(llm_targets, &(&1 == "build_prompt"))

      consol_target =
        router_edges
        |> Enum.find(&(edge_condition(&1) =~ "consolidation"))

      assert consol_target.to == "consolidate"
    end

    test "both LLM and consolidation paths converge at process", %{graph: graph} do
      # LLM path: llm_call -> process
      assert Enum.any?(edges_from(graph, "llm_call"), &(&1.to == "process"))

      # Consolidation path: consolidate -> process
      assert Enum.any?(edges_from(graph, "consolidate"), &(&1.to == "process"))
    end

    test "post-processing tail is correctly ordered", %{graph: graph} do
      # process -> store_decompositions -> process_proposals -> update_wm ->
      # execute_actions -> update_goals -> check_loop
      chain = ~w(process store_decompositions process_proposals update_wm
                 execute_actions update_goals check_loop)

      for [from, to] <- Enum.chunk_every(chain, 2, 1, :discard) do
        assert Enum.any?(edges_from(graph, from), &(&1.to == to)),
               "Missing edge: #{from} -> #{to}"
      end
    end

    test "tool loop has conditional exit and cycle back", %{graph: graph} do
      loop_edges = edges_from(graph, "check_loop")

      # Exit to done (unconditional)
      assert Enum.any?(loop_edges, &(&1.to == "done"))

      # Cycle to build_followup (conditional)
      followup_edge = Enum.find(loop_edges, &(&1.to == "build_followup"))
      assert followup_edge != nil
      assert edge_condition(followup_edge) =~ "has_action_results"
    end

    test "tool loop cycles back to process", %{graph: graph} do
      # build_followup -> llm_followup -> process
      assert Enum.any?(edges_from(graph, "build_followup"), &(&1.to == "llm_followup"))
      assert Enum.any?(edges_from(graph, "llm_followup"), &(&1.to == "process"))
    end

    test "compute nodes have LLM purpose", %{graph: graph} do
      for id <- ["llm_call", "llm_followup"] do
        node = graph.nodes[id]
        assert node.attrs["type"] == "compute"
        assert node.attrs["purpose"] == "llm"
      end
    end

    test "all nodes reachable from start", %{graph: graph} do
      reachable = reachable_from(graph, "start")

      for {id, _node} <- graph.nodes do
        assert MapSet.member?(reachable, id),
               "Node #{id} not reachable from start"
      end
    end
  end

  describe "session/heartbeat-bare.dot structure" do
    setup do
      %{graph: parse_pipeline("session/heartbeat-bare.dot")}
    end

    test "has no memory persistence nodes", %{graph: graph} do
      # Bare variant should NOT have these memory nodes
      refute Map.has_key?(graph.nodes, "store_decompositions")
      refute Map.has_key?(graph.nodes, "process_proposals")
      refute Map.has_key?(graph.nodes, "update_wm")
      refute Map.has_key?(graph.nodes, "update_goals")
    end

    test "process goes directly to execute_actions", %{graph: graph} do
      assert Enum.any?(edges_from(graph, "process"), &(&1.to == "execute_actions"))
    end

    test "has same mode routing as full heartbeat", %{graph: graph} do
      edges = edges_from(graph, "mode_router")
      assert length(edges) == 4

      conditions = Enum.map(edges, &edge_condition/1)
      assert "context.session.cognitive_mode=goal_pursuit" in conditions
      assert "context.session.cognitive_mode=consolidation" in conditions
    end

    test "has tool loop", %{graph: graph} do
      assert Map.has_key?(graph.nodes, "check_loop")
      assert Map.has_key?(graph.nodes, "build_followup")
      assert Map.has_key?(graph.nodes, "llm_followup")
    end
  end
end
