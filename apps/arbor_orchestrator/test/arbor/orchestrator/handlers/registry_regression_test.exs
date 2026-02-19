defmodule Arbor.Orchestrator.Handlers.RegistryRegressionTest do
  @moduledoc """
  Regression tests ensuring the registry restructuring (core + compat maps)
  produces identical behavior to the original flat @handlers map.
  """
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Handlers.Registry

  # The expected type → module mappings from the ORIGINAL registry.
  # If any of these change, it means the restructuring broke something.
  @expected_mappings %{
    "start" => Arbor.Orchestrator.Handlers.StartHandler,
    "exit" => Arbor.Orchestrator.Handlers.ExitHandler,
    "conditional" => Arbor.Orchestrator.Handlers.ConditionalHandler,
    "tool" => Arbor.Orchestrator.Handlers.ToolHandler,
    "wait.human" => Arbor.Orchestrator.Handlers.WaitHumanHandler,
    "parallel" => Arbor.Orchestrator.Handlers.ParallelHandler,
    "parallel.fan_in" => Arbor.Orchestrator.Handlers.FanInHandler,
    "stack.manager_loop" => Arbor.Orchestrator.Handlers.ManagerLoopHandler,
    "codergen" => Arbor.Orchestrator.Handlers.CodergenHandler,
    "file.write" => Arbor.Orchestrator.Handlers.FileWriteHandler,
    "output.validate" => Arbor.Orchestrator.Handlers.OutputValidateHandler,
    "pipeline.validate" => Arbor.Orchestrator.Handlers.PipelineValidateHandler,
    "pipeline.run" => Arbor.Orchestrator.Handlers.PipelineRunHandler,
    "eval.dataset" => Arbor.Orchestrator.Handlers.EvalDatasetHandler,
    "eval.run" => Arbor.Orchestrator.Handlers.EvalRunHandler,
    "eval.aggregate" => Arbor.Orchestrator.Handlers.EvalAggregateHandler,
    "eval.persist" => Arbor.Orchestrator.Handlers.EvalPersistHandler,
    "eval.report" => Arbor.Orchestrator.Handlers.EvalReportHandler,
    "consensus.propose" => Arbor.Orchestrator.Handlers.ConsensusHandler,
    "consensus.ask" => Arbor.Orchestrator.Handlers.ConsensusHandler,
    "consensus.await" => Arbor.Orchestrator.Handlers.ConsensusHandler,
    "consensus.check" => Arbor.Orchestrator.Handlers.ConsensusHandler,
    "consensus.decide" => Arbor.Orchestrator.Handlers.ConsensusHandler,
    "memory.recall" => Arbor.Orchestrator.Handlers.MemoryHandler,
    "memory.consolidate" => Arbor.Orchestrator.Handlers.MemoryHandler,
    "memory.index" => Arbor.Orchestrator.Handlers.MemoryHandler,
    "memory.working_load" => Arbor.Orchestrator.Handlers.MemoryHandler,
    "memory.working_save" => Arbor.Orchestrator.Handlers.MemoryHandler,
    "memory.stats" => Arbor.Orchestrator.Handlers.MemoryHandler,
    "graph.invoke" => Arbor.Orchestrator.Handlers.SubgraphHandler,
    "graph.compose" => Arbor.Orchestrator.Handlers.SubgraphHandler,
    "graph.adapt" => Arbor.Orchestrator.Handlers.AdaptHandler,
    "shell" => Arbor.Orchestrator.Handlers.ShellHandler,
    "accumulator" => Arbor.Orchestrator.Handlers.AccumulatorHandler,
    "retry.escalate" => Arbor.Orchestrator.Handlers.RetryEscalateHandler,
    "feedback.loop" => Arbor.Orchestrator.Handlers.FeedbackLoopHandler,
    "map" => Arbor.Orchestrator.Handlers.MapHandler,
    "drift_detect" => Arbor.Orchestrator.Handlers.DriftDetectHandler,
    "prompt.ab_test" => Arbor.Orchestrator.Handlers.PromptAbTestHandler,
    "memory.recall_store" => Arbor.Orchestrator.Handlers.MemoryRecallHandler,
    "memory.store_file" => Arbor.Orchestrator.Handlers.MemoryStoreHandler,
    "routing.select" => Arbor.Orchestrator.Handlers.RoutingHandler,
    "session.classify" => Arbor.Orchestrator.Handlers.SessionHandler,
    "session.memory_recall" => Arbor.Orchestrator.Handlers.SessionHandler,
    "session.mode_select" => Arbor.Orchestrator.Handlers.SessionHandler,
    "session.llm_call" => Arbor.Orchestrator.Handlers.SessionHandler,
    "session.tool_dispatch" => Arbor.Orchestrator.Handlers.SessionHandler,
    "session.format" => Arbor.Orchestrator.Handlers.SessionHandler,
    "session.memory_update" => Arbor.Orchestrator.Handlers.SessionHandler,
    "session.checkpoint" => Arbor.Orchestrator.Handlers.SessionHandler,
    "session.background_checks" => Arbor.Orchestrator.Handlers.SessionHandler,
    "session.process_results" => Arbor.Orchestrator.Handlers.SessionHandler,
    "session.route_actions" => Arbor.Orchestrator.Handlers.SessionHandler,
    "session.update_goals" => Arbor.Orchestrator.Handlers.SessionHandler,
    "session.store_decompositions" => Arbor.Orchestrator.Handlers.SessionHandler,
    "session.process_proposal_decisions" => Arbor.Orchestrator.Handlers.SessionHandler,
    "session.consolidate" => Arbor.Orchestrator.Handlers.SessionHandler,
    "session.update_working_memory" => Arbor.Orchestrator.Handlers.SessionHandler,
    "session.store_identity" => Arbor.Orchestrator.Handlers.SessionHandler
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
