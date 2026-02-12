defmodule Arbor.Orchestrator.Handlers.Registry do
  @moduledoc false

  alias Arbor.Orchestrator.Graph.Node

  alias Arbor.Orchestrator.Handlers.{
    CodergenHandler,
    ConditionalHandler,
    EvalAggregateHandler,
    EvalDatasetHandler,
    EvalReportHandler,
    EvalRunHandler,
    ExitHandler,
    FanInHandler,
    FileWriteHandler,
    ManagerLoopHandler,
    PipelineRunHandler,
    PipelineValidateHandler,
    ParallelHandler,
    StartHandler,
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
    "house" => "stack.manager_loop"
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
    "pipeline.validate" => PipelineValidateHandler,
    "pipeline.run" => PipelineRunHandler,
    "eval.dataset" => EvalDatasetHandler,
    "eval.run" => EvalRunHandler,
    "eval.aggregate" => EvalAggregateHandler,
    "eval.report" => EvalReportHandler
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
