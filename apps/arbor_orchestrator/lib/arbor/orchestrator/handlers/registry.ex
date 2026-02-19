defmodule Arbor.Orchestrator.Handlers.Registry do
  @moduledoc """
  Handler registry mapping node type strings to handler modules.

  Organized into three layers:
    - **Core handlers** — 15 canonical primitives (start, exit, branch, etc.)
    - **Compat handlers** — all existing type strings mapped to their current handler modules
    - **Custom handlers** — runtime-registered handlers via `register/2`

  Resolution order: custom > compat > core. Default: CodergenHandler.
  """

  alias Arbor.Orchestrator.Graph.Node

  alias Arbor.Orchestrator.Handlers.{
    AccumulatorHandler,
    AdaptHandler,
    BranchHandler,
    CodergenHandler,
    ComposeHandler,
    ComputeHandler,
    ConditionalHandler,
    ConsensusHandler,
    DriftDetectHandler,
    EvalAggregateHandler,
    EvalDatasetHandler,
    EvalPersistHandler,
    EvalReportHandler,
    EvalRunHandler,
    ExecHandler,
    ExitHandler,
    FanInHandler,
    FeedbackLoopHandler,
    FileWriteHandler,
    GateHandler,
    ManagerLoopHandler,
    MapHandler,
    MemoryHandler,
    MemoryRecallHandler,
    MemoryStoreHandler,
    OutputValidateHandler,
    ParallelHandler,
    PipelineRunHandler,
    PipelineValidateHandler,
    PromptAbTestHandler,
    ReadHandler,
    RetryEscalateHandler,
    RoutingHandler,
    SessionHandler,
    ShellHandler,
    StartHandler,
    SubgraphHandler,
    ToolHandler,
    TransformHandler,
    WaitHandler,
    WaitHumanHandler,
    WriteHandler
  }

  @shape_to_type %{
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

  # 15 canonical core handlers
  @core_handlers %{
    "start" => StartHandler,
    "exit" => ExitHandler,
    "branch" => BranchHandler,
    "parallel" => ParallelHandler,
    "fan_in" => FanInHandler,
    "compute" => ComputeHandler,
    "transform" => TransformHandler,
    "exec" => ExecHandler,
    "read" => ReadHandler,
    "write" => WriteHandler,
    "compose" => ComposeHandler,
    "map" => MapHandler,
    "adapt" => AdaptHandler,
    "wait" => WaitHandler,
    "gate" => GateHandler
  }

  # Compatibility layer — all existing type strings → their CURRENT handler modules.
  # This preserves identical behavior for all existing DOT pipelines.
  @compat_handlers %{
    # Control flow
    "conditional" => ConditionalHandler,
    "parallel.fan_in" => FanInHandler,
    # Computation
    "codergen" => CodergenHandler,
    "routing.select" => RoutingHandler,
    "prompt.ab_test" => PromptAbTestHandler,
    "drift_detect" => DriftDetectHandler,
    "retry.escalate" => RetryEscalateHandler,
    # Execution
    "tool" => ToolHandler,
    "shell" => ShellHandler,
    # File I/O
    "file.write" => FileWriteHandler,
    # Validation
    "output.validate" => OutputValidateHandler,
    "pipeline.validate" => PipelineValidateHandler,
    "pipeline.run" => PipelineRunHandler,
    # Eval
    "eval.dataset" => EvalDatasetHandler,
    "eval.run" => EvalRunHandler,
    "eval.aggregate" => EvalAggregateHandler,
    "eval.persist" => EvalPersistHandler,
    "eval.report" => EvalReportHandler,
    # Consensus
    "consensus.propose" => ConsensusHandler,
    "consensus.ask" => ConsensusHandler,
    "consensus.await" => ConsensusHandler,
    "consensus.check" => ConsensusHandler,
    "consensus.decide" => ConsensusHandler,
    # Memory
    "memory.recall" => MemoryHandler,
    "memory.consolidate" => MemoryHandler,
    "memory.index" => MemoryHandler,
    "memory.working_load" => MemoryHandler,
    "memory.working_save" => MemoryHandler,
    "memory.stats" => MemoryHandler,
    # Sub-graph composition
    "graph.invoke" => SubgraphHandler,
    "graph.compose" => SubgraphHandler,
    "graph.adapt" => AdaptHandler,
    # Stateful accumulation
    "accumulator" => AccumulatorHandler,
    # Feedback and loops
    "feedback.loop" => FeedbackLoopHandler,
    "stack.manager_loop" => ManagerLoopHandler,
    # Homelab-ported handlers
    "memory.recall_store" => MemoryRecallHandler,
    "memory.store_file" => MemoryStoreHandler,
    # Wait
    "wait.human" => WaitHumanHandler,
    # Session-as-DOT node types
    "session.classify" => SessionHandler,
    "session.memory_recall" => SessionHandler,
    "session.mode_select" => SessionHandler,
    "session.llm_call" => SessionHandler,
    "session.tool_dispatch" => SessionHandler,
    "session.format" => SessionHandler,
    "session.memory_update" => SessionHandler,
    "session.checkpoint" => SessionHandler,
    "session.background_checks" => SessionHandler,
    "session.process_results" => SessionHandler,
    "session.route_actions" => SessionHandler,
    "session.update_goals" => SessionHandler,
    "session.store_decompositions" => SessionHandler,
    "session.process_proposal_decisions" => SessionHandler,
    "session.consolidate" => SessionHandler,
    "session.update_working_memory" => SessionHandler,
    "session.store_identity" => SessionHandler
  }

  # Merged: core overridden by compat (preserves existing behavior)
  @handlers Map.merge(@core_handlers, @compat_handlers)
  @custom_handlers_key {__MODULE__, :custom_handlers}

  @doc "Returns the canonical core type for any type string."
  @spec canonical_type(String.t()) :: String.t()
  defdelegate canonical_type(type), to: Arbor.Orchestrator.Stdlib.Aliases

  @doc "Returns the 15 core handler type → module map."
  @spec core_handlers() :: map()
  def core_handlers, do: @core_handlers

  @doc "Returns the compatibility handler type → module map."
  @spec compat_handlers() :: map()
  def compat_handlers, do: @compat_handlers

  @spec node_type(Node.t()) :: String.t()
  def node_type(%Node{} = node) do
    Map.get(node.attrs, "type") ||
      Map.get(@shape_to_type, Map.get(node.attrs, "shape", "box"), "codergen")
  end

  @spec resolve(Node.t()) :: module()
  def resolve(%Node{} = node) do
    handlers = Map.merge(@handlers, custom_handlers())
    Map.get(handlers, node_type(node), CodergenHandler)
  end

  @spec register(String.t(), module()) :: :ok
  def register(type, module) when is_binary(type) and is_atom(module) do
    put_custom_handlers(Map.put(custom_handlers(), type, module))
  end

  @spec unregister(String.t()) :: :ok
  def unregister(type) when is_binary(type) do
    put_custom_handlers(Map.delete(custom_handlers(), type))
  end

  @spec reset_custom_handlers() :: :ok
  def reset_custom_handlers, do: put_custom_handlers(%{})

  @doc """
  Returns the current custom handlers map.
  Use with `restore_custom_handlers/1` for test save/restore.
  """
  @spec snapshot_custom_handlers() :: map()
  def snapshot_custom_handlers, do: custom_handlers()

  @doc """
  Restores custom handlers from a previous snapshot.
  """
  @spec restore_custom_handlers(map()) :: :ok
  def restore_custom_handlers(handlers) when is_map(handlers) do
    put_custom_handlers(handlers)
  end

  defp custom_handlers do
    :persistent_term.get(@custom_handlers_key, %{})
  end

  defp put_custom_handlers(handlers) do
    :persistent_term.put(@custom_handlers_key, handlers)
    :ok
  end
end
