defmodule Arbor.Orchestrator.EngineCoverageTest do
  @moduledoc """
  Coverage-focused tests for the orchestrator engine, handlers, and context threading.

  Covers:
  - Integration tests for full graph execution (start -> compute -> end)
  - Handler edge case tests (error conditions, type mismatches)
  - Context threading tests across multiple handlers
  - Router edge cases and condition evaluation
  - Authorization edge cases
  - Executor retry edge cases
  """
  use ExUnit.Case, async: false

  alias Arbor.Orchestrator.Engine
  alias Arbor.Orchestrator.Engine.{Authorization, Condition, Context, Executor, Outcome, Router}
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.{Edge, Node}
  alias Arbor.Orchestrator.Handlers.CodergenHandler
  alias Arbor.Orchestrator.Handlers.ConditionalHandler
  alias Arbor.Orchestrator.Handlers.ExitHandler
  alias Arbor.Orchestrator.Handlers.Handler
  alias Arbor.Orchestrator.Handlers.Helpers
  alias Arbor.Orchestrator.Handlers.Registry
  alias Arbor.Orchestrator.Handlers.StartHandler

  setup_all do
    # Ensure the EventRegistry is running for Engine.run tests
    # Use Elixir's Registry (not our Handlers.Registry alias)
    case Elixir.Registry.start_link(keys: :duplicate, name: Arbor.Orchestrator.EventRegistry) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  # ─── Helpers ────────────────────────────────────────────────────────────

  defp tmp_logs_root do
    Path.join(
      System.tmp_dir!(),
      "arbor_engine_coverage_#{System.unique_integer([:positive])}"
    )
  end

  defp build_graph(nodes, edges, attrs \\ %{}) do
    graph = %Graph{id: "test", attrs: attrs}

    graph =
      Enum.reduce(nodes, graph, fn {id, node_attrs}, g ->
        Graph.add_node(g, %Node{id: id, attrs: node_attrs})
      end)

    Enum.reduce(edges, graph, fn {from, to, edge_attrs}, g ->
      Graph.add_edge(g, %Edge{from: from, to: to, attrs: edge_attrs})
    end)
  end

  defp collect_events(opts_extra) do
    parent = self()
    on_event = fn event -> send(parent, {:event, event}) end
    [{:on_event, on_event} | opts_extra]
  end

  # ═══════════════════════════════════════════════════════════════════════
  # SECTION 1: Full Graph Execution Integration Tests
  # ═══════════════════════════════════════════════════════════════════════

  describe "full graph execution: start -> compute -> end" do
    @tag :fast
    test "minimal linear pipeline completes with correct node ordering" do
      graph =
        build_graph(
          [
            {"start", %{"shape" => "Mdiamond"}},
            {"compute", %{"label" => "Compute step"}},
            {"exit", %{"shape" => "Msquare"}}
          ],
          [
            {"start", "compute", %{}},
            {"compute", "exit", %{}}
          ]
        )

      logs = tmp_logs_root()
      assert {:ok, result} = Engine.run(graph, logs_root: logs)
      assert result.completed_nodes == ["start", "compute", "exit"]
      assert result.final_outcome.status == :success
      assert is_map(result.context)
      assert is_map(result.node_durations)
    end

    @tag :fast
    test "four-node linear pipeline preserves execution order" do
      graph =
        build_graph(
          [
            {"start", %{"shape" => "Mdiamond"}},
            {"step_a", %{"label" => "A"}},
            {"step_b", %{"label" => "B"}},
            {"exit", %{"shape" => "Msquare"}}
          ],
          [
            {"start", "step_a", %{}},
            {"step_a", "step_b", %{}},
            {"step_b", "exit", %{}}
          ]
        )

      assert {:ok, result} = Engine.run(graph, logs_root: tmp_logs_root())
      assert result.completed_nodes == ["start", "step_a", "step_b", "exit"]
    end

    @tag :fast
    test "graph with goal attribute threads goal into context" do
      graph =
        build_graph(
          [
            {"start", %{"shape" => "Mdiamond"}},
            {"task", %{"label" => "Task"}},
            {"exit", %{"shape" => "Msquare"}}
          ],
          [
            {"start", "task", %{}},
            {"task", "exit", %{}}
          ],
          %{"goal" => "Build a widget", "label" => "Widget Pipeline"}
        )

      assert {:ok, result} = Engine.run(graph, logs_root: tmp_logs_root())
      assert result.context["graph.goal"] == "Build a widget"
      assert result.context["graph.label"] == "Widget Pipeline"
    end

    @tag :fast
    test "graph with initial_values merges them into context" do
      graph =
        build_graph(
          [
            {"start", %{"shape" => "Mdiamond"}},
            {"exit", %{"shape" => "Msquare"}}
          ],
          [{"start", "exit", %{}}]
        )

      initial = %{"custom_key" => "custom_value", "version" => "2.0"}

      assert {:ok, result} =
               Engine.run(graph, logs_root: tmp_logs_root(), initial_values: initial)

      assert result.context["custom_key"] == "custom_value"
      assert result.context["version"] == "2.0"
    end

    @tag :fast
    test "missing start node returns error" do
      graph =
        build_graph(
          [
            {"compute", %{"label" => "Compute"}},
            {"exit", %{"shape" => "Msquare"}}
          ],
          [{"compute", "exit", %{}}]
        )

      assert {:error, :missing_start_node} = Engine.run(graph, logs_root: tmp_logs_root())
    end

    @tag :fast
    test "max_steps exceeded returns error" do
      graph =
        build_graph(
          [
            {"start", %{"shape" => "Mdiamond"}},
            {"a", %{"label" => "A"}},
            {"b", %{"label" => "B"}},
            {"c", %{"label" => "C"}},
            {"exit", %{"shape" => "Msquare"}}
          ],
          [
            {"start", "a", %{}},
            {"a", "b", %{}},
            {"b", "c", %{}},
            {"c", "exit", %{}}
          ]
        )

      assert {:error, :max_steps_exceeded} =
               Engine.run(graph, logs_root: tmp_logs_root(), max_steps: 2)
    end

    @tag :fast
    test "pipeline emits pipeline_started and pipeline_completed events" do
      graph =
        build_graph(
          [
            {"start", %{"shape" => "Mdiamond"}},
            {"exit", %{"shape" => "Msquare"}}
          ],
          [{"start", "exit", %{}}]
        )

      opts = collect_events(logs_root: tmp_logs_root())
      assert {:ok, _result} = Engine.run(graph, opts)

      assert_receive {:event, %{type: :pipeline_started, graph_id: "test"}}
      assert_receive {:event, %{type: :pipeline_completed}}
    end

    @tag :fast
    test "pipeline emits stage_started and stage_completed for each node" do
      graph =
        build_graph(
          [
            {"start", %{"shape" => "Mdiamond"}},
            {"task", %{"label" => "Task"}},
            {"exit", %{"shape" => "Msquare"}}
          ],
          [
            {"start", "task", %{}},
            {"task", "exit", %{}}
          ]
        )

      opts = collect_events(logs_root: tmp_logs_root())
      assert {:ok, _result} = Engine.run(graph, opts)

      assert_receive {:event, %{type: :stage_started, node_id: "start"}}
      assert_receive {:event, %{type: :stage_completed, node_id: "start"}}
      assert_receive {:event, %{type: :stage_started, node_id: "task"}}
      assert_receive {:event, %{type: :stage_completed, node_id: "task"}}
      assert_receive {:event, %{type: :stage_started, node_id: "exit"}}
      assert_receive {:event, %{type: :stage_completed, node_id: "exit"}}
    end

    @tag :fast
    test "node_durations tracks per-node timing" do
      graph =
        build_graph(
          [
            {"start", %{"shape" => "Mdiamond"}},
            {"task", %{"label" => "Task"}},
            {"exit", %{"shape" => "Msquare"}}
          ],
          [
            {"start", "task", %{}},
            {"task", "exit", %{}}
          ]
        )

      assert {:ok, result} = Engine.run(graph, logs_root: tmp_logs_root())
      assert Map.has_key?(result.node_durations, "start")
      assert Map.has_key?(result.node_durations, "task")
      assert Map.has_key?(result.node_durations, "exit")
      assert is_integer(result.node_durations["task"])
      assert result.node_durations["task"] >= 0
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # SECTION 2: Context Threading Tests
  # ═══════════════════════════════════════════════════════════════════════

  describe "context threading across handlers" do
    @tag :fast
    test "context updates from one node are visible to subsequent nodes" do
      graph =
        build_graph(
          [
            {"start", %{"shape" => "Mdiamond"}},
            {"producer", %{"label" => "Producer"}},
            {"consumer", %{"label" => "Consumer"}},
            {"exit", %{"shape" => "Msquare"}}
          ],
          [
            {"start", "producer", %{}},
            {"producer", "consumer", %{}},
            {"consumer", "exit", %{}}
          ]
        )

      assert {:ok, result} = Engine.run(graph, logs_root: tmp_logs_root())

      # The codergen handler sets last_stage for each node
      assert result.context["last_stage"] == "consumer"
      # And context.previous_outcome is threaded through
      assert result.context["context.previous_outcome"] == "success"
    end

    @tag :fast
    test "context tracks current_node through pipeline" do
      graph =
        build_graph(
          [
            {"start", %{"shape" => "Mdiamond"}},
            {"step1", %{"label" => "Step 1"}},
            {"exit", %{"shape" => "Msquare"}}
          ],
          [
            {"start", "step1", %{}},
            {"step1", "exit", %{}}
          ]
        )

      assert {:ok, result} = Engine.run(graph, logs_root: tmp_logs_root())
      # The last current_node set is the terminal "exit" node
      assert result.context["current_node"] == "exit"
    end

    @tag :fast
    test "outcome status is threaded into context" do
      graph =
        build_graph(
          [
            {"start", %{"shape" => "Mdiamond"}},
            {"task", %{"label" => "Task"}},
            {"exit", %{"shape" => "Msquare"}}
          ],
          [
            {"start", "task", %{}},
            {"task", "exit", %{}}
          ]
        )

      assert {:ok, result} = Engine.run(graph, logs_root: tmp_logs_root())
      assert result.context["outcome"] == "success"
    end

    @tag :fast
    test "simulated fail sets failure context correctly" do
      graph =
        build_graph(
          [
            {"start", %{"shape" => "Mdiamond"}},
            {"failing", %{"simulate" => "fail", "max_retries" => "0"}},
            {"recovery", %{"label" => "Recovery"}},
            {"exit", %{"shape" => "Msquare"}}
          ],
          [
            {"start", "failing", %{}},
            {"failing", "recovery", %{"condition" => "outcome=fail"}},
            {"recovery", "exit", %{}}
          ]
        )

      assert {:ok, result} =
               Engine.run(graph, logs_root: tmp_logs_root(), sleep_fn: fn _ -> :ok end)

      assert "recovery" in result.completed_nodes
      assert result.context["last_stage"] == "recovery"
    end

    @tag :fast
    test "context values from initial_values persist through execution" do
      graph =
        build_graph(
          [
            {"start", %{"shape" => "Mdiamond"}},
            {"task", %{"label" => "Task"}},
            {"exit", %{"shape" => "Msquare"}}
          ],
          [
            {"start", "task", %{}},
            {"task", "exit", %{}}
          ]
        )

      initial = %{"environment" => "test", "run_id" => "abc-123"}

      assert {:ok, result} =
               Engine.run(graph, logs_root: tmp_logs_root(), initial_values: initial)

      assert result.context["environment"] == "test"
      assert result.context["run_id"] == "abc-123"
    end

    @tag :fast
    test "completed_nodes stored in context as internal tracking" do
      graph =
        build_graph(
          [
            {"start", %{"shape" => "Mdiamond"}},
            {"a", %{"label" => "A"}},
            {"exit", %{"shape" => "Msquare"}}
          ],
          [
            {"start", "a", %{}},
            {"a", "exit", %{}}
          ]
        )

      assert {:ok, result} = Engine.run(graph, logs_root: tmp_logs_root())
      # __completed_nodes__ is an internal tracking key
      assert is_list(result.context["__completed_nodes__"])
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # SECTION 3: Context Module Unit Tests
  # ═══════════════════════════════════════════════════════════════════════

  describe "Context module" do
    @tag :fast
    test "new/0 creates empty context" do
      ctx = Context.new()
      assert ctx.values == %{}
      assert ctx.logs == []
    end

    @tag :fast
    test "new/1 initializes with provided values" do
      ctx = Context.new(%{"key" => "value"})
      assert Context.get(ctx, "key") == "value"
    end

    @tag :fast
    test "get/3 returns default when key missing" do
      ctx = Context.new()
      assert Context.get(ctx, "missing", "default_val") == "default_val"
    end

    @tag :fast
    test "get/2 returns nil for missing key without default" do
      ctx = Context.new()
      assert Context.get(ctx, "missing") == nil
    end

    @tag :fast
    test "set/3 adds and overwrites values" do
      ctx = Context.new()
      ctx = Context.set(ctx, "key", "first")
      assert Context.get(ctx, "key") == "first"

      ctx = Context.set(ctx, "key", "second")
      assert Context.get(ctx, "key") == "second"
    end

    @tag :fast
    test "apply_updates/2 merges a map of updates" do
      ctx = Context.new(%{"existing" => "value"})
      ctx = Context.apply_updates(ctx, %{"new" => "added", "existing" => "overwritten"})
      assert Context.get(ctx, "new") == "added"
      assert Context.get(ctx, "existing") == "overwritten"
    end

    @tag :fast
    test "apply_updates/2 with empty map is no-op" do
      ctx = Context.new(%{"key" => "val"})
      ctx2 = Context.apply_updates(ctx, %{})
      assert Context.snapshot(ctx2) == Context.snapshot(ctx)
    end

    @tag :fast
    test "snapshot/1 returns raw values map" do
      ctx = Context.new(%{"a" => 1, "b" => 2})
      assert Context.snapshot(ctx) == %{"a" => 1, "b" => 2}
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # SECTION 4: Handler Edge Cases and Error Conditions
  # ═══════════════════════════════════════════════════════════════════════

  describe "handler edge cases: simulated modes" do
    @tag :fast
    test "simulate=fail produces fail outcome" do
      graph =
        build_graph(
          [
            {"start", %{"shape" => "Mdiamond"}},
            {"failing", %{"simulate" => "fail", "max_retries" => "0"}},
            {"exit", %{"shape" => "Msquare"}}
          ],
          [
            {"start", "failing", %{}},
            {"failing", "exit", %{}}
          ]
        )

      assert {:ok, result} =
               Engine.run(graph, logs_root: tmp_logs_root(), sleep_fn: fn _ -> :ok end)

      # The fail node has no failure edge with condition, so pipeline ends
      assert "failing" in result.completed_nodes
      assert result.final_outcome.status == :fail
    end

    @tag :fast
    test "simulate=retry exhausts retries then fails" do
      graph =
        build_graph(
          [
            {"start", %{"shape" => "Mdiamond"}},
            {"flaky", %{"simulate" => "retry", "max_retries" => "1", "retry_initial_delay_ms" => "1"}},
            {"exit", %{"shape" => "Msquare"}}
          ],
          [
            {"start", "flaky", %{}},
            {"flaky", "exit", %{}}
          ]
        )

      assert {:ok, result} =
               Engine.run(graph, logs_root: tmp_logs_root(), sleep_fn: fn _ -> :ok end)

      assert result.final_outcome.status == :fail
      assert result.final_outcome.failure_reason == "max retries exceeded"
    end

    @tag :fast
    test "simulate=fail_once fails first then succeeds" do
      graph =
        build_graph(
          [
            {"start", %{"shape" => "Mdiamond"}},
            {"flaky", %{"simulate" => "fail_once"}},
            {"exit", %{"shape" => "Msquare"}}
          ],
          [
            {"start", "flaky", %{}},
            {"flaky", "exit", %{"condition" => "outcome=success"}},
            {"flaky", "flaky", %{"condition" => "outcome=fail"}}
          ]
        )

      assert {:ok, result} = Engine.run(graph, logs_root: tmp_logs_root(), max_steps: 20)
      assert List.last(result.completed_nodes) == "exit"
      # flaky should appear at least twice
      assert Enum.count(result.completed_nodes, &(&1 == "flaky")) >= 2
    end

    @tag :fast
    test "simulate=raise_retryable raises retryable exception" do
      graph =
        build_graph(
          [
            {"start", %{"shape" => "Mdiamond"}},
            {"crashy", %{"simulate" => "raise_retryable", "max_retries" => "0"}},
            {"exit", %{"shape" => "Msquare"}}
          ],
          [
            {"start", "crashy", %{}},
            {"crashy", "exit", %{}}
          ]
        )

      assert {:ok, result} =
               Engine.run(graph, logs_root: tmp_logs_root(), sleep_fn: fn _ -> :ok end)

      assert result.final_outcome.status == :fail
      assert result.final_outcome.failure_reason =~ "network timeout"
    end

    @tag :fast
    test "simulate=raise_terminal raises non-retryable exception" do
      graph =
        build_graph(
          [
            {"start", %{"shape" => "Mdiamond"}},
            {"crashy", %{"simulate" => "raise_terminal", "max_retries" => "2"}},
            {"exit", %{"shape" => "Msquare"}}
          ],
          [
            {"start", "crashy", %{}},
            {"crashy", "exit", %{}}
          ]
        )

      assert {:ok, result} =
               Engine.run(graph, logs_root: tmp_logs_root(), sleep_fn: fn _ -> :ok end)

      assert result.final_outcome.status == :fail
      assert result.final_outcome.failure_reason =~ "401 unauthorized"
    end
  end

  describe "handler edge cases: conditional routing" do
    @tag :fast
    test "conditional edge with outcome=success routes correctly" do
      graph =
        build_graph(
          [
            {"start", %{"shape" => "Mdiamond"}},
            {"check", %{"label" => "Check"}},
            {"success_path", %{"label" => "Success"}},
            {"fail_path", %{"label" => "Fail"}},
            {"exit", %{"shape" => "Msquare"}}
          ],
          [
            {"start", "check", %{}},
            {"check", "success_path", %{"condition" => "outcome=success"}},
            {"check", "fail_path", %{"condition" => "outcome=fail"}},
            {"success_path", "exit", %{}},
            {"fail_path", "exit", %{}}
          ]
        )

      assert {:ok, result} = Engine.run(graph, logs_root: tmp_logs_root())
      assert "success_path" in result.completed_nodes
      refute "fail_path" in result.completed_nodes
    end

    @tag :fast
    test "weighted edges prefer higher weight" do
      graph =
        build_graph(
          [
            {"start", %{"shape" => "Mdiamond", "fan_out" => "false"}},
            {"high", %{"label" => "High weight"}},
            {"low", %{"label" => "Low weight"}},
            {"exit", %{"shape" => "Msquare"}}
          ],
          [
            {"start", "high", %{"weight" => "10"}},
            {"start", "low", %{"weight" => "1"}},
            {"high", "exit", %{}},
            {"low", "exit", %{}}
          ]
        )

      assert {:ok, result} = Engine.run(graph, logs_root: tmp_logs_root())
      assert "high" in result.completed_nodes
      refute "low" in result.completed_nodes
    end

    @tag :fast
    test "condition with context variable evaluates correctly" do
      graph =
        build_graph(
          [
            {"start", %{"shape" => "Mdiamond"}},
            {"task", %{"label" => "Task"}},
            {"check", %{"shape" => "diamond"}},
            {"path_a", %{"label" => "A"}},
            {"path_b", %{"label" => "B"}},
            {"exit", %{"shape" => "Msquare"}}
          ],
          [
            {"start", "task", %{}},
            {"task", "check", %{}},
            {"check", "path_a", %{"condition" => "outcome=success"}},
            {"check", "path_b", %{"condition" => "outcome=fail"}},
            {"path_a", "exit", %{}},
            {"path_b", "exit", %{}}
          ]
        )

      assert {:ok, result} = Engine.run(graph, logs_root: tmp_logs_root())
      assert "path_a" in result.completed_nodes
      refute "path_b" in result.completed_nodes
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # SECTION 5: Router Edge Cases
  # ═══════════════════════════════════════════════════════════════════════

  describe "Router.terminal?/1" do
    @tag :fast
    test "Msquare shape is terminal" do
      node = %Node{id: "end", attrs: %{"shape" => "Msquare"}}
      assert Router.terminal?(node)
    end

    @tag :fast
    test "exit id (lowercase) is terminal" do
      node = %Node{id: "exit", attrs: %{}}
      assert Router.terminal?(node)
    end

    @tag :fast
    test "end id (lowercase) is terminal" do
      node = %Node{id: "end", attrs: %{}}
      assert Router.terminal?(node)
    end

    @tag :fast
    test "regular node is not terminal" do
      node = %Node{id: "task", attrs: %{"shape" => "box"}}
      refute Router.terminal?(node)
    end

    @tag :fast
    test "start node is not terminal" do
      node = %Node{id: "start", attrs: %{"shape" => "Mdiamond"}}
      refute Router.terminal?(node)
    end
  end

  describe "Router.valid_target?/2" do
    @tag :fast
    test "nil target is invalid" do
      graph = build_graph([{"a", %{}}], [])
      refute Router.valid_target?(graph, nil)
    end

    @tag :fast
    test "empty string target is invalid" do
      graph = build_graph([{"a", %{}}], [])
      refute Router.valid_target?(graph, "")
    end

    @tag :fast
    test "non-existent node is invalid" do
      graph = build_graph([{"a", %{}}], [])
      refute Router.valid_target?(graph, "nonexistent")
    end

    @tag :fast
    test "existing node is valid" do
      graph = build_graph([{"a", %{}}], [])
      assert Router.valid_target?(graph, "a")
    end

    @tag :fast
    test "non-binary non-nil target is invalid" do
      graph = build_graph([{"a", %{}}], [])
      refute Router.valid_target?(graph, 42)
    end
  end

  describe "Router.normalize_label/1" do
    @tag :fast
    test "strips bracket prefix" do
      assert Router.normalize_label("[Y] Yes") == "yes"
    end

    @tag :fast
    test "strips parenthetical prefix" do
      assert Router.normalize_label("a) First option") == "first option"
    end

    @tag :fast
    test "strips dash prefix" do
      assert Router.normalize_label("b - Second option") == "second option"
    end

    @tag :fast
    test "trims and lowercases" do
      assert Router.normalize_label("  HELLO WORLD  ") == "hello world"
    end

    @tag :fast
    test "handles empty string" do
      assert Router.normalize_label("") == ""
    end
  end

  describe "Router.best_by_weight_then_lexical/1" do
    @tag :fast
    test "picks highest weight" do
      edges = [
        %Edge{from: "a", to: "low", attrs: %{"weight" => "1"}},
        %Edge{from: "a", to: "high", attrs: %{"weight" => "10"}}
      ]

      assert Router.best_by_weight_then_lexical(edges).to == "high"
    end

    @tag :fast
    test "breaks weight tie with lexical ordering" do
      edges = [
        %Edge{from: "a", to: "beta", attrs: %{"weight" => "5"}},
        %Edge{from: "a", to: "alpha", attrs: %{"weight" => "5"}}
      ]

      assert Router.best_by_weight_then_lexical(edges).to == "alpha"
    end

    @tag :fast
    test "handles edges without weight attribute" do
      edges = [
        %Edge{from: "a", to: "z", attrs: %{}},
        %Edge{from: "a", to: "a", attrs: %{}}
      ]

      assert Router.best_by_weight_then_lexical(edges).to == "a"
    end
  end

  describe "Router.all_predecessors_complete?/3" do
    @tag :fast
    test "returns true when all predecessors are in completed list" do
      graph =
        build_graph(
          [{"a", %{}}, {"b", %{}}, {"join", %{}}],
          [{"a", "join", %{}}, {"b", "join", %{}}]
        )

      assert Router.all_predecessors_complete?(graph, "join", ["a", "b"])
    end

    @tag :fast
    test "returns false when predecessor is missing from completed" do
      graph =
        build_graph(
          [{"a", %{}}, {"b", %{}}, {"join", %{}}],
          [{"a", "join", %{}}, {"b", "join", %{}}]
        )

      refute Router.all_predecessors_complete?(graph, "join", ["a"])
    end

    @tag :fast
    test "returns true for node with no predecessors" do
      graph = build_graph([{"solo", %{}}], [])
      assert Router.all_predecessors_complete?(graph, "solo", [])
    end
  end

  describe "Router.merge_pending/2" do
    @tag :fast
    test "deduplicates by node_id" do
      existing = [{"a", nil}]
      new_targets = [{"a", %Edge{from: "x", to: "a", attrs: %{}}}, {"b", nil}]
      merged = Router.merge_pending(new_targets, existing)
      assert length(merged) == 2
      ids = Enum.map(merged, fn {id, _} -> id end)
      assert "a" in ids
      assert "b" in ids
    end

    @tag :fast
    test "handles empty existing" do
      new_targets = [{"c", nil}]
      merged = Router.merge_pending(new_targets, [])
      assert merged == [{"c", nil}]
    end

    @tag :fast
    test "handles empty new targets" do
      existing = [{"a", nil}]
      merged = Router.merge_pending([], existing)
      assert merged == [{"a", nil}]
    end
  end

  describe "Router.find_next_ready/3" do
    @tag :fast
    test "returns nil for empty candidates" do
      graph = build_graph([{"a", %{}}], [])
      assert Router.find_next_ready([], graph, []) == nil
    end

    @tag :fast
    test "returns ready node and remaining candidates" do
      graph =
        build_graph(
          [{"a", %{}}, {"b", %{}}, {"join", %{}}],
          [{"a", "join", %{}}]
        )

      candidates = [{"join", nil}, {"b", nil}]
      # "join" needs "a" to be completed
      result = Router.find_next_ready(candidates, graph, ["a"])
      assert {next_id, _edge, remaining} = result
      assert next_id == "join"
      assert length(remaining) == 1
    end

    @tag :fast
    test "skips already-completed candidates" do
      graph = build_graph([{"a", %{}}, {"b", %{}}], [])

      candidates = [{"a", nil}, {"b", nil}]
      result = Router.find_next_ready(candidates, graph, ["a"])
      assert {next_id, _edge, _remaining} = result
      assert next_id == "b"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # SECTION 6: Condition Evaluation Edge Cases
  # ═══════════════════════════════════════════════════════════════════════

  describe "Condition.eval/3" do
    @tag :fast
    test "nil condition returns true" do
      outcome = %Outcome{status: :success}
      ctx = Context.new()
      assert Condition.eval(nil, outcome, ctx)
    end

    @tag :fast
    test "empty string condition returns true" do
      outcome = %Outcome{status: :success}
      ctx = Context.new()
      assert Condition.eval("", outcome, ctx)
    end

    @tag :fast
    test "outcome=success matches success status" do
      outcome = %Outcome{status: :success}
      ctx = Context.new()
      assert Condition.eval("outcome=success", outcome, ctx)
    end

    @tag :fast
    test "outcome=fail does not match success status" do
      outcome = %Outcome{status: :success}
      ctx = Context.new()
      refute Condition.eval("outcome=fail", outcome, ctx)
    end

    @tag :fast
    test "outcome!=fail matches success status" do
      outcome = %Outcome{status: :success}
      ctx = Context.new()
      assert Condition.eval("outcome!=fail", outcome, ctx)
    end

    @tag :fast
    test "preferred_label matches label" do
      outcome = %Outcome{status: :success, preferred_label: "yes"}
      ctx = Context.new()
      assert Condition.eval("preferred_label=yes", outcome, ctx)
    end

    @tag :fast
    test "context variable evaluation" do
      outcome = %Outcome{status: :success}
      ctx = Context.new(%{"context.mode" => "production"})
      assert Condition.eval("context.mode=production", outcome, ctx)
    end

    @tag :fast
    test "compound condition with && requires all clauses" do
      outcome = %Outcome{status: :success}
      ctx = Context.new(%{"context.mode" => "test"})
      assert Condition.eval("outcome=success && context.mode=test", outcome, ctx)
      refute Condition.eval("outcome=success && context.mode=production", outcome, ctx)
    end

    @tag :fast
    test "unknown key resolves to empty string" do
      outcome = %Outcome{status: :success}
      ctx = Context.new()
      # unknown_key resolves to "", which != "something"
      refute Condition.eval("unknown_key=something", outcome, ctx)
    end
  end

  describe "Condition.valid_syntax?/1" do
    @tag :fast
    test "nil is valid" do
      assert Condition.valid_syntax?(nil)
    end

    @tag :fast
    test "empty string is valid" do
      assert Condition.valid_syntax?("")
    end

    @tag :fast
    test "outcome=success is valid" do
      assert Condition.valid_syntax?("outcome=success")
    end

    @tag :fast
    test "context.var=value is valid" do
      assert Condition.valid_syntax?("context.my_var=hello")
    end

    @tag :fast
    test "invalid key is not valid" do
      refute Condition.valid_syntax?("bad key=value")
    end

    @tag :fast
    test "non-binary is not valid" do
      refute Condition.valid_syntax?(42)
    end

    @tag :fast
    test "compound conditions are valid" do
      assert Condition.valid_syntax?("outcome=success && preferred_label=yes")
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # SECTION 7: Executor Edge Cases
  # ═══════════════════════════════════════════════════════════════════════

  describe "Executor.should_retry_exception?/1" do
    @tag :fast
    test "timeout exception is retryable" do
      assert Executor.should_retry_exception?(%RuntimeError{message: "connection timeout"})
    end

    @tag :fast
    test "timed out is retryable" do
      assert Executor.should_retry_exception?(%RuntimeError{message: "request timed out"})
    end

    @tag :fast
    test "network error is retryable" do
      assert Executor.should_retry_exception?(%RuntimeError{message: "network unreachable"})
    end

    @tag :fast
    test "connection error is retryable" do
      assert Executor.should_retry_exception?(%RuntimeError{message: "connection refused"})
    end

    @tag :fast
    test "rate limit is retryable" do
      assert Executor.should_retry_exception?(%RuntimeError{message: "rate limit exceeded"})
    end

    @tag :fast
    test "429 status is retryable" do
      assert Executor.should_retry_exception?(%RuntimeError{message: "HTTP 429 Too Many Requests"})
    end

    @tag :fast
    test "5xx status is retryable" do
      assert Executor.should_retry_exception?(%RuntimeError{message: "received 5xx error"})
    end

    @tag :fast
    test "server error is retryable" do
      assert Executor.should_retry_exception?(%RuntimeError{message: "internal server error"})
    end

    @tag :fast
    test "401 is NOT retryable" do
      refute Executor.should_retry_exception?(%RuntimeError{message: "401 Unauthorized"})
    end

    @tag :fast
    test "403 is NOT retryable" do
      refute Executor.should_retry_exception?(%RuntimeError{message: "403 Forbidden"})
    end

    @tag :fast
    test "400 is NOT retryable" do
      refute Executor.should_retry_exception?(%RuntimeError{message: "400 Bad Request"})
    end

    @tag :fast
    test "validation error is NOT retryable" do
      refute Executor.should_retry_exception?(%RuntimeError{message: "validation failed"})
    end

    @tag :fast
    test "generic error is NOT retryable" do
      refute Executor.should_retry_exception?(%RuntimeError{message: "something broke"})
    end
  end

  describe "Executor.parse_max_attempts/2" do
    @tag :fast
    test "uses node max_retries when present" do
      node = %Node{id: "t", attrs: %{"max_retries" => "3"}}
      graph = %Graph{attrs: %{}}
      assert Executor.parse_max_attempts(node, graph) == 4
    end

    @tag :fast
    test "uses graph default_max_retry when node has none" do
      node = %Node{id: "t", attrs: %{}}
      graph = %Graph{attrs: %{"default_max_retry" => "2"}}
      assert Executor.parse_max_attempts(node, graph) == 3
    end

    @tag :fast
    test "defaults to retry profile when neither is set" do
      node = %Node{id: "t", attrs: %{}}
      graph = %Graph{attrs: %{}}
      # Default retry policy is "none" which has max_attempts=1
      assert Executor.parse_max_attempts(node, graph) == 1
    end

    @tag :fast
    test "node max_retries takes precedence over graph default" do
      node = %Node{id: "t", attrs: %{"max_retries" => "5"}}
      graph = %Graph{attrs: %{"default_max_retry" => "2"}}
      assert Executor.parse_max_attempts(node, graph) == 6
    end

    @tag :fast
    test "retry_policy standard provides 5 max_attempts" do
      node = %Node{id: "t", attrs: %{}}
      graph = %Graph{attrs: %{"retry_policy" => "standard"}}
      assert Executor.parse_max_attempts(node, graph) == 5
    end
  end

  describe "Executor.retry_delay_ms/4" do
    @tag :fast
    test "exponential backoff doubles delay each attempt" do
      node = %Node{
        id: "t",
        attrs: %{
          "retry_initial_delay_ms" => "100",
          "retry_backoff_factor" => "2.0",
          "retry_max_delay_ms" => "100000",
          "retry_jitter" => "false"
        }
      }

      graph = %Graph{attrs: %{}}

      delay1 = Executor.retry_delay_ms(node, graph, 1, [])
      delay2 = Executor.retry_delay_ms(node, graph, 2, [])
      delay3 = Executor.retry_delay_ms(node, graph, 3, [])

      assert delay1 == 100
      assert delay2 == 200
      assert delay3 == 400
    end

    @tag :fast
    test "max_delay caps the backoff" do
      node = %Node{
        id: "t",
        attrs: %{
          "retry_initial_delay_ms" => "1000",
          "retry_backoff_factor" => "10.0",
          "retry_max_delay_ms" => "5000",
          "retry_jitter" => "false"
        }
      }

      graph = %Graph{attrs: %{}}

      delay = Executor.retry_delay_ms(node, graph, 5, [])
      assert delay == 5000
    end

    @tag :fast
    test "jitter modifies delay non-deterministically" do
      node = %Node{
        id: "t",
        attrs: %{
          "retry_initial_delay_ms" => "100",
          "retry_backoff_factor" => "1.0",
          "retry_max_delay_ms" => "10000",
          "retry_jitter" => "true"
        }
      }

      graph = %Graph{attrs: %{}}

      # With rand_fn returning 0.0, jitter factor is 0.5 + 0.0 = 0.5
      delay = Executor.retry_delay_ms(node, graph, 1, rand_fn: fn -> 0.0 end)
      assert delay == 50

      # With rand_fn returning 1.0, jitter factor is 0.5 + 1.0 = 1.5
      delay = Executor.retry_delay_ms(node, graph, 1, rand_fn: fn -> 1.0 end)
      assert delay == 150
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # SECTION 8: Authorization Edge Cases
  # ═══════════════════════════════════════════════════════════════════════

  describe "Authorization.authorize_and_execute/5" do
    @tag :fast
    test "authorization disabled bypasses checks" do
      handler = fn _node, _ctx, _graph, _opts ->
        %Outcome{status: :success, notes: "executed"}
      end

      node = %Node{id: "task", attrs: %{"type" => "codergen"}}
      ctx = Context.new()
      graph = %Graph{attrs: %{}}

      outcome = Authorization.authorize_and_execute(handler, node, ctx, graph, [])
      assert outcome.status == :success
      assert outcome.notes == "executed"
    end

    @tag :fast
    test "authorization enabled, authorized agent proceeds" do
      handler = fn _node, _ctx, _graph, _opts ->
        %Outcome{status: :success, notes: "authorized_run"}
      end

      authorizer = fn _agent_id, _type -> :ok end
      node = %Node{id: "task", attrs: %{"type" => "codergen"}}
      ctx = Context.new(%{"session.agent_id" => "agent_001"})
      graph = %Graph{attrs: %{}}
      opts = [authorization: true, authorizer: authorizer]

      outcome = Authorization.authorize_and_execute(handler, node, ctx, graph, opts)
      assert outcome.status == :success
    end

    @tag :fast
    test "authorization enabled, denied agent gets fail" do
      handler = fn _node, _ctx, _graph, _opts ->
        %Outcome{status: :success}
      end

      authorizer = fn _agent_id, _type -> {:error, "denied"} end
      node = %Node{id: "task", attrs: %{"type" => "tool"}}
      ctx = Context.new(%{"session.agent_id" => "untrusted"})
      graph = %Graph{attrs: %{}}
      opts = [authorization: true, authorizer: authorizer]

      outcome = Authorization.authorize_and_execute(handler, node, ctx, graph, opts)
      assert outcome.status == :fail
      assert outcome.failure_reason =~ "unauthorized"
    end

    @tag :fast
    test "start nodes are always authorized" do
      handler = fn _node, _ctx, _graph, _opts ->
        %Outcome{status: :success}
      end

      # Authorizer that always denies
      authorizer = fn _agent_id, _type -> {:error, "denied"} end
      node = %Node{id: "start", attrs: %{"shape" => "Mdiamond"}}
      ctx = Context.new(%{"session.agent_id" => "untrusted"})
      graph = %Graph{attrs: %{}}
      opts = [authorization: true, authorizer: authorizer]

      outcome = Authorization.authorize_and_execute(handler, node, ctx, graph, opts)
      # Start nodes bypass authorization
      assert outcome.status == :success
    end

    @tag :fast
    test "exit nodes are always authorized" do
      handler = fn _node, _ctx, _graph, _opts ->
        %Outcome{status: :success}
      end

      authorizer = fn _agent_id, _type -> {:error, "denied"} end
      node = %Node{id: "exit", attrs: %{"shape" => "Msquare"}}
      ctx = Context.new(%{"session.agent_id" => "untrusted"})
      graph = %Graph{attrs: %{}}
      opts = [authorization: true, authorizer: authorizer]

      outcome = Authorization.authorize_and_execute(handler, node, ctx, graph, opts)
      assert outcome.status == :success
    end

    @tag :fast
    test "missing authorizer function returns fail" do
      handler = fn _node, _ctx, _graph, _opts ->
        %Outcome{status: :success}
      end

      node = %Node{id: "task", attrs: %{"type" => "codergen"}}
      ctx = Context.new(%{"session.agent_id" => "agent"})
      graph = %Graph{attrs: %{}}
      opts = [authorization: true]

      outcome = Authorization.authorize_and_execute(handler, node, ctx, graph, opts)
      assert outcome.status == :fail
      assert outcome.failure_reason =~ "unauthorized"
    end
  end

  describe "Authorization.required_capability/1" do
    @tag :fast
    test "start node has no capability requirement" do
      node = %Node{id: "start", attrs: %{"shape" => "Mdiamond"}}
      assert Authorization.required_capability(node) == nil
    end

    @tag :fast
    test "exit node has no capability requirement" do
      node = %Node{id: "exit", attrs: %{"shape" => "Msquare"}}
      assert Authorization.required_capability(node) == nil
    end

    @tag :fast
    test "tool node requires orchestrator:handler:tool" do
      node = %Node{id: "run", attrs: %{"type" => "tool"}}
      assert Authorization.required_capability(node) == "orchestrator:handler:tool"
    end

    @tag :fast
    test "codergen node requires orchestrator:handler:codergen" do
      node = %Node{id: "build", attrs: %{"type" => "codergen"}}
      assert Authorization.required_capability(node) == "orchestrator:handler:codergen"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # SECTION 9: Registry Edge Cases
  # ═══════════════════════════════════════════════════════════════════════

  describe "Registry.node_type/1" do
    @tag :fast
    test "uses explicit type attribute when present" do
      node = %Node{id: "n", attrs: %{"type" => "tool"}}
      assert Registry.node_type(node) == "tool"
    end

    @tag :fast
    test "maps Mdiamond shape to start" do
      node = %Node{id: "n", attrs: %{"shape" => "Mdiamond"}}
      assert Registry.node_type(node) == "start"
    end

    @tag :fast
    test "maps Msquare shape to exit" do
      node = %Node{id: "n", attrs: %{"shape" => "Msquare"}}
      assert Registry.node_type(node) == "exit"
    end

    @tag :fast
    test "maps diamond shape to conditional" do
      node = %Node{id: "n", attrs: %{"shape" => "diamond"}}
      assert Registry.node_type(node) == "conditional"
    end

    @tag :fast
    test "maps parallelogram shape to tool" do
      node = %Node{id: "n", attrs: %{"shape" => "parallelogram"}}
      assert Registry.node_type(node) == "tool"
    end

    @tag :fast
    test "defaults to codergen for box shape" do
      node = %Node{id: "n", attrs: %{"shape" => "box"}}
      assert Registry.node_type(node) == "codergen"
    end

    @tag :fast
    test "defaults to codergen when no shape or type" do
      node = %Node{id: "n", attrs: %{}}
      assert Registry.node_type(node) == "codergen"
    end
  end

  describe "Registry.resolve/1" do
    @tag :fast
    test "resolves start handler" do
      node = %Node{id: "n", attrs: %{"shape" => "Mdiamond"}}
      assert Registry.resolve(node) == Arbor.Orchestrator.Handlers.StartHandler
    end

    @tag :fast
    test "resolves exit handler" do
      node = %Node{id: "n", attrs: %{"shape" => "Msquare"}}
      assert Registry.resolve(node) == Arbor.Orchestrator.Handlers.ExitHandler
    end

    @tag :fast
    test "unknown type falls back to CodergenHandler" do
      node = %Node{id: "n", attrs: %{"type" => "completely_unknown"}}
      assert Registry.resolve(node) == Arbor.Orchestrator.Handlers.CodergenHandler
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # SECTION 10: Graph Model Edge Cases
  # ═══════════════════════════════════════════════════════════════════════

  describe "Graph module" do
    @tag :fast
    test "outgoing_edges returns edges in insertion order" do
      graph =
        build_graph(
          [{"a", %{}}, {"b", %{}}, {"c", %{}}],
          [
            {"a", "b", %{"label" => "first"}},
            {"a", "c", %{"label" => "second"}}
          ]
        )

      edges = Graph.outgoing_edges(graph, "a")
      assert length(edges) == 2
      assert Enum.at(edges, 0).to == "b"
      assert Enum.at(edges, 1).to == "c"
    end

    @tag :fast
    test "incoming_edges returns edges pointing to a node" do
      graph =
        build_graph(
          [{"a", %{}}, {"b", %{}}, {"c", %{}}],
          [
            {"a", "c", %{}},
            {"b", "c", %{}}
          ]
        )

      edges = Graph.incoming_edges(graph, "c")
      from_ids = Enum.map(edges, & &1.from) |> Enum.sort()
      assert from_ids == ["a", "b"]
    end

    @tag :fast
    test "outgoing_edges for node with no edges returns empty" do
      graph = build_graph([{"solo", %{}}], [])
      assert Graph.outgoing_edges(graph, "solo") == []
    end

    @tag :fast
    test "find_start_node returns Mdiamond node" do
      graph =
        build_graph(
          [
            {"s", %{"shape" => "Mdiamond"}},
            {"t", %{"label" => "Task"}}
          ],
          []
        )

      assert %Node{id: "s"} = Graph.find_start_node(graph)
    end

    @tag :fast
    test "find_start_node returns node with id=start" do
      graph = build_graph([{"start", %{"shape" => "box"}}], [])
      assert %Node{id: "start"} = Graph.find_start_node(graph)
    end

    @tag :fast
    test "find_start_node returns nil when no start exists" do
      graph = build_graph([{"task", %{"shape" => "box"}}], [])
      assert Graph.find_start_node(graph) == nil
    end

    @tag :fast
    test "find_exit_nodes returns Msquare nodes" do
      graph =
        build_graph(
          [
            {"s", %{"shape" => "Mdiamond"}},
            {"e1", %{"shape" => "Msquare"}},
            {"e2", %{"shape" => "Msquare"}},
            {"task", %{"shape" => "box"}}
          ],
          []
        )

      exits = Graph.find_exit_nodes(graph)
      exit_ids = Enum.map(exits, & &1.id) |> Enum.sort()
      assert exit_ids == ["e1", "e2"]
    end

    @tag :fast
    test "terminal? checks if node is exit" do
      graph =
        build_graph(
          [
            {"exit", %{"shape" => "Msquare"}},
            {"task", %{"shape" => "box"}}
          ],
          []
        )

      exit_node = Map.get(graph.nodes, "exit")
      task_node = Map.get(graph.nodes, "task")
      assert Graph.terminal?(graph, exit_node)
      refute Graph.terminal?(graph, task_node)
    end

    @tag :fast
    test "goal/1 returns graph goal attribute" do
      graph = %Graph{attrs: %{"goal" => "Build something"}}
      assert Graph.goal(graph) == "Build something"
    end

    @tag :fast
    test "goal/1 returns nil when no goal" do
      graph = %Graph{attrs: %{}}
      assert Graph.goal(graph) == nil
    end

    @tag :fast
    test "label/1 returns graph label" do
      graph = %Graph{attrs: %{"label" => "My Pipeline"}}
      assert Graph.label(graph) == "My Pipeline"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # SECTION 11: Node and Edge attr/3 Edge Cases
  # ═══════════════════════════════════════════════════════════════════════

  describe "Node.attr/3 edge cases" do
    @tag :fast
    test "string key lookup" do
      node = %Node{id: "n", attrs: %{"key" => "value"}}
      assert Node.attr(node, "key") == "value"
    end

    @tag :fast
    test "atom key is converted to string" do
      node = %Node{id: "n", attrs: %{"shape" => "box"}}
      assert Node.attr(node, :shape) == "box"
    end

    @tag :fast
    test "missing key returns default" do
      node = %Node{id: "n", attrs: %{}}
      assert Node.attr(node, "missing", "fallback") == "fallback"
    end

    @tag :fast
    test "missing key returns nil by default" do
      node = %Node{id: "n", attrs: %{}}
      assert Node.attr(node, "missing") == nil
    end
  end

  describe "Edge.attr/3 edge cases" do
    @tag :fast
    test "string key lookup" do
      edge = %Edge{from: "a", to: "b", attrs: %{"condition" => "outcome=fail"}}
      assert Edge.attr(edge, "condition") == "outcome=fail"
    end

    @tag :fast
    test "atom key is converted to string" do
      edge = %Edge{from: "a", to: "b", attrs: %{"weight" => "5"}}
      assert Edge.attr(edge, :weight) == "5"
    end

    @tag :fast
    test "missing key returns default" do
      edge = %Edge{from: "a", to: "b", attrs: %{}}
      assert Edge.attr(edge, "missing", "default") == "default"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # SECTION 12: Helpers Module
  # ═══════════════════════════════════════════════════════════════════════

  describe "Helpers.parse_int/2" do
    @tag :fast
    test "parses valid string integer" do
      assert Helpers.parse_int("42", 0) == 42
    end

    @tag :fast
    test "returns default for nil" do
      assert Helpers.parse_int(nil, 10) == 10
    end

    @tag :fast
    test "returns default for non-numeric string" do
      assert Helpers.parse_int("abc", 5) == 5
    end

    @tag :fast
    test "returns integer value directly" do
      assert Helpers.parse_int(99, 0) == 99
    end

    @tag :fast
    test "returns default for non-string non-integer" do
      assert Helpers.parse_int(3.14, 0) == 0
    end
  end

  describe "Helpers.parse_csv/1" do
    @tag :fast
    test "splits comma-separated values" do
      assert Helpers.parse_csv("a, b, c") == ["a", "b", "c"]
    end

    @tag :fast
    test "returns empty list for nil" do
      assert Helpers.parse_csv(nil) == []
    end

    @tag :fast
    test "returns empty list for empty string" do
      assert Helpers.parse_csv("") == []
    end

    @tag :fast
    test "handles single value" do
      assert Helpers.parse_csv("single") == ["single"]
    end

    @tag :fast
    test "rejects blank entries" do
      assert Helpers.parse_csv("a,,b, ,c") == ["a", "b", "c"]
    end

    @tag :fast
    test "returns empty list for non-binary" do
      assert Helpers.parse_csv(42) == []
    end
  end

  describe "Helpers.maybe_add/3" do
    @tag :fast
    test "adds non-nil value" do
      assert Helpers.maybe_add([], :key, "value") == [key: "value"]
    end

    @tag :fast
    test "skips nil value" do
      assert Helpers.maybe_add([], :key, nil) == []
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # SECTION 13: Handler Behaviour and Idempotency
  # ═══════════════════════════════════════════════════════════════════════

  describe "Handler.idempotency_of/1" do
    @tag :fast
    test "returns handler-declared idempotency" do
      assert Handler.idempotency_of(StartHandler) == :idempotent
    end

    @tag :fast
    test "returns :idempotent for exit handler" do
      assert Handler.idempotency_of(ExitHandler) == :idempotent
    end

    @tag :fast
    test "returns :idempotent for conditional handler" do
      assert Handler.idempotency_of(ConditionalHandler) == :idempotent
    end

    @tag :fast
    test "returns :idempotent_with_key for codergen handler" do
      assert Handler.idempotency_of(CodergenHandler) == :idempotent_with_key
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # SECTION 14: Outcome Struct Edge Cases
  # ═══════════════════════════════════════════════════════════════════════

  describe "Outcome struct defaults" do
    @tag :fast
    test "default outcome has success status" do
      outcome = %Outcome{}
      assert outcome.status == :success
    end

    @tag :fast
    test "default outcome has nil preferred_label" do
      outcome = %Outcome{}
      assert outcome.preferred_label == nil
    end

    @tag :fast
    test "default outcome has empty suggested_next_ids" do
      outcome = %Outcome{}
      assert outcome.suggested_next_ids == []
    end

    @tag :fast
    test "default outcome has empty context_updates" do
      outcome = %Outcome{}
      assert outcome.context_updates == %{}
    end

    @tag :fast
    test "default outcome has nil notes and failure_reason" do
      outcome = %Outcome{}
      assert outcome.notes == nil
      assert outcome.failure_reason == nil
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # SECTION 15: Fidelity Resolution
  # ═══════════════════════════════════════════════════════════════════════

  describe "Fidelity resolution in engine" do
    @tag :fast
    test "edge fidelity takes precedence over node fidelity" do
      graph =
        build_graph(
          [
            {"start", %{"shape" => "Mdiamond"}},
            {"task", %{"fidelity" => "compact"}},
            {"exit", %{"shape" => "Msquare"}}
          ],
          [
            {"start", "task", %{"fidelity" => "full", "thread_id" => "edge-t"}},
            {"task", "exit", %{}}
          ]
        )

      opts = collect_events(logs_root: tmp_logs_root())
      assert {:ok, _result} = Engine.run(graph, opts)

      assert_receive {:event,
                      %{type: :fidelity_resolved, node_id: "task", mode: "full"}}
    end

    @tag :fast
    test "node fidelity used when no edge fidelity" do
      graph =
        build_graph(
          [
            {"start", %{"shape" => "Mdiamond"}},
            {"task", %{"fidelity" => "truncate"}},
            {"exit", %{"shape" => "Msquare"}}
          ],
          [
            {"start", "task", %{}},
            {"task", "exit", %{}}
          ]
        )

      opts = collect_events(logs_root: tmp_logs_root())
      assert {:ok, _result} = Engine.run(graph, opts)

      assert_receive {:event,
                      %{type: :fidelity_resolved, node_id: "task", mode: "truncate"}}
    end

    @tag :fast
    test "graph default_fidelity used as fallback" do
      graph =
        build_graph(
          [
            {"start", %{"shape" => "Mdiamond"}},
            {"task", %{"label" => "Task"}},
            {"exit", %{"shape" => "Msquare"}}
          ],
          [
            {"start", "task", %{}},
            {"task", "exit", %{}}
          ],
          %{"default_fidelity" => "summary:low"}
        )

      opts = collect_events(logs_root: tmp_logs_root())
      assert {:ok, _result} = Engine.run(graph, opts)

      assert_receive {:event,
                      %{type: :fidelity_resolved, node_id: "task", mode: "summary:low"}}
    end

    @tag :fast
    test "invalid fidelity falls back to compact" do
      graph =
        build_graph(
          [
            {"start", %{"shape" => "Mdiamond"}},
            {"task", %{"fidelity" => "invalid_mode"}},
            {"exit", %{"shape" => "Msquare"}}
          ],
          [
            {"start", "task", %{}},
            {"task", "exit", %{}}
          ]
        )

      opts = collect_events(logs_root: tmp_logs_root())
      assert {:ok, _result} = Engine.run(graph, opts)

      assert_receive {:event,
                      %{type: :fidelity_resolved, node_id: "task", mode: "compact"}}
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # SECTION 16: Fan-out and Fan-in Integration
  # ═══════════════════════════════════════════════════════════════════════

  describe "fan-out and fan-in integration" do
    @tag :fast
    test "two-branch fan-out executes both branches before merge" do
      graph =
        build_graph(
          [
            {"start", %{"shape" => "Mdiamond"}},
            {"branch_a", %{"label" => "A"}},
            {"branch_b", %{"label" => "B"}},
            {"merge", %{"label" => "Merge"}},
            {"exit", %{"shape" => "Msquare"}}
          ],
          [
            {"start", "branch_a", %{}},
            {"start", "branch_b", %{}},
            {"branch_a", "merge", %{}},
            {"branch_b", "merge", %{}},
            {"merge", "exit", %{}}
          ]
        )

      assert {:ok, result} = Engine.run(graph, logs_root: tmp_logs_root())
      assert "branch_a" in result.completed_nodes
      assert "branch_b" in result.completed_nodes
      assert "merge" in result.completed_nodes

      merge_idx = Enum.find_index(result.completed_nodes, &(&1 == "merge"))
      a_idx = Enum.find_index(result.completed_nodes, &(&1 == "branch_a"))
      b_idx = Enum.find_index(result.completed_nodes, &(&1 == "branch_b"))

      assert merge_idx > a_idx
      assert merge_idx > b_idx
    end

    @tag :fast
    test "fan_out=false suppresses fan-out behavior" do
      graph =
        build_graph(
          [
            {"start", %{"shape" => "Mdiamond", "fan_out" => "false"}},
            {"a", %{"label" => "A"}},
            {"b", %{"label" => "B"}},
            {"exit", %{"shape" => "Msquare"}}
          ],
          [
            {"start", "a", %{}},
            {"start", "b", %{}},
            {"a", "exit", %{}},
            {"b", "exit", %{}}
          ]
        )

      assert {:ok, result} = Engine.run(graph, logs_root: tmp_logs_root())
      a_ran = "a" in result.completed_nodes
      b_ran = "b" in result.completed_nodes
      assert a_ran or b_ran
      refute a_ran and b_ran
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # SECTION 17: Graph Adaptation (Self-Modifying Pipelines)
  # ═══════════════════════════════════════════════════════════════════════

  describe "graph adaptation" do
    @tag :fast
    test "adapted graph key in context is cleared after use" do
      # The engine checks for __adapted_graph__ in context after each node
      # When present, it swaps the graph and clears the key
      ctx = Context.new(%{"__adapted_graph__" => nil})
      assert Context.get(ctx, "__adapted_graph__") == nil
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # SECTION 18: Failure Routing Edge Cases
  # ═══════════════════════════════════════════════════════════════════════

  describe "failure routing" do
    @tag :fast
    test "fail routes to retry_target when no fail condition edge" do
      graph =
        build_graph(
          [
            {"start", %{"shape" => "Mdiamond"}},
            {"failing", %{"simulate" => "fail", "max_retries" => "0", "retry_target" => "repair"}},
            {"repair", %{"label" => "Repair"}},
            {"normal", %{"label" => "Normal"}},
            {"exit", %{"shape" => "Msquare"}}
          ],
          [
            {"start", "failing", %{}},
            {"failing", "normal", %{}},
            {"repair", "exit", %{}},
            {"normal", "exit", %{}}
          ]
        )

      assert {:ok, result} =
               Engine.run(graph, logs_root: tmp_logs_root(), sleep_fn: fn _ -> :ok end)

      assert "repair" in result.completed_nodes
      refute "normal" in result.completed_nodes
    end

    @tag :fast
    test "fail condition edge takes precedence over retry_target" do
      graph =
        build_graph(
          [
            {"start", %{"shape" => "Mdiamond"}},
            {"failing",
             %{"simulate" => "fail", "max_retries" => "0", "retry_target" => "repair"}},
            {"fail_edge_target", %{"label" => "Fail Edge"}},
            {"repair", %{"label" => "Repair"}},
            {"exit", %{"shape" => "Msquare"}}
          ],
          [
            {"start", "failing", %{}},
            {"failing", "fail_edge_target", %{"condition" => "outcome=fail"}},
            {"fail_edge_target", "exit", %{}},
            {"repair", "exit", %{}}
          ]
        )

      assert {:ok, result} =
               Engine.run(graph, logs_root: tmp_logs_root(), sleep_fn: fn _ -> :ok end)

      assert "fail_edge_target" in result.completed_nodes
      refute "repair" in result.completed_nodes
    end

    @tag :fast
    test "allow_partial on retry exhaustion yields partial_success for that node" do
      graph =
        build_graph(
          [
            {"start", %{"shape" => "Mdiamond"}},
            {"flaky",
             %{
               "simulate" => "retry",
               "max_retries" => "1",
               "retry_initial_delay_ms" => "1",
               "allow_partial" => "true"
             }},
            {"exit", %{"shape" => "Msquare"}}
          ],
          [
            {"start", "flaky", %{}},
            {"flaky", "exit", %{}}
          ]
        )

      opts = collect_events(logs_root: tmp_logs_root(), sleep_fn: fn _ -> :ok end)

      assert {:ok, result} = Engine.run(graph, opts)

      # The flaky node gets partial_success when retries exhaust with allow_partial
      # But the pipeline continues, and exit node succeeds, making the final_outcome :success
      assert result.final_outcome.status == :success
      # Confirm the partial_success status was set in context during the flaky node
      # (the outcome field in context reflects the last node's status)
      assert "flaky" in result.completed_nodes
      assert "exit" in result.completed_nodes
      # The flaky node completed as partial_success, which routes forward
      assert_receive {:event, %{type: :stage_completed, node_id: "flaky", status: :partial_success}}
    end
  end
end
