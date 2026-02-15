defmodule Arbor.Orchestrator.Handlers.Registry do
  @moduledoc false

  alias Arbor.Orchestrator.Graph.Node

  alias Arbor.Orchestrator.Handlers.{
    AccumulatorHandler,
    AdaptHandler,
    CodergenHandler,
    ConditionalHandler,
    ConsensusHandler,
    DriftDetectHandler,
    EvalAggregateHandler,
    EvalDatasetHandler,
    EvalPersistHandler,
    EvalReportHandler,
    EvalRunHandler,
    ExitHandler,
    FanInHandler,
    FeedbackLoopHandler,
    FileWriteHandler,
    ManagerLoopHandler,
    MapHandler,
    MemoryHandler,
    MemoryRecallHandler,
    MemoryStoreHandler,
    OutputValidateHandler,
    PipelineRunHandler,
    PipelineValidateHandler,
    ParallelHandler,
    PromptAbTestHandler,
    RetryEscalateHandler,
    RoutingHandler,
    SessionHandler,
    ShellHandler,
    StartHandler,
    SubgraphHandler,
    ToolHandler,
    WaitHumanHandler
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

  @handlers %{
    "start" => StartHandler,
    "exit" => ExitHandler,
    "conditional" => ConditionalHandler,
    "tool" => ToolHandler,
    "wait.human" => WaitHumanHandler,
    "parallel" => ParallelHandler,
    "parallel.fan_in" => FanInHandler,
    "stack.manager_loop" => ManagerLoopHandler,
    "codergen" => CodergenHandler,
    "file.write" => FileWriteHandler,
    "output.validate" => OutputValidateHandler,
    "pipeline.validate" => PipelineValidateHandler,
    "pipeline.run" => PipelineRunHandler,
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
    # Graph adaptation (self-modifying pipelines)
    "graph.adapt" => AdaptHandler,
    # Shell command execution
    "shell" => ShellHandler,
    # Stateful accumulation
    "accumulator" => AccumulatorHandler,
    # Model escalation
    "retry.escalate" => RetryEscalateHandler,
    # Iterative feedback loops
    "feedback.loop" => FeedbackLoopHandler,
    # Collection fan-out
    "map" => MapHandler,
    # Homelab-ported handlers
    "drift_detect" => DriftDetectHandler,
    "prompt.ab_test" => PromptAbTestHandler,
    "memory.recall_store" => MemoryRecallHandler,
    "memory.store_file" => MemoryStoreHandler,
    # LLM routing
    "routing.select" => RoutingHandler,
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
    "session.update_goals" => SessionHandler
  }
  @custom_handlers_key {__MODULE__, :custom_handlers}

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
