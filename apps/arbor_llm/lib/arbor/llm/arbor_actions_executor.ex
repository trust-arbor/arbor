defmodule Arbor.LLM.ArborActionsExecutor do
  @moduledoc """
  LLM-facing tool interface for Arbor Actions.

  Converts Arbor Action schemas (Jido format) to OpenAI tool-calling format
  for the LLM, and delegates execution to `Arbor.Orchestrator.ActionsExecutor`.

  ## Usage in DOT nodes

  Set `tools` attribute to a comma-separated list of action names:

      node [type="codergen" use_tools="true" tools="file_read,file_search,shell_execute"]

  If `tools` is omitted, all available actions are used.
  """

  # Arbor.Orchestrator.ActionsExecutor lives in arbor_orchestrator (which
  # depends on arbor_llm). Runtime indirection avoids the cycle — see
  # Client's @tool_hooks_mod for the same pattern. defdelegate, being a
  # compile-time directive, must be replaced with apply/3.
  @actions_executor_mod Arbor.Orchestrator.ActionsExecutor

  @actions_mod Module.concat([:Arbor, :Actions])

  @doc """
  Get OpenAI-format tool definitions for the specified action names.

  If `action_names` is nil, returns definitions for all available actions.
  """
  @spec definitions(list(String.t()) | nil) :: [map()]
  def definitions(action_names \\ nil)

  def definitions(nil) do
    executor = @actions_executor_mod

    apply(executor, :with_actions_module, [
      fn ->
        apply(@actions_mod, :all_tools, [])
        |> Enum.map(&to_openai_format/1)
      end
    ]) || []
  end

  def definitions(action_names) when is_list(action_names) do
    executor = @actions_executor_mod

    apply(executor, :with_actions_module, [
      fn ->
        registry = Arbor.Common.ActionRegistry

      Enum.flat_map(action_names, fn name ->
        name = String.trim(name)

        case resolve_action(registry, name) do
          {:ok, module} ->
            [to_openai_format(module.to_tool())]

          {:error, _} ->
            require Logger
            Logger.warning("ArborActionsExecutor: unknown action '#{name}'")
            []
        end
      end)
      end
    ]) || []
  end

  # Resolve via ActionRegistry first, then fall back to build_action_map.
  # The registry uses module-derived canonical names (e.g. "tool.find_tools")
  # while the action map also indexes by Jido name (e.g. "find_tools").
  defp resolve_action(registry, name) do
    registry_result =
      if Process.whereis(registry) do
        registry.resolve_by_name(name)
      else
        {:error, :not_found}
      end

    case registry_result do
      {:ok, _module} = ok ->
        ok

      {:error, :not_found} ->
        executor = @actions_executor_mod
        action_map = apply(executor, :build_action_map, [])

        case Map.get(action_map, name) do
          nil -> {:error, :not_found}
          module -> {:ok, module}
        end
    end
  end

  @doc """
  Execute an action by name. Delegates to `Arbor.Orchestrator.ActionsExecutor.execute/4`.

  `defdelegate` would be a compile-time bind; we go through apply/3 to keep
  the arbor_orchestrator boundary at runtime — see module-level comment.
  """
  @spec execute(String.t(), map(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def execute(name, args, workdir, opts \\ []) do
    executor = @actions_executor_mod
    apply(executor, :execute, [name, args, workdir, opts])
  end

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
