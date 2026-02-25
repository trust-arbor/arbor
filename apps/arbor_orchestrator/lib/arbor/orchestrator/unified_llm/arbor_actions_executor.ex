defmodule Arbor.Orchestrator.UnifiedLLM.ArborActionsExecutor do
  @moduledoc """
  LLM-facing tool interface for Arbor Actions.

  Converts Arbor Action schemas (Jido format) to OpenAI tool-calling format
  for the LLM, and delegates execution to `Arbor.Orchestrator.ActionsExecutor`.

  ## Usage in DOT nodes

  Set `tools` attribute to a comma-separated list of action names:

      node [type="codergen" use_tools="true" tools="file_read,file_search,shell_execute"]

  If `tools` is omitted, falls back to `CodingTools` (5 built-in tools).
  """

  alias Arbor.Orchestrator.ActionsExecutor

  @actions_mod Module.concat([:Arbor, :Actions])

  @doc """
  Get OpenAI-format tool definitions for the specified action names.

  If `action_names` is nil, returns definitions for all available actions.
  """
  @spec definitions(list(String.t()) | nil) :: [map()]
  def definitions(action_names \\ nil)

  def definitions(nil) do
    ActionsExecutor.with_actions_module(fn ->
      apply(@actions_mod, :all_tools, [])
      |> Enum.map(&to_openai_format/1)
    end) || []
  end

  def definitions(action_names) when is_list(action_names) do
    ActionsExecutor.with_actions_module(fn ->
      action_map = ActionsExecutor.build_action_map()

      Enum.flat_map(action_names, fn name ->
        name = String.trim(name)

        case Map.get(action_map, name) do
          nil ->
            require Logger
            Logger.warning("ArborActionsExecutor: unknown action '#{name}'")
            []

          module ->
            [to_openai_format(module.to_tool())]
        end
      end)
    end) || []
  end

  @doc """
  Execute an action by name. Delegates to `Arbor.Orchestrator.ActionsExecutor.execute/4`.
  """
  @spec execute(String.t(), map(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  defdelegate execute(name, args, workdir, opts \\ []), to: ActionsExecutor

  @doc """
  Convert a Jido tool definition to OpenAI function-calling format.
  """
  @spec to_openai_format(map()) :: map()
  def to_openai_format(jido_tool) do
    %{
      "type" => "function",
      "function" => %{
        "name" => jido_tool.name,
        "description" => jido_tool.description,
        "parameters" => jido_tool.parameters_schema || %{"type" => "object", "properties" => %{}}
      }
    }
  end
end
