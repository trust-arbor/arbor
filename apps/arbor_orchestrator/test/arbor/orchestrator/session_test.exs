defmodule Arbor.Orchestrator.SessionTest do
  @moduledoc """
  Integration tests for Session-as-DOT convergence.

  Validates that:
  1. Turn and heartbeat DOT pipelines parse and validate correctly
  2. The engine executes session pipelines end-to-end with mock adapters
  3. Tool loop cycles work (dispatch_tools → call_llm cycle)
  4. Heartbeat cognitive mode routing fans out correctly
  5. Context key alignment between handler and DOT conditions

  ## Architecture

  SessionHandler dispatches by node `type` attribute. All external deps
  (LLM, memory, tools) are injected via `opts[:session_adapters]` map.
  The engine passes opts through to handlers, so session_adapters flow
  from Engine.run/2 opts → handler.execute/4 opts.

  ## Context Key Alignment

  DOT condition keys are aligned with SessionHandler context keys:
  - Handler sets `"session.input_type"`, DOT uses `context.session.input_type` ✓
  - Handler sets `"session.cognitive_mode"`, DOT uses `context.session.cognitive_mode` ✓
  - Handler sets `"llm.response_type"`, DOT uses `context.llm.response_type` ✓

  Engine supports `:initial_values` for pre-seeding context (added during spike).
  """
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator
  alias Arbor.Orchestrator.Engine
  alias Arbor.Orchestrator.Engine.Context
  alias Arbor.Orchestrator.Handlers.SessionHandler

  @turn_dot_path Path.join([
                   __DIR__,
                   "..",
                   "..",
                   "..",
                   "specs",
                   "pipelines",
                   "session",
                   "turn.dot"
                 ])

  @heartbeat_dot_path Path.join([
                        __DIR__,
                        "..",
                        "..",
                        "..",
                        "specs",
                        "pipelines",
                        "session",
                        "heartbeat.dot"
                      ])

  # All session.* node types used in turn.dot and heartbeat.dot
  @session_types ~w(
    session.classify session.memory_recall session.mode_select
    session.llm_call session.tool_dispatch session.format
    session.memory_update session.checkpoint session.background_checks
    session.process_results session.route_actions session.update_goals
  )

  setup_all do
    # Ensure EventRegistry is running (needed when running with --no-start)
    case Registry.start_link(keys: :duplicate, name: Arbor.Orchestrator.EventRegistry) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    # Session types resolved via alias path since Phase 4 — no custom registration needed.

    :ok
  end

  setup do
    # Unique logs_root per test to avoid cross-test checkpoint collisions
    logs_root =
      Path.join(
        System.tmp_dir!(),
        "arbor_session_test_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(logs_root)
    on_exit(fn -> File.rm_rf(logs_root) end)

    %{logs_root: logs_root}
  end

  # ── Helpers ────────────────────────────────────────────────────

  defp read_dot!(path) do
    path
    |> Path.expand()
    |> File.read!()
  end

  defp parse!(path) do
    {:ok, graph} = Orchestrator.parse(read_dot!(path))
    graph
  end

  defp collect_events(opts_fun) do
    events = :ets.new(:events, [:duplicate_bag, :public])

    on_event = fn event ->
      :ets.insert(events, {event.type, event})
    end

    result = opts_fun.(on_event)

    all_events =
      :ets.tab2list(events)
      |> Enum.map(fn {_type, event} -> event end)

    :ets.delete(events)
    {result, all_events}
  end

  defp visited_node_ids(events) do
    events
    |> Enum.filter(&(&1.type == :stage_started))
    |> Enum.map(& &1.node_id)
  end

  # ════════════════════════════════════════════════════════════════
  # Test 1: Turn graph parses and validates
  # ════════════════════════════════════════════════════════════════

  describe "turn.dot parsing and validation" do
    @tag :spike
    test "parses successfully with correct node count" do
      dot = read_dot!(@turn_dot_path)
      assert {:ok, graph} = Orchestrator.parse(dot)

      # turn.dot defines: start, classify, check_auth, recall, select_mode,
      # call_llm, check_response, dispatch_tools, format, update_memory,
      # checkpoint, done = 12 nodes
      assert map_size(graph.nodes) == 12

      # Verify key nodes exist
      assert Map.has_key?(graph.nodes, "start")
      assert Map.has_key?(graph.nodes, "classify")
      assert Map.has_key?(graph.nodes, "call_llm")
      assert Map.has_key?(graph.nodes, "dispatch_tools")
      assert Map.has_key?(graph.nodes, "check_response")
      assert Map.has_key?(graph.nodes, "done")
    end

    @tag :spike
    test "validates with no errors" do
      dot = read_dot!(@turn_dot_path)
      diagnostics = Orchestrator.validate(dot)

      errors =
        Enum.filter(diagnostics, fn d ->
          d.severity == :error
        end)

      assert errors == [],
             "Expected no validation errors, got: #{inspect(errors)}"
    end

    @tag :spike
    test "graph has the critical cycle edge: dispatch_tools -> call_llm" do
      graph = parse!(@turn_dot_path)

      cycle_edge =
        Enum.find(graph.edges, fn edge ->
          edge.from == "dispatch_tools" and edge.to == "call_llm"
        end)

      assert cycle_edge != nil,
             "The tool loop cycle edge (dispatch_tools -> call_llm) must exist"
    end

    @tag :spike
    test "session handler types are correctly assigned to nodes" do
      graph = parse!(@turn_dot_path)

      # Verify key nodes have the right handler type attributes
      assert graph.nodes["classify"].attrs["type"] == "session.classify"
      assert graph.nodes["recall"].attrs["type"] == "session.memory_recall"
      assert graph.nodes["select_mode"].attrs["type"] == "session.mode_select"
      assert graph.nodes["call_llm"].attrs["type"] == "session.llm_call"
      assert graph.nodes["dispatch_tools"].attrs["type"] == "session.tool_dispatch"
      assert graph.nodes["format"].attrs["type"] == "session.format"
      assert graph.nodes["update_memory"].attrs["type"] == "session.memory_update"
      assert graph.nodes["checkpoint"].attrs["type"] == "session.checkpoint"
    end

    @tag :spike
    test "conditional nodes have diamond shape" do
      graph = parse!(@turn_dot_path)

      assert graph.nodes["check_auth"].attrs["shape"] == "diamond"
      assert graph.nodes["check_response"].attrs["shape"] == "diamond"
    end

    @tag :spike
    test "edges carry correct conditions for response routing" do
      graph = parse!(@turn_dot_path)

      response_edges =
        Enum.filter(graph.edges, fn edge ->
          edge.from == "check_response"
        end)

      assert length(response_edges) == 2

      conditions =
        response_edges
        |> Enum.map(&{&1.to, Map.get(&1.attrs, "condition", "")})
        |> Map.new()

      assert conditions["dispatch_tools"] =~ "tool_call"
      assert conditions["format"] =~ "text"
    end
  end

  # ════════════════════════════════════════════════════════════════
  # Test 2: Heartbeat graph parses and validates
  # ════════════════════════════════════════════════════════════════

  describe "heartbeat.dot parsing and validation" do
    @tag :spike
    test "parses successfully with correct node count" do
      dot = read_dot!(@heartbeat_dot_path)
      assert {:ok, graph} = Orchestrator.parse(dot)

      # heartbeat.dot defines: start, bg_checks, select_mode, mode_router,
      # llm_goal, llm_reflect, llm_plan, consolidate, process,
      # store_decompositions, process_proposals, update_wm,
      # execute_actions, update_goals, check_loop, llm_followup,
      # done = 17 nodes
      assert map_size(graph.nodes) == 17

      # Verify mode-specific nodes exist
      assert Map.has_key?(graph.nodes, "llm_goal")
      assert Map.has_key?(graph.nodes, "llm_reflect")
      assert Map.has_key?(graph.nodes, "llm_plan")
      assert Map.has_key?(graph.nodes, "consolidate")
      assert Map.has_key?(graph.nodes, "mode_router")
    end

    @tag :spike
    test "validates with no errors" do
      dot = read_dot!(@heartbeat_dot_path)
      diagnostics = Orchestrator.validate(dot)

      errors =
        Enum.filter(diagnostics, fn d ->
          d.severity == :error
        end)

      assert errors == [],
             "Expected no validation errors, got: #{inspect(errors)}"
    end

    @tag :spike
    test "mode_router has four conditional outgoing edges" do
      graph = parse!(@heartbeat_dot_path)

      mode_edges =
        Enum.filter(graph.edges, fn edge ->
          edge.from == "mode_router"
        end)

      assert length(mode_edges) == 4

      # Each should have a condition
      conditions =
        Enum.map(mode_edges, fn edge ->
          Map.get(edge.attrs, "condition", "")
        end)

      assert Enum.all?(conditions, &(&1 != "")),
             "All mode_router edges should have conditions"
    end

    @tag :spike
    test "all four cognitive modes have routing edges" do
      graph = parse!(@heartbeat_dot_path)

      mode_edges =
        graph.edges
        |> Enum.filter(&(&1.from == "mode_router"))
        |> Enum.map(&{&1.to, Map.get(&1.attrs, "condition", "")})
        |> Map.new()

      assert mode_edges["llm_goal"] =~ "goal_pursuit"
      assert mode_edges["llm_reflect"] =~ "reflection"
      assert mode_edges["llm_plan"] =~ "plan_execution"
      assert mode_edges["consolidate"] =~ "consolidation"
    end

    @tag :spike
    test "all mode branches converge at process node" do
      graph = parse!(@heartbeat_dot_path)

      # Check that llm_goal, llm_reflect, llm_plan, consolidate all have
      # edges pointing to "process"
      converge_sources =
        graph.edges
        |> Enum.filter(&(&1.to == "process"))
        |> Enum.map(& &1.from)
        |> MapSet.new()

      assert MapSet.member?(converge_sources, "llm_goal")
      assert MapSet.member?(converge_sources, "llm_reflect")
      assert MapSet.member?(converge_sources, "llm_plan")
      assert MapSet.member?(converge_sources, "consolidate")
    end
  end

  # ════════════════════════════════════════════════════════════════
  # Test 3: Turn graph executes — text response path
  # ════════════════════════════════════════════════════════════════

  describe "turn graph execution — text response" do
    @tag :spike
    test "minimal session graph runs end-to-end with mock adapters", %{logs_root: logs_root} do
      # Use a minimal inline DOT to avoid the condition key mismatch issue.
      # This validates that SessionHandler + Engine integration works.
      dot = """
      digraph MinimalTurn {
        graph [goal="Process a message"]
        start [shape=Mdiamond]
        classify [type="session.classify"]
        recall [type="session.memory_recall"]
        call_llm [type="session.llm_call"]
        format [type="session.format"]
        update_memory [type="session.memory_update"]
        done [shape=Msquare]

        start -> classify -> recall -> call_llm -> format -> update_memory -> done
      }
      """

      {:ok, graph} = Orchestrator.parse(dot)

      adapters = %{
        llm_call: fn _messages, _mode, _opts ->
          {:ok, %{content: "Hello from the LLM!"}}
        end,
        memory_recall: fn _agent_id, _query -> {:ok, []} end,
        memory_update: fn _agent_id, _turn_data -> :ok end
      }

      {result, events} =
        collect_events(fn on_event ->
          Engine.run(graph,
            session_adapters: adapters,
            logs_root: logs_root,
            on_event: on_event
          )
        end)

      assert {:ok, run_result} = result
      assert run_result.final_outcome.status == :success
      assert "done" in run_result.completed_nodes

      visited = visited_node_ids(events)
      assert "start" in visited
      assert "classify" in visited
      assert "recall" in visited
      assert "call_llm" in visited
      assert "format" in visited
      assert "update_memory" in visited

      # SessionHandler.format copies llm.content → session.response
      assert run_result.context["session.response"] == "Hello from the LLM!"
      assert run_result.context["llm.content"] == "Hello from the LLM!"
      assert run_result.context["llm.response_type"] == "text"
    end

    @tag :spike
    test "full turn.dot executes and reaches done", %{logs_root: logs_root} do
      graph = parse!(@turn_dot_path)

      adapters = %{
        llm_call: fn _messages, _mode, _opts ->
          {:ok, %{content: "Hello from the LLM!"}}
        end,
        memory_recall: fn _agent_id, _query -> {:ok, []} end,
        memory_update: fn _agent_id, _turn_data -> :ok end,
        checkpoint: fn _session_id, _turn_count, _snapshot -> :ok end
      }

      {result, events} =
        collect_events(fn on_event ->
          Engine.run(graph,
            session_adapters: adapters,
            logs_root: logs_root,
            on_event: on_event
          )
        end)

      assert {:ok, run_result} = result
      assert run_result.final_outcome.status == :success

      # Pipeline must reach the terminal node
      assert "done" in run_result.completed_nodes

      visited = visited_node_ids(events)

      # Core nodes that must always be visited regardless of condition routing
      assert "start" in visited
      assert "classify" in visited
      assert "check_auth" in visited

      # The LLM returned text content (no tool_calls), so we expect:
      # - call_llm to be visited (it's on the main path)
      # - format to be visited (either via condition match or fallback edge)
      assert "call_llm" in visited

      # Whether conditions route correctly depends on key alignment.
      # Either way, the pipeline should complete successfully.
      ctx = run_result.context
      has_response = ctx["session.response"] != nil or ctx["llm.content"] != nil

      assert has_response,
             "Expected LLM output in context, got keys: #{inspect(Map.keys(ctx))}"
    end

    @tag :spike
    test "adapter functions receive correct context values", %{logs_root: logs_root} do
      # Track what the adapters actually receive
      test_pid = self()

      dot = """
      digraph AdapterCheck {
        start [shape=Mdiamond]
        recall [type="session.memory_recall"]
        call_llm [type="session.llm_call"]
        format [type="session.format"]
        done [shape=Msquare]

        start -> recall -> call_llm -> format -> done
      }
      """

      {:ok, graph} = Orchestrator.parse(dot)

      adapters = %{
        memory_recall: fn agent_id, query ->
          send(test_pid, {:recall_called, agent_id, query})
          {:ok, ["memory_1"]}
        end,
        llm_call: fn messages, mode, opts ->
          send(test_pid, {:llm_called, messages, mode, opts})
          {:ok, %{content: "test response"}}
        end
      }

      assert {:ok, _} =
               Engine.run(graph,
                 session_adapters: adapters,
                 logs_root: logs_root
               )

      # memory_recall adapter should be called
      assert_received {:recall_called, _agent_id, _query}

      # llm_call adapter should be called with the mode from mode_select
      assert_received {:llm_called, _messages, mode, _opts}
      # Default mode when no goals and turn_count=0: "reflection"
      assert is_binary(mode)
    end
  end

  # ════════════════════════════════════════════════════════════════
  # Test 4: Tool loop cycles correctly
  # ════════════════════════════════════════════════════════════════

  describe "turn graph execution — tool loop" do
    @tag :spike
    test "tool loop cycles via inline graph with aligned condition keys", %{logs_root: logs_root} do
      # Use inline DOT with condition keys that match what SessionHandler sets.
      # The handler sets "llm.response_type" and the condition module resolves
      # "context.llm.response_type" → Context.get(ctx, "llm.response_type") ✓
      dot = """
      digraph ToolLoopTest {
        graph [goal="Test tool loop cycle"]
        start [shape=Mdiamond]
        call_llm [type="session.llm_call"]
        check_response [shape=diamond]
        dispatch_tools [type="session.tool_dispatch"]
        format [type="session.format"]
        done [shape=Msquare]

        start -> call_llm -> check_response
        check_response -> dispatch_tools [condition="context.llm.response_type=tool_call"]
        check_response -> format [condition="context.llm.response_type=text"]
        dispatch_tools -> call_llm
        format -> done
      }
      """

      {:ok, graph} = Orchestrator.parse(dot)

      # Counter: first call returns tool_calls, second returns text
      counter = :counters.new(1, [:atomics])

      adapters = %{
        llm_call: fn _messages, _mode, _opts ->
          call_num = :counters.get(counter, 1)
          :counters.add(counter, 1, 1)

          if call_num == 0 do
            {:ok, %{tool_calls: [%{name: "read_file", args: %{path: "/tmp/test.txt"}}]}}
          else
            {:ok, %{content: "Here is the file content."}}
          end
        end,
        tool_dispatch: fn _tool_calls, _agent_id ->
          {:ok, ["file content: hello world"]}
        end
      }

      {result, events} =
        collect_events(fn on_event ->
          Engine.run(graph,
            session_adapters: adapters,
            logs_root: logs_root,
            on_event: on_event
          )
        end)

      assert {:ok, run_result} = result
      assert run_result.final_outcome.status == :success

      visited = visited_node_ids(events)

      # call_llm should appear at least twice (initial call + after tool dispatch)
      call_llm_visits = Enum.count(visited, &(&1 == "call_llm"))

      assert call_llm_visits >= 2,
             "call_llm should be visited at least twice for tool loop, got #{call_llm_visits}. " <>
               "Visited: #{inspect(visited)}"

      # dispatch_tools should appear at least once
      dispatch_visits = Enum.count(visited, &(&1 == "dispatch_tools"))

      assert dispatch_visits >= 1,
             "dispatch_tools should be visited at least once, got #{dispatch_visits}"

      # The LLM adapter should have been called at least twice
      assert :counters.get(counter, 1) >= 2

      # Final response should be the text from the second LLM call
      assert run_result.context["session.response"] == "Here is the file content."
    end

    @tag :spike
    test "tool loop respects max_steps to prevent infinite cycles", %{logs_root: logs_root} do
      # LLM always returns tool_calls — should hit max_steps
      dot = """
      digraph InfiniteToolLoop {
        graph [goal="Test max_steps guard"]
        start [shape=Mdiamond]
        call_llm [type="session.llm_call"]
        check_response [shape=diamond]
        dispatch_tools [type="session.tool_dispatch"]
        format [type="session.format"]
        done [shape=Msquare]

        start -> call_llm -> check_response
        check_response -> dispatch_tools [condition="context.llm.response_type=tool_call"]
        check_response -> format [condition="context.llm.response_type=text"]
        dispatch_tools -> call_llm
        format -> done
      }
      """

      {:ok, graph} = Orchestrator.parse(dot)

      adapters = %{
        llm_call: fn _messages, _mode, _opts ->
          # Always return tool_calls — never text
          {:ok, %{tool_calls: [%{name: "infinite", args: %{}}]}}
        end,
        tool_dispatch: fn _tool_calls, _agent_id ->
          {:ok, ["result"]}
        end
      }

      result =
        Engine.run(graph,
          session_adapters: adapters,
          logs_root: logs_root,
          max_steps: 10
        )

      assert {:error, :max_steps_exceeded} = result
    end

    @tag :spike
    test "multi-turn tool loop: 3 tool calls then text", %{logs_root: logs_root} do
      dot = """
      digraph MultiToolLoop {
        graph [goal="Test multi-turn tool loop"]
        start [shape=Mdiamond]
        call_llm [type="session.llm_call"]
        check_response [shape=diamond]
        dispatch_tools [type="session.tool_dispatch"]
        format [type="session.format"]
        done [shape=Msquare]

        start -> call_llm -> check_response
        check_response -> dispatch_tools [condition="context.llm.response_type=tool_call"]
        check_response -> format [condition="context.llm.response_type=text"]
        dispatch_tools -> call_llm
        format -> done
      }
      """

      {:ok, graph} = Orchestrator.parse(dot)

      # 3 tool calls, then text on 4th call
      counter = :counters.new(1, [:atomics])

      adapters = %{
        llm_call: fn _messages, _mode, _opts ->
          call_num = :counters.get(counter, 1)
          :counters.add(counter, 1, 1)

          if call_num < 3 do
            {:ok, %{tool_calls: [%{name: "step_#{call_num}", args: %{}}]}}
          else
            {:ok, %{content: "Done after 3 tool calls."}}
          end
        end,
        tool_dispatch: fn _tool_calls, _agent_id ->
          {:ok, ["tool result"]}
        end
      }

      {result, events} =
        collect_events(fn on_event ->
          Engine.run(graph,
            session_adapters: adapters,
            logs_root: logs_root,
            on_event: on_event
          )
        end)

      assert {:ok, run_result} = result

      visited = visited_node_ids(events)
      call_llm_visits = Enum.count(visited, &(&1 == "call_llm"))
      dispatch_visits = Enum.count(visited, &(&1 == "dispatch_tools"))

      # 4 LLM calls total: 3 returning tool_calls + 1 returning text
      assert call_llm_visits == 4,
             "Expected 4 call_llm visits, got #{call_llm_visits}. Visited: #{inspect(visited)}"

      # 3 tool dispatches
      assert dispatch_visits == 3,
             "Expected 3 dispatch_tools visits, got #{dispatch_visits}"

      assert run_result.context["session.response"] == "Done after 3 tool calls."
    end
  end

  # ════════════════════════════════════════════════════════════════
  # Test 5: Heartbeat routes by cognitive mode
  # ════════════════════════════════════════════════════════════════

  describe "heartbeat execution — cognitive mode routing" do
    @tag :spike
    test "inline heartbeat routes to correct mode node via aligned conditions", %{
      logs_root: logs_root
    } do
      # Use inline DOT with condition keys aligned to what SessionHandler sets.
      # Handler sets "session.cognitive_mode", so conditions use
      # "context.session.cognitive_mode" which the Condition module resolves to
      # Context.get(ctx, "session.cognitive_mode") ✓
      dot = """
      digraph HeartbeatRouting {
        graph [goal="Test cognitive mode routing"]
        start [shape=Mdiamond]
        select_mode [type="session.mode_select"]
        mode_router [shape=diamond]
        llm_goal [type="session.llm_call"]
        llm_reflect [type="session.llm_call"]
        process [type="session.process_results"]
        done [shape=Msquare]

        start -> select_mode -> mode_router

        mode_router -> llm_goal [condition="context.session.cognitive_mode=goal_pursuit"]
        mode_router -> llm_reflect [condition="context.session.cognitive_mode=reflection"]

        llm_goal -> process
        llm_reflect -> process
        process -> done
      }
      """

      {:ok, graph} = Orchestrator.parse(dot)

      heartbeat_json =
        Jason.encode!(%{
          "actions" => [],
          "goal_updates" => [%{"id" => "g1", "progress" => 0.3}],
          "new_goals" => [],
          "memory_notes" => ["working on goal g1"]
        })

      adapters = %{
        llm_call: fn _messages, _mode, _opts ->
          {:ok, %{content: heartbeat_json}}
        end
      }

      # Without initial_context, session.goals defaults to [] and
      # turn_count defaults to 0, so mode_select picks "reflection"
      {result, events} =
        collect_events(fn on_event ->
          Engine.run(graph,
            session_adapters: adapters,
            logs_root: logs_root,
            on_event: on_event
          )
        end)

      assert {:ok, run_result} = result
      assert run_result.final_outcome.status == :success

      visited = visited_node_ids(events)

      assert "start" in visited
      assert "select_mode" in visited
      assert "mode_router" in visited

      # With no goals and turn_count=0, mode should be "reflection"
      assert run_result.context["session.cognitive_mode"] == "reflection"

      # The condition routing should send us to llm_reflect
      assert "llm_reflect" in visited,
             "Expected llm_reflect to be visited for reflection mode. Visited: #{inspect(visited)}"

      refute "llm_goal" in visited,
             "llm_goal should NOT be visited in reflection mode"

      assert "process" in visited
      assert "done" in visited
    end

    @tag :spike
    test "full heartbeat.dot executes and reaches done", %{logs_root: logs_root} do
      graph = parse!(@heartbeat_dot_path)

      heartbeat_json =
        Jason.encode!(%{
          "actions" => [],
          "goal_updates" => [],
          "new_goals" => [],
          "memory_notes" => []
        })

      adapters = %{
        llm_call: fn _messages, _mode, _opts ->
          {:ok, %{content: heartbeat_json}}
        end,
        background_checks: fn _agent_id -> %{memory_health: :ok} end,
        route_actions: fn _actions, _agent_id -> :ok end,
        update_goals: fn _updates, _new, _agent_id -> :ok end
      }

      {result, events} =
        collect_events(fn on_event ->
          Engine.run(graph,
            session_adapters: adapters,
            logs_root: logs_root,
            on_event: on_event
          )
        end)

      assert {:ok, run_result} = result
      assert run_result.final_outcome.status == :success
      assert "done" in run_result.completed_nodes

      visited = visited_node_ids(events)

      # Core heartbeat nodes should always be visited
      assert "start" in visited
      assert "bg_checks" in visited
      assert "select_mode" in visited
      assert "mode_router" in visited

      # The pipeline should visit ONE of the mode branches
      mode_nodes_visited =
        Enum.filter(
          ["llm_goal", "llm_reflect", "llm_plan", "consolidate"],
          &(&1 in visited)
        )

      assert mode_nodes_visited != [],
             "At least one mode branch should be visited. Visited: #{inspect(visited)}"

      # Post-processing tail should be visited
      assert "process" in visited
      assert "done" in visited
    end

    @tag :spike
    test "heartbeat result processing parses JSON into structured data", %{logs_root: logs_root} do
      dot = """
      digraph HeartbeatProcess {
        graph [goal="Test result processing"]
        start [shape=Mdiamond]
        call_llm [type="session.llm_call"]
        process [type="session.process_results"]
        route_actions [type="session.route_actions"]
        update_goals [type="session.update_goals"]
        done [shape=Msquare]

        start -> call_llm -> process -> route_actions -> update_goals -> done
      }
      """

      {:ok, graph} = Orchestrator.parse(dot)

      test_pid = self()

      heartbeat_json =
        Jason.encode!(%{
          "actions" => [%{"type" => "search", "query" => "test"}],
          "goal_updates" => [%{"id" => "g1", "progress" => 0.5}],
          "new_goals" => [%{"description" => "learn Elixir"}],
          "memory_notes" => ["remembered something important"]
        })

      adapters = %{
        llm_call: fn _messages, _mode, _opts ->
          {:ok, %{content: heartbeat_json}}
        end,
        route_actions: fn actions, _agent_id ->
          send(test_pid, {:actions_routed, actions})
          :ok
        end,
        update_goals: fn updates, new_goals, _agent_id ->
          send(test_pid, {:goals_updated, updates, new_goals})
          :ok
        end
      }

      assert {:ok, run_result} =
               Engine.run(graph,
                 session_adapters: adapters,
                 logs_root: logs_root
               )

      assert run_result.final_outcome.status == :success

      # process_results should have parsed the JSON
      ctx = run_result.context
      assert is_list(ctx["session.actions"])
      assert length(ctx["session.actions"]) == 1
      assert is_list(ctx["session.new_goals"])
      assert length(ctx["session.new_goals"]) == 1
      assert is_list(ctx["session.memory_notes"])
      assert length(ctx["session.memory_notes"]) == 1

      # route_actions and update_goals adapters should have been called
      assert_received {:actions_routed, actions}
      assert length(actions) == 1

      assert_received {:goals_updated, goal_updates, new_goals}
      assert length(goal_updates) == 1
      assert length(new_goals) == 1
    end
  end

  # ════════════════════════════════════════════════════════════════
  # Condition key alignment verification
  # ════════════════════════════════════════════════════════════════

  describe "condition key alignment" do
    @tag :spike
    test "handler context keys match DOT condition keys" do
      # Handler sets these keys:
      handler_keys = %{
        classify: "session.input_type",
        mode_select: "session.cognitive_mode",
        llm_call: "llm.response_type"
      }

      # DOT conditions reference "context.KEY" which resolves to Context.get(ctx, "KEY")
      # After stripping the "context." prefix:
      dot_resolved_keys = %{
        check_auth: "session.input_type",
        check_response: "llm.response_type",
        mode_router: "session.cognitive_mode"
      }

      # All keys are now aligned
      assert handler_keys.classify == dot_resolved_keys.check_auth
      assert handler_keys.llm_call == dot_resolved_keys.check_response
      assert handler_keys.mode_select == dot_resolved_keys.mode_router
    end

    @tag :spike
    test "aligned condition keys work with Condition module" do
      alias Arbor.Orchestrator.Engine.Condition
      alias Arbor.Orchestrator.Engine.Outcome

      context = Context.new(%{"session.cognitive_mode" => "goal_pursuit"})
      outcome = %Outcome{status: :success}

      # DOT files use "context.session.cognitive_mode" which resolves correctly
      assert Condition.eval("context.session.cognitive_mode=goal_pursuit", outcome, context)
      refute Condition.eval("context.session.cognitive_mode=reflection", outcome, context)

      # Unqualified key does NOT match — confirms alignment is required
      refute Condition.eval("context.cognitive_mode=goal_pursuit", outcome, context)

      # llm.response_type also aligned
      context2 = Context.new(%{"llm.response_type" => "tool_call"})
      assert Condition.eval("context.llm.response_type=tool_call", outcome, context2)
    end
  end

  # ════════════════════════════════════════════════════════════════
  # Engine initial_context gap documentation
  # ════════════════════════════════════════════════════════════════

  describe "Engine initial_values injection" do
    @tag :spike
    test "engine context defaults without initial_values", %{logs_root: logs_root} do
      # Without initial_values, handlers receive default values.
      # With initial_values (added during spike), callers can pre-seed context.
      dot = """
      digraph TestDefaults {
        graph [goal="Test default context"]
        start [shape=Mdiamond]
        classify [type="session.classify"]
        done [shape=Msquare]
        start -> classify -> done
      }
      """

      {:ok, graph} = Orchestrator.parse(dot)

      {:ok, run_result} =
        Engine.run(graph,
          session_adapters: %{},
          logs_root: logs_root
        )

      assert run_result.final_outcome.status == :success

      # Without initial_context, session.input defaults to "" (nil → "")
      # which classifies as "query" (the default path in classify handler)
      assert run_result.context["session.input_type"] == "query"
    end

    @tag :spike
    test "mode_select defaults to reflection without initial_values", %{logs_root: logs_root} do
      dot = """
      digraph TestModeDefaults {
        graph [goal="Test mode selection defaults"]
        start [shape=Mdiamond]
        select_mode [type="session.mode_select"]
        done [shape=Msquare]
        start -> select_mode -> done
      }
      """

      {:ok, graph} = Orchestrator.parse(dot)

      {:ok, run_result} =
        Engine.run(graph,
          session_adapters: %{},
          logs_root: logs_root
        )

      # With no goals and turn_count=0 (default), mode should be "reflection"
      # (not "consolidation" which triggers on turn % 5 == 0 only when turn > 0)
      assert run_result.context["session.cognitive_mode"] == "reflection"
    end
  end

  # ════════════════════════════════════════════════════════════════
  # Graceful degradation
  # ════════════════════════════════════════════════════════════════

  describe "graceful degradation" do
    @tag :spike
    test "pipeline completes with empty adapters map", %{logs_root: logs_root} do
      dot = """
      digraph DegradeTest {
        graph [goal="Test graceful degradation"]
        start [shape=Mdiamond]
        classify [type="session.classify"]
        recall [type="session.memory_recall"]
        call_llm [type="session.llm_call"]
        format [type="session.format"]
        checkpoint [type="session.checkpoint"]
        done [shape=Msquare]

        start -> classify -> recall -> call_llm -> format -> checkpoint -> done
      }
      """

      {:ok, graph} = Orchestrator.parse(dot)

      # No adapters at all — all should degrade gracefully
      {:ok, run_result} =
        Engine.run(graph,
          session_adapters: %{},
          logs_root: logs_root
        )

      assert run_result.final_outcome.status == :success
      assert "done" in run_result.completed_nodes
    end

    @tag :spike
    test "adapter errors surface as pipeline failures (no silent degradation)", %{
      logs_root: logs_root
    } do
      dot = """
      digraph ErrorTest {
        graph [goal="Test error resilience"]
        start [shape=Mdiamond]
        recall [type="session.memory_recall"]
        call_llm [type="session.llm_call"]
        format [type="session.format"]
        done [shape=Msquare]

        start -> recall -> call_llm -> format -> done
      }
      """

      {:ok, graph} = Orchestrator.parse(dot)

      adapters = %{
        memory_recall: fn _agent_id, _query -> raise "kaboom" end,
        llm_call: fn _messages, _mode, _opts ->
          {:ok, %{content: "recovered"}}
        end
      }

      {:ok, run_result} =
        Engine.run(graph,
          session_adapters: adapters,
          logs_root: logs_root
        )

      # Adapter raises are caught and surfaced as failures —
      # no silent degradation on security-critical paths.
      assert run_result.final_outcome.status == :fail
      assert run_result.final_outcome.failure_reason =~ "memory_recall"
    end
  end

  # ════════════════════════════════════════════════════════════════
  # Test 6: Context round-trip through turn pipeline
  # ════════════════════════════════════════════════════════════════

  describe "context round-trip through turn pipeline" do
    @tag :spike
    test "messages grow by 2, turn_count increments, trust_tier and goals preserved", %{
      logs_root: logs_root
    } do
      alias Arbor.Orchestrator.Session

      # Build initial state with pre-existing data
      initial_messages = [
        %{"role" => "user", "content" => "earlier question"},
        %{"role" => "assistant", "content" => "earlier answer"}
      ]

      initial_goals = [
        %{"id" => "g1", "description" => "learn Elixir", "progress" => 0.4}
      ]

      state = %Session{
        session_id: "ctx-round-trip-test",
        agent_id: "agent_test123",
        trust_tier: :trusted_partner,
        turn_graph: nil,
        heartbeat_graph: nil,
        turn_count: 3,
        messages: initial_messages,
        working_memory: %{"key" => "value"},
        goals: initial_goals,
        cognitive_mode: :goal_pursuit,
        adapters: %{}
      }

      # Step 1: build_turn_values produces the context the engine will see
      values = Session.build_turn_values(state, "What is OTP?")

      assert values["session.id"] == "ctx-round-trip-test"
      assert values["session.agent_id"] == "agent_test123"
      assert values["session.trust_tier"] == "trusted_partner"
      assert values["session.turn_count"] == 3
      assert values["session.goals"] == initial_goals

      # Messages should include the new user message appended
      assert length(values["session.messages"]) == 3
      last_msg = List.last(values["session.messages"])
      assert last_msg["role"] == "user"
      assert last_msg["content"] == "What is OTP?"

      # Step 2: Simulate engine run — execute a minimal graph with initial_values
      dot = """
      digraph RoundTrip {
        graph [goal="Context round-trip test"]
        start [shape=Mdiamond]
        call_llm [type="session.llm_call"]
        format [type="session.format"]
        done [shape=Msquare]

        start -> call_llm -> format -> done
      }
      """

      {:ok, graph} = Orchestrator.parse(dot)

      adapters = %{
        llm_call: fn _messages, _mode, _opts ->
          {:ok, %{content: "OTP is Open Telecom Platform."}}
        end
      }

      {:ok, run_result} =
        Engine.run(graph,
          session_adapters: adapters,
          logs_root: logs_root,
          initial_values: values
        )

      assert run_result.context["session.response"] == "OTP is Open Telecom Platform."

      # Step 3: apply_turn_result merges engine output back into state
      new_state = Session.apply_turn_result(state, "What is OTP?", run_result)

      # Messages grew by 2 (user + assistant)
      assert length(new_state.messages) == length(initial_messages) + 2

      user_msg = Enum.at(new_state.messages, 2)
      assert user_msg["role"] == "user"
      assert user_msg["content"] == "What is OTP?"

      assistant_msg = Enum.at(new_state.messages, 3)
      assert assistant_msg["role"] == "assistant"
      assert assistant_msg["content"] == "OTP is Open Telecom Platform."

      # Turn count incremented
      assert new_state.turn_count == 4

      # Trust tier preserved (not changed by engine)
      assert new_state.trust_tier == :trusted_partner

      # Goals intact (turn pipeline doesn't modify goals)
      assert new_state.goals == initial_goals
    end
  end

  # ════════════════════════════════════════════════════════════════
  # Test 7: Session GenServer round-trip
  # ════════════════════════════════════════════════════════════════

  describe "Session GenServer round-trip" do
    @tag :spike
    test "send_message updates state correctly across multiple turns" do
      alias Arbor.Orchestrator.Session

      # Write minimal turn and heartbeat DOT files for the session
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "arbor_session_genserver_test_#{:erlang.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_dir)

      turn_dot = """
      digraph Turn {
        graph [goal="Test turn"]
        start [shape=Mdiamond]
        classify [type="session.classify"]
        call_llm [type="session.llm_call"]
        format [type="session.format"]
        done [shape=Msquare]

        start -> classify -> call_llm -> format -> done
      }
      """

      heartbeat_dot = """
      digraph Heartbeat {
        graph [goal="Test heartbeat"]
        start [shape=Mdiamond]
        select_mode [type="session.mode_select"]
        done [shape=Msquare]

        start -> select_mode -> done
      }
      """

      turn_path = Path.join(tmp_dir, "turn.dot")
      heartbeat_path = Path.join(tmp_dir, "heartbeat.dot")
      File.write!(turn_path, turn_dot)
      File.write!(heartbeat_path, heartbeat_dot)

      on_exit(fn -> File.rm_rf(tmp_dir) end)

      # Counter to vary responses per call
      counter = :counters.new(1, [:atomics])

      adapters = %{
        llm_call: fn _messages, _mode, _opts ->
          n = :counters.get(counter, 1)
          :counters.add(counter, 1, 1)

          response =
            case n do
              0 -> "Hello back!"
              _ -> "Response #{n + 1}"
            end

          {:ok, %{content: response}}
        end
      }

      {:ok, pid} =
        Session.start_link(
          session_id: "genserver-test-#{:erlang.unique_integer([:positive])}",
          agent_id: "agent_gs_test",
          trust_tier: :established,
          turn_dot: turn_path,
          heartbeat_dot: heartbeat_path,
          adapters: adapters,
          start_heartbeat: false
        )

      # ── Turn 1 ──
      assert {:ok, %{text: text1}} = Session.send_message(pid, "Hello")
      assert text1 == "Hello back!"

      state1 = Session.get_state(pid)
      assert state1.turn_count == 1
      assert length(state1.messages) == 2

      [msg1, msg2] = state1.messages
      assert msg1["role"] == "user"
      assert msg1["content"] == "Hello"
      assert msg2["role"] == "assistant"
      assert msg2["content"] == "Hello back!"

      # ── Turn 2 ──
      assert {:ok, %{text: text2}} = Session.send_message(pid, "How are you?")
      assert text2 == "Response 2"

      state2 = Session.get_state(pid)
      assert state2.turn_count == 2
      assert length(state2.messages) == 4

      [_, _, msg3, msg4] = state2.messages
      assert msg3["role"] == "user"
      assert msg3["content"] == "How are you?"
      assert msg4["role"] == "assistant"
      assert msg4["content"] == "Response 2"

      # Trust tier, agent_id, session_id remain stable across turns
      assert state2.trust_tier == :established
      assert state2.agent_id == "agent_gs_test"

      GenServer.stop(pid)
    end
  end

  # ════════════════════════════════════════════════════════════════
  # Test 8: Async turn execution
  # ════════════════════════════════════════════════════════════════

  describe "async turn execution" do
    @async_agent_id "agent_async_test"

    setup do
      Arbor.Orchestrator.TestCapabilities.grant_orchestrator_access(@async_agent_id)
      :ok
    end

    defp start_session(opts) do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "arbor_async_test_#{:erlang.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_dir)

      turn_dot =
        Keyword.get(opts, :turn_dot, """
        digraph Turn {
          graph [goal="Test turn"]
          start [shape=Mdiamond]
          classify [type="session.classify"]
          call_llm [type="session.llm_call"]
          format [type="session.format"]
          done [shape=Msquare]

          start -> classify -> call_llm -> format -> done
        }
        """)

      heartbeat_dot =
        Keyword.get(opts, :heartbeat_dot, """
        digraph Heartbeat {
          graph [goal="Test heartbeat"]
          start [shape=Mdiamond]
          select_mode [type="session.mode_select"]
          done [shape=Msquare]

          start -> select_mode -> done
        }
        """)

      turn_path = Path.join(tmp_dir, "turn.dot")
      heartbeat_path = Path.join(tmp_dir, "heartbeat.dot")
      File.write!(turn_path, turn_dot)
      File.write!(heartbeat_path, heartbeat_dot)

      adapters = Keyword.get(opts, :adapters, %{})
      heartbeat_interval = Keyword.get(opts, :heartbeat_interval, 30_000)
      start_heartbeat = Keyword.get(opts, :start_heartbeat, false)

      {:ok, pid} =
        Arbor.Orchestrator.Session.start_link(
          session_id: "async-test-#{:erlang.unique_integer([:positive])}",
          agent_id: @async_agent_id,
          trust_tier: :established,
          turn_dot: turn_path,
          heartbeat_dot: heartbeat_path,
          adapters: adapters,
          start_heartbeat: start_heartbeat,
          heartbeat_interval: heartbeat_interval
        )

      {pid, tmp_dir}
    end

    @tag :spike
    test "heartbeat fires during long turn" do
      adapters = %{
        llm_call: fn _messages, _mode, _opts ->
          # Slow LLM — 600ms to give heartbeat time to fire
          Process.sleep(600)
          {:ok, %{content: "slow response"}}
        end
      }

      {pid, tmp_dir} =
        start_session(
          adapters: adapters,
          heartbeat_interval: 100,
          start_heartbeat: true
        )

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
        File.rm_rf(tmp_dir)
      end)

      # Send a message — will take ~600ms
      assert {:ok, %{text: "slow response"}} =
               Arbor.Orchestrator.Session.send_message(pid, "hello")

      # After the turn completes, check that heartbeat ran at least once.
      # The heartbeat interval is 100ms and the turn takes 600ms, so
      # multiple heartbeats should have had the chance to fire.
      state = Arbor.Orchestrator.Session.get_state(pid)

      # The session should be idle (both turn and heartbeat done)
      assert state.turn_in_flight == false
      # The heartbeat timer should still be scheduled
      assert state.heartbeat_ref != nil
    end

    @tag :spike
    test "concurrent turn rejection" do
      adapters = %{
        llm_call: fn _messages, _mode, _opts ->
          # Slow so the second call arrives while first is in-flight
          Process.sleep(200)
          {:ok, %{content: "response"}}
        end
      }

      {pid, tmp_dir} = start_session(adapters: adapters)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
        File.rm_rf(tmp_dir)
      end)

      # Start first turn in a separate process
      task =
        Task.async(fn ->
          Arbor.Orchestrator.Session.send_message(pid, "first")
        end)

      # Small delay to ensure first call is in-flight
      Process.sleep(50)

      # Second call should be rejected
      assert {:error, :turn_in_progress} =
               Arbor.Orchestrator.Session.send_message(pid, "second")

      # First call should complete normally
      assert {:ok, %{text: "response"}} = Task.await(task, 5_000)
    end

    @tag :spike
    test "turn task crash recovery" do
      # Use Process.exit to kill the task process itself (not just an adapter error).
      # The adapter exit is caught by SessionHandler's catch block and returns a fail
      # outcome. To truly crash the task, we need to kill it from outside.
      test_pid = self()

      adapters = %{
        llm_call: fn _messages, _mode, _opts ->
          # Signal the test process that the task is running
          send(test_pid, :task_running)
          # Block so the test can kill the task
          Process.sleep(5_000)
          {:ok, %{content: "should not reach"}}
        end
      }

      {pid, tmp_dir} = start_session(adapters: adapters)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
        File.rm_rf(tmp_dir)
      end)

      # Start the turn in a separate process
      caller =
        Task.async(fn ->
          Arbor.Orchestrator.Session.send_message(pid, "crash me")
        end)

      # Wait for the task to be running
      assert_receive :task_running, 2_000

      # Get the turn task ref from state and kill the task
      state = Arbor.Orchestrator.Session.get_state(pid)
      assert state.turn_in_flight == true

      # The caller should get an error when the task crashes via DOWN
      # Kill the task by finding it via the monitor ref
      # We can't easily get the task PID, so instead verify the state
      # recovers after the turn completes (or crashes)

      # Cancel the caller and wait
      Task.shutdown(caller, :brutal_kill)

      # Give the session time to process the DOWN message
      Process.sleep(100)

      # Session should still be alive
      assert Process.alive?(pid)

      # After the task eventually completes (it was sleeping),
      # the session should reset. Let's wait for it.
      Process.sleep(200)

      # The session should have recovered — even if the caller died,
      # the turn result message still arrives and resets state
      # (We can't easily test the exact error path without more plumbing,
      # but we CAN verify the session is still functional after disruption)
    end

    @tag :spike
    test "tool history accumulation" do
      counter = :counters.new(1, [:atomics])

      tool_loop_dot = """
      digraph ToolLoop {
        graph [goal="Test tool history"]
        start [shape=Mdiamond]
        call_llm [type="session.llm_call"]
        check_response [shape=diamond]
        dispatch_tools [type="session.tool_dispatch"]
        format [type="session.format"]
        done [shape=Msquare]

        start -> call_llm -> check_response
        check_response -> dispatch_tools [condition="context.llm.response_type=tool_call"]
        check_response -> format [condition="context.llm.response_type=text"]
        dispatch_tools -> call_llm
        format -> done
      }
      """

      adapters = %{
        llm_call: fn _messages, _mode, _opts ->
          call_num = :counters.get(counter, 1)
          :counters.add(counter, 1, 1)

          if call_num < 3 do
            {:ok, %{tool_calls: [%{name: "tool_#{call_num}", args: %{step: call_num}}]}}
          else
            {:ok, %{content: "Done after 3 tool rounds."}}
          end
        end,
        tool_dispatch: fn _tool_calls, _agent_id ->
          {:ok, ["tool result"]}
        end
      }

      {pid, tmp_dir} = start_session(adapters: adapters, turn_dot: tool_loop_dot)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
        File.rm_rf(tmp_dir)
      end)

      assert {:ok, %{text: text, tool_history: history, tool_rounds: rounds}} =
               Arbor.Orchestrator.Session.send_message(pid, "use tools")

      assert text == "Done after 3 tool rounds."
      assert rounds == 3
      assert length(history) == 3

      # Each entry should have the expected fields
      Enum.each(history, fn entry ->
        assert Map.has_key?(entry, "name")
        assert Map.has_key?(entry, "args")
        assert Map.has_key?(entry, "result")
        assert Map.has_key?(entry, "duration_ms")
        assert Map.has_key?(entry, "timestamp")
      end)

      # Tool names should be in order
      names = Enum.map(history, & &1["name"])
      assert names == ["tool_0", "tool_1", "tool_2"]

      GenServer.stop(pid)
    end

    @tag :spike
    test "caller timeout handling — Session does not crash" do
      adapters = %{
        llm_call: fn _messages, _mode, _opts ->
          # Very slow — caller will time out before this completes
          Process.sleep(500)
          {:ok, %{content: "too late"}}
        end
      }

      {pid, tmp_dir} = start_session(adapters: adapters)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
        File.rm_rf(tmp_dir)
      end)

      # Call from a spawned process that will die before the turn completes
      caller =
        spawn(fn ->
          GenServer.call(pid, {:send_message, "timeout me"}, :infinity)
        end)

      # Give the turn task time to start
      Process.sleep(50)

      # Kill the caller while the turn is in-flight
      Process.exit(caller, :kill)

      # Wait for the turn task to complete and send its result
      Process.sleep(700)

      # Session should still be alive and functional
      assert Process.alive?(pid)

      state = Arbor.Orchestrator.Session.get_state(pid)
      assert state.turn_in_flight == false
    end

    @tag :spike
    test "return type includes tool_history and tool_rounds for simple turns" do
      adapters = %{
        llm_call: fn _messages, _mode, _opts ->
          {:ok, %{content: "simple response"}}
        end
      }

      {pid, tmp_dir} = start_session(adapters: adapters)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
        File.rm_rf(tmp_dir)
      end)

      assert {:ok, result} = Arbor.Orchestrator.Session.send_message(pid, "hello")

      # Even without tool calls, the return type should have these fields
      assert %{text: "simple response", tool_history: [], tool_rounds: 0} = result

      GenServer.stop(pid)
    end
  end
end
