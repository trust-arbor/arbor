defmodule Arbor.Orchestrator.UnifiedLLM.ToolCallValidator do
  @moduledoc false

  alias Arbor.Orchestrator.UnifiedLLM.Tool

  @spec validate(map(), [Tool.t()]) :: :ok | {:error, term()}
  def validate(call, tools) when is_map(call) do
    id = Map.get(call, "id") || Map.get(call, :id)
    name = Map.get(call, "name") || Map.get(call, :name)
    arguments = Map.get(call, "arguments") || Map.get(call, :arguments)

    cond do
      not is_binary(id) and not is_integer(id) ->
        {:error, :missing_id}

      not is_binary(name) ->
        {:error, :missing_name}

      Enum.find(tools, &(&1.name == name)) == nil ->
        {:error, :unknown_tool}

      not is_map(arguments) ->
        {:error, :invalid_arguments}

      true ->
        :ok
    end
  end

  def validate(_call, _tools), do: {:error, :invalid_call_shape}

  @spec maybe_repair(map(), term(), [Tool.t()], keyword()) ::
          {:ok, map()} | {:error, term()} | :drop
  def maybe_repair(call, reason, tools, opts) do
    case Keyword.get(opts, :repair_tool_call) do
      repair when is_function(repair, 3) ->
        repair.(call, reason, tools)

      _ ->
        {:error, reason}
    end
  end
end
