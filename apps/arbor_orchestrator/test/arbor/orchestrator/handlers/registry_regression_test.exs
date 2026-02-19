defmodule Arbor.Orchestrator.Handlers.RegistryRegressionTest do
  @moduledoc """
  Regression tests ensuring handler resolution produces correct results.

  Phase 4 (handler migration): alias types now resolve to their canonical
  core handler via the Aliases layer. The core handler then delegates to the
  appropriate specialized handler based on injected attributes.
  """
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Handlers.Registry

  # Phase 4 expected resolution: alias types resolve to core handlers.
  # Core handlers delegate to specialized handlers via injected attributes.
  @expected_mappings %{
    # Core types — resolve to themselves
    "start" => Arbor.Orchestrator.Handlers.StartHandler,
    "exit" => Arbor.Orchestrator.Handlers.ExitHandler,
    "parallel" => Arbor.Orchestrator.Handlers.ParallelHandler,
    "fan_in" => Arbor.Orchestrator.Handlers.FanInHandler,
    "map" => Arbor.Orchestrator.Handlers.MapHandler,
    "adapt" => Arbor.Orchestrator.Handlers.AdaptHandler,
    "compute" => Arbor.Orchestrator.Handlers.ComputeHandler,
    "transform" => Arbor.Orchestrator.Handlers.TransformHandler,
    "exec" => Arbor.Orchestrator.Handlers.ExecHandler,
    "read" => Arbor.Orchestrator.Handlers.ReadHandler,
    "write" => Arbor.Orchestrator.Handlers.WriteHandler,
    "compose" => Arbor.Orchestrator.Handlers.ComposeHandler,
    "branch" => Arbor.Orchestrator.Handlers.BranchHandler,
    "wait" => Arbor.Orchestrator.Handlers.WaitHandler,
    "gate" => Arbor.Orchestrator.Handlers.GateHandler,

    # Control flow aliases → core handlers
    "conditional" => Arbor.Orchestrator.Handlers.BranchHandler,
    "parallel.fan_in" => Arbor.Orchestrator.Handlers.FanInHandler,

    # Computation aliases → ComputeHandler
    "codergen" => Arbor.Orchestrator.Handlers.ComputeHandler,
    "routing.select" => Arbor.Orchestrator.Handlers.ComputeHandler,
    "prompt.ab_test" => Arbor.Orchestrator.Handlers.ComputeHandler,
    "drift_detect" => Arbor.Orchestrator.Handlers.ComputeHandler,
    "retry.escalate" => Arbor.Orchestrator.Handlers.ComputeHandler,
    "eval.run" => Arbor.Orchestrator.Handlers.ComputeHandler,
    "eval.aggregate" => Arbor.Orchestrator.Handlers.ComputeHandler,

    # Execution aliases → ExecHandler
    "tool" => Arbor.Orchestrator.Handlers.ExecHandler,
    "shell" => Arbor.Orchestrator.Handlers.ExecHandler,

    # Read aliases → ReadHandler
    "memory.recall" => Arbor.Orchestrator.Handlers.ReadHandler,
    "memory.working_load" => Arbor.Orchestrator.Handlers.ReadHandler,
    "memory.stats" => Arbor.Orchestrator.Handlers.ReadHandler,
    "memory.recall_store" => Arbor.Orchestrator.Handlers.ReadHandler,
    "eval.dataset" => Arbor.Orchestrator.Handlers.ReadHandler,

    # Write aliases → WriteHandler
    "file.write" => Arbor.Orchestrator.Handlers.WriteHandler,
    "memory.consolidate" => Arbor.Orchestrator.Handlers.WriteHandler,
    "memory.index" => Arbor.Orchestrator.Handlers.WriteHandler,
    "memory.working_save" => Arbor.Orchestrator.Handlers.WriteHandler,
    "memory.store_file" => Arbor.Orchestrator.Handlers.WriteHandler,
    "accumulator" => Arbor.Orchestrator.Handlers.WriteHandler,
    "eval.persist" => Arbor.Orchestrator.Handlers.WriteHandler,
    "eval.report" => Arbor.Orchestrator.Handlers.WriteHandler,

    # Composition aliases → ComposeHandler
    "graph.invoke" => Arbor.Orchestrator.Handlers.ComposeHandler,
    "graph.compose" => Arbor.Orchestrator.Handlers.ComposeHandler,
    "graph.adapt" => Arbor.Orchestrator.Handlers.AdaptHandler,
    "pipeline.run" => Arbor.Orchestrator.Handlers.ComposeHandler,
    "feedback.loop" => Arbor.Orchestrator.Handlers.ComposeHandler,
    "stack.manager_loop" => Arbor.Orchestrator.Handlers.ComposeHandler,
    "consensus.propose" => Arbor.Orchestrator.Handlers.ComposeHandler,
    "consensus.ask" => Arbor.Orchestrator.Handlers.ComposeHandler,
    "consensus.await" => Arbor.Orchestrator.Handlers.ComposeHandler,
    "consensus.check" => Arbor.Orchestrator.Handlers.ComposeHandler,
    "consensus.decide" => Arbor.Orchestrator.Handlers.ComposeHandler,
    "session.classify" => Arbor.Orchestrator.Handlers.ComposeHandler,
    "session.memory_recall" => Arbor.Orchestrator.Handlers.ComposeHandler,
    "session.mode_select" => Arbor.Orchestrator.Handlers.ComposeHandler,
    "session.llm_call" => Arbor.Orchestrator.Handlers.ComposeHandler,
    "session.tool_dispatch" => Arbor.Orchestrator.Handlers.ComposeHandler,
    "session.format" => Arbor.Orchestrator.Handlers.ComposeHandler,
    "session.memory_update" => Arbor.Orchestrator.Handlers.ComposeHandler,
    "session.checkpoint" => Arbor.Orchestrator.Handlers.ComposeHandler,
    "session.background_checks" => Arbor.Orchestrator.Handlers.ComposeHandler,
    "session.process_results" => Arbor.Orchestrator.Handlers.ComposeHandler,
    "session.route_actions" => Arbor.Orchestrator.Handlers.ComposeHandler,
    "session.update_goals" => Arbor.Orchestrator.Handlers.ComposeHandler,
    "session.store_decompositions" => Arbor.Orchestrator.Handlers.ComposeHandler,
    "session.process_proposal_decisions" => Arbor.Orchestrator.Handlers.ComposeHandler,
    "session.consolidate" => Arbor.Orchestrator.Handlers.ComposeHandler,
    "session.update_working_memory" => Arbor.Orchestrator.Handlers.ComposeHandler,
    "session.store_identity" => Arbor.Orchestrator.Handlers.ComposeHandler,

    # Coordination aliases → WaitHandler
    "wait.human" => Arbor.Orchestrator.Handlers.WaitHandler,

    # Governance aliases → GateHandler
    "output.validate" => Arbor.Orchestrator.Handlers.GateHandler,
    "pipeline.validate" => Arbor.Orchestrator.Handlers.GateHandler
  }

  describe "registry regression" do
    test "every existing type string resolves to the same handler module" do
      for {type, expected_module} <- @expected_mappings do
        node = %Node{id: "test_#{type}", attrs: %{"type" => type}}
        resolved = Registry.resolve(node)

        assert resolved == expected_module,
               "Type '#{type}' resolved to #{inspect(resolved)} but expected #{inspect(expected_module)}"
      end
    end

    test "unknown types still default to CodergenHandler" do
      node = %Node{id: "unknown", attrs: %{"type" => "nonexistent.type"}}
      assert Registry.resolve(node) == Arbor.Orchestrator.Handlers.CodergenHandler
    end

    test "shape-based resolution unchanged" do
      shapes = %{
        "Mdiamond" => "start",
        "Msquare" => "exit",
        "diamond" => "conditional",
        "parallelogram" => "tool",
        "hexagon" => "wait.human",
        "component" => "parallel",
        "tripleoctagon" => "parallel.fan_in",
        "house" => "stack.manager_loop",
        "octagon" => "graph.adapt"
      }

      for {shape, expected_type} <- shapes do
        node = %Node{id: "shape_test", attrs: %{"shape" => shape}}
        type = Registry.node_type(node)

        assert type == expected_type,
               "Shape '#{shape}' returned type '#{type}' but expected '#{expected_type}'"
      end
    end

    test "no type or shape defaults to codergen" do
      node = %Node{id: "bare", attrs: %{}}
      assert Registry.node_type(node) == "codergen"
    end
  end

  describe "new core handlers" do
    test "15 core handler types are registered" do
      core = Registry.core_handlers()
      assert map_size(core) == 15
    end

    test "core types resolve to new handler modules" do
      expected = %{
        "branch" => Arbor.Orchestrator.Handlers.BranchHandler,
        "compute" => Arbor.Orchestrator.Handlers.ComputeHandler,
        "transform" => Arbor.Orchestrator.Handlers.TransformHandler,
        "exec" => Arbor.Orchestrator.Handlers.ExecHandler,
        "read" => Arbor.Orchestrator.Handlers.ReadHandler,
        "write" => Arbor.Orchestrator.Handlers.WriteHandler,
        "compose" => Arbor.Orchestrator.Handlers.ComposeHandler,
        "wait" => Arbor.Orchestrator.Handlers.WaitHandler,
        "gate" => Arbor.Orchestrator.Handlers.GateHandler
      }

      for {type, expected_module} <- expected do
        node = %Node{id: "core_#{type}", attrs: %{"type" => type}}
        resolved = Registry.resolve(node)

        assert resolved == expected_module,
               "Core type '#{type}' resolved to #{inspect(resolved)} but expected #{inspect(expected_module)}"
      end
    end

    test "existing core types still resolve to original handlers" do
      # These core types already existed and should resolve to their original modules
      existing = %{
        "start" => Arbor.Orchestrator.Handlers.StartHandler,
        "exit" => Arbor.Orchestrator.Handlers.ExitHandler,
        "parallel" => Arbor.Orchestrator.Handlers.ParallelHandler,
        "fan_in" => Arbor.Orchestrator.Handlers.FanInHandler,
        "map" => Arbor.Orchestrator.Handlers.MapHandler,
        "adapt" => Arbor.Orchestrator.Handlers.AdaptHandler
      }

      for {type, expected_module} <- existing do
        node = %Node{id: "existing_#{type}", attrs: %{"type" => type}}
        resolved = Registry.resolve(node)

        assert resolved == expected_module,
               "Existing core type '#{type}' changed from #{inspect(expected_module)} to #{inspect(resolved)}"
      end
    end
  end

  describe "resolve_with_attrs/1" do
    test "aliased types resolve to core handlers with injected attributes" do
      # codergen → compute with purpose="llm"
      node = %Node{id: "n", attrs: %{"type" => "codergen"}}
      {handler, updated_node} = Registry.resolve_with_attrs(node)
      assert handler == Arbor.Orchestrator.Handlers.ComputeHandler
      assert updated_node.attrs["purpose"] == "llm"
    end

    test "shell alias injects target attribute" do
      node = %Node{id: "n", attrs: %{"type" => "shell"}}
      {handler, updated_node} = Registry.resolve_with_attrs(node)
      assert handler == Arbor.Orchestrator.Handlers.ExecHandler
      assert updated_node.attrs["target"] == "shell"
    end

    test "tool alias injects target attribute" do
      node = %Node{id: "n", attrs: %{"type" => "tool"}}
      {handler, updated_node} = Registry.resolve_with_attrs(node)
      assert handler == Arbor.Orchestrator.Handlers.ExecHandler
      assert updated_node.attrs["target"] == "tool"
    end

    test "memory.recall alias injects source and op" do
      node = %Node{id: "n", attrs: %{"type" => "memory.recall"}}
      {handler, updated_node} = Registry.resolve_with_attrs(node)
      assert handler == Arbor.Orchestrator.Handlers.ReadHandler
      assert updated_node.attrs["source"] == "memory"
      assert updated_node.attrs["op"] == "recall"
    end

    test "file.write alias injects target" do
      node = %Node{id: "n", attrs: %{"type" => "file.write"}}
      {handler, updated_node} = Registry.resolve_with_attrs(node)
      assert handler == Arbor.Orchestrator.Handlers.WriteHandler
      assert updated_node.attrs["target"] == "file"
    end

    test "eval.run alias injects purpose" do
      node = %Node{id: "n", attrs: %{"type" => "eval.run"}}
      {handler, updated_node} = Registry.resolve_with_attrs(node)
      assert handler == Arbor.Orchestrator.Handlers.ComputeHandler
      assert updated_node.attrs["purpose"] == "eval_run"
    end

    test "output.validate alias injects predicate" do
      node = %Node{id: "n", attrs: %{"type" => "output.validate"}}
      {handler, updated_node} = Registry.resolve_with_attrs(node)
      assert handler == Arbor.Orchestrator.Handlers.GateHandler
      assert updated_node.attrs["predicate"] == "output_valid"
    end

    test "graph.invoke alias injects mode" do
      node = %Node{id: "n", attrs: %{"type" => "graph.invoke"}}
      {handler, updated_node} = Registry.resolve_with_attrs(node)
      assert handler == Arbor.Orchestrator.Handlers.ComposeHandler
      assert updated_node.attrs["mode"] == "invoke"
    end

    test "wait.human alias injects source" do
      node = %Node{id: "n", attrs: %{"type" => "wait.human"}}
      {handler, updated_node} = Registry.resolve_with_attrs(node)
      assert handler == Arbor.Orchestrator.Handlers.WaitHandler
      assert updated_node.attrs["source"] == "human"
    end

    test "consensus types resolve to ComposeHandler with mode injection" do
      node = %Node{id: "n", attrs: %{"type" => "consensus.propose"}}
      {handler, updated_node} = Registry.resolve_with_attrs(node)
      assert handler == Arbor.Orchestrator.Handlers.ComposeHandler
      assert updated_node.attrs["mode"] == "consensus"
    end

    test "session types resolve to ComposeHandler with mode injection" do
      node = %Node{id: "n", attrs: %{"type" => "session.classify"}}
      {handler, updated_node} = Registry.resolve_with_attrs(node)
      assert handler == Arbor.Orchestrator.Handlers.ComposeHandler
      assert updated_node.attrs["mode"] == "session"
    end

    test "core types passthrough with no injection" do
      node = %Node{id: "n", attrs: %{"type" => "compute"}}
      {handler, returned_node} = Registry.resolve_with_attrs(node)
      assert handler == Arbor.Orchestrator.Handlers.ComputeHandler
      assert returned_node == node
    end

    test "explicit node attrs override injected attrs" do
      # Node has explicit purpose="custom" — should NOT be overwritten by alias injection
      node = %Node{id: "n", attrs: %{"type" => "codergen", "purpose" => "custom"}}
      {_handler, updated_node} = Registry.resolve_with_attrs(node)
      assert updated_node.attrs["purpose"] == "custom"
    end

    test "unknown types fall through to CodergenHandler" do
      node = %Node{id: "n", attrs: %{"type" => "nonexistent"}}
      {handler, returned_node} = Registry.resolve_with_attrs(node)
      assert handler == Arbor.Orchestrator.Handlers.CodergenHandler
      assert returned_node == node
    end
  end

  describe "custom handlers" do
    setup do
      snapshot = Registry.snapshot_custom_handlers()
      on_exit(fn -> Registry.restore_custom_handlers(snapshot) end)
      :ok
    end

    test "custom handlers override both core and compat" do
      defmodule TestHandler do
        @behaviour Arbor.Orchestrator.Handlers.Handler
        @impl true
        def execute(_, _, _, _), do: %Arbor.Orchestrator.Engine.Outcome{status: :success}
      end

      Registry.register("compute", TestHandler)
      node = %Node{id: "test", attrs: %{"type" => "compute"}}
      assert Registry.resolve(node) == TestHandler
    end
  end
end
