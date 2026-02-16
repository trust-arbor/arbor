defmodule Arbor.Orchestrator.UnifiedLLM.ArborActionsExecutor do
  @moduledoc """
  Bridges ToolLoop's `execute/3` interface to Arbor.Actions.

  Converts Arbor Action schemas (Jido format) to OpenAI tool-calling format
  for the LLM, and routes `execute/3` calls to Arbor's action system.

  ## Usage in DOT nodes

  Set `tools` attribute to a comma-separated list of action names:

      node [type="codergen" use_tools="true" tools="file_read,file_search,shell_execute"]

  If `tools` is omitted, falls back to `CodingTools` (5 built-in tools).

  ## Tool Format

  Arbor Actions use Jido format (`to_tool/0`):

      %{name: "file_read", description: "...", parameters_schema: %{...}}

  This module converts them to OpenAI format for the LLM:

      %{"type" => "function", "function" => %{"name" => "file_read", ...}}
  """

  require Logger

  @actions_mod Module.concat([:Arbor, :Actions])

  @doc """
  Get OpenAI-format tool definitions for the specified action names.

  If `action_names` is nil, returns definitions for all available actions.
  """
  @spec definitions(list(String.t()) | nil) :: [map()]
  def definitions(action_names \\ nil)

  def definitions(nil) do
    with_actions_module(fn ->
      apply(@actions_mod, :all_tools, [])
      |> Enum.map(&to_openai_format/1)
    end) || []
  end

  def definitions(action_names) when is_list(action_names) do
    with_actions_module(fn ->
      action_map = build_action_map()

      Enum.flat_map(action_names, fn name ->
        name = String.trim(name)

        case Map.get(action_map, name) do
          nil ->
            Logger.warning("ArborActionsExecutor: unknown action '#{name}'")
            []

          module ->
            [to_openai_format(module.to_tool())]
        end
      end)
    end) || []
  end

  @doc """
  Execute an action by name, matching ToolLoop's `execute/3` interface.

  Maps tool names to Arbor Actions and executes via the action system.
  Uses a system agent ID for authorization since codergen runs in a
  trusted orchestrator context.
  """
  @spec execute(String.t(), map(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(name, args, workdir) do
    with_actions_module(fn ->
      action_map = build_action_map()

      case Map.get(action_map, name) do
        nil ->
          {:error, "Unknown action: #{name}"}

        action_module ->
          # Inject workdir into args for file/shell actions
          params = maybe_inject_workdir(args, workdir)

          case apply(@actions_mod, :authorize_and_execute, [
                 "orchestrator",
                 action_module,
                 params
               ]) do
            {:ok, result} when is_binary(result) ->
              {:ok, result}

            {:ok, result} ->
              {:ok, inspect(result)}

            {:error, reason} ->
              {:error, "Action #{name} failed: #{inspect(reason)}"}
          end
      end
    end) || {:error, "Arbor.Actions not available"}
  end

  # ============================================================================
  # Private
  # ============================================================================

  # Convert Jido tool format to OpenAI function-calling format
  defp to_openai_format(jido_tool) do
    %{
      "type" => "function",
      "function" => %{
        "name" => jido_tool.name,
        "description" => jido_tool.description,
        "parameters" => jido_tool.parameters_schema || %{"type" => "object", "properties" => %{}}
      }
    }
  end

  # Build a name -> module mapping from all registered actions
  defp build_action_map do
    apply(@actions_mod, :all_actions, [])
    |> Enum.map(fn module ->
      tool = module.to_tool()
      {tool.name, module}
    end)
    |> Map.new()
  end

  # Inject workdir for actions that need directory context
  defp maybe_inject_workdir(args, workdir) do
    args
    |> Map.put_new("workdir", workdir)
    |> Map.put_new("cwd", workdir)
  end

  # Runtime bridge — don't crash if arbor_actions isn't loaded
  defp with_actions_module(fun) do
    if Code.ensure_loaded?(@actions_mod) do
      fun.()
    else
      nil
    end
  rescue
    e ->
      Logger.warning("ArborActionsExecutor: #{inspect(e)}")
      nil
  end
end
