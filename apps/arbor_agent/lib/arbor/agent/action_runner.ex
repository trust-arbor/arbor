defmodule Arbor.Agent.ActionRunner do
  @moduledoc """
  Stateless helper for executing Jido actions on agents.

  Executes an action on the agent using Jido 2.0's `cmd/2` API, returning
  the updated agent, result, and directives. Used by `Arbor.Agent.Server`
  for action dispatch.

  ## Usage

      case ActionRunner.run(agent, MyAction, %{param: "value"}) do
        {:ok, updated_agent, result} -> handle_success(result)
        {:error, reason} -> handle_failure(reason)
      end
  """

  require Logger

  @doc """
  Run a Jido action on an agent.

  Uses the agent module's `cmd/2` to execute the action. In Jido 2.0,
  `cmd/2` returns `{updated_agent, directives}` where directives may
  include error directives on failure.

  ## Parameters
  - `agent` - The Jido agent struct
  - `action_module` - The action module to execute
  - `params` - Parameters to pass to the action
  - `opts` - Options
    - `:agent_module` - The concrete agent module (required for cmd dispatch)

  ## Returns
  - `{:ok, updated_agent, result}` on success
  - `{:error, reason}` on failure (including Directive.Error directives)
  """
  @spec run(struct(), module(), map(), keyword()) :: {:ok, struct(), term()} | {:error, term()}
  def run(agent, action_module, params, opts \\ []) do
    # The concrete module that defined the agent (has cmd/2)
    # Falls back to agent.__struct__ which is Jido.Agent for the struct itself
    concrete_module = Keyword.get(opts, :agent_module, agent.__struct__)
    Code.ensure_loaded(concrete_module)

    action = {action_module, params}
    {updated_agent, directives} = concrete_module.cmd(agent, action)

    # Check for error directives
    case find_error_directive(directives) do
      nil ->
        result = extract_result(updated_agent, directives)
        {:ok, updated_agent, result}

      error_directive ->
        {:error, error_directive.error}
    end
  rescue
    e in [UndefinedFunctionError] ->
      Logger.warning("Action module not available: #{Exception.message(e)}")
      {:error, {:action_failed, Exception.message(e)}}

    e in [RuntimeError, ArgumentError, KeyError, FunctionClauseError] ->
      Logger.warning("Exception in action: #{Exception.message(e)}")
      {:error, {:action_failed, Exception.message(e)}}

    e ->
      Logger.warning("Unexpected error in action", error: inspect(e))
      {:error, {:action_failed, Exception.message(e)}}
  catch
    kind, reason ->
      Logger.warning("Caught #{kind} in action", reason: inspect(reason))
      {:error, {:action_failed, "Action execution interrupted (#{kind})"}}
  end

  # Check directives list for error directives
  defp find_error_directive(directives) when is_list(directives) do
    Enum.find(directives, fn
      %{__struct__: struct} ->
        struct_name = to_string(struct)
        String.contains?(struct_name, "Error")

      _ ->
        false
    end)
  end

  defp find_error_directive(_), do: nil

  # Extract result from agent state or directives
  defp extract_result(agent, _directives) do
    Map.get(agent, :result, agent.state)
  end
end
