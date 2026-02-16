defmodule Arbor.AI.ToolAuthorization do
  @moduledoc """
  Bridges tool authorization between arbor_ai (Standalone) and arbor_security (Level 1).

  Uses `Code.ensure_loaded?/1` + `apply/3` to avoid compile-time dependency on
  arbor_security. When security is unavailable (test, standalone mode), all tools
  pass through.
  """

  require Logger

  @doc """
  Filter a tools map, keeping only tools the agent is authorized to use.

  Returns the tools map unchanged if `agent_id` is nil (system-level call)
  or if the map is empty.
  """
  @spec filter_authorized_tools(String.t() | nil, map()) :: map()
  def filter_authorized_tools(nil, tools_map), do: tools_map

  def filter_authorized_tools(agent_id, tools_map) when map_size(tools_map) == 0 do
    Logger.debug("No tools to authorize for agent #{agent_id}")
    tools_map
  end

  def filter_authorized_tools(agent_id, tools_map) do
    {authorized, denied} =
      Enum.split_with(tools_map, fn {tool_name, _module} ->
        check_tool_authorization(agent_id, tool_name) == :authorized
      end)

    if denied != [] do
      denied_names = Enum.map(denied, fn {name, _} -> name end)

      Logger.info(
        "Tool authorization: filtered #{length(denied)} unauthorized tools " <>
          "for agent #{agent_id}: #{inspect(denied_names)}"
      )

      emit_tool_authorization_denied(agent_id, denied_names)
    end

    Map.new(authorized)
  end

  # Check whether an agent is authorized to execute a specific tool.
  #
  # Uses the Code.ensure_loaded?/apply bridge pattern to avoid compile-time
  # dependency on arbor_security (which is Level 1; arbor_ai is Standalone).
  #
  # Returns:
  #   :authorized - agent holds the capability (or security unavailable)
  #   :unauthorized - agent lacks the capability
  #   :pending_approval - requires escalation
  @spec check_tool_authorization(String.t(), String.t()) ::
          :authorized | :unauthorized | :pending_approval
  defp check_tool_authorization(agent_id, tool_name) do
    if Code.ensure_loaded?(Arbor.Security) do
      resource = "arbor://actions/execute/#{tool_name}"

      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      case apply(Arbor.Security, :authorize, [agent_id, resource, :execute, []]) do
        {:ok, :authorized} ->
          :authorized

        {:ok, :pending_approval, _proposal_id} ->
          Logger.debug(
            "Tool #{tool_name} requires approval for agent #{agent_id}, " <>
              "excluding from available tools"
          )

          :pending_approval

        {:error, reason} ->
          Logger.debug(
            "Tool authorization denied for #{tool_name}, agent #{agent_id}: #{inspect(reason)}"
          )

          :unauthorized
      end
    else
      Logger.debug(
        "Arbor.Security not loaded — tool authorization check skipped for #{tool_name}"
      )

      :authorized
    end
  rescue
    e ->
      Logger.warning(
        "Tool authorization check failed for #{tool_name}: #{inspect(e)}, defaulting to deny"
      )

      :unauthorized
  catch
    :exit, reason ->
      Logger.warning(
        "Tool authorization check exited for #{tool_name}: #{inspect(reason)}, defaulting to deny"
      )

      :unauthorized
  end

  defp emit_tool_authorization_denied(agent_id, denied_tool_names) do
    Arbor.Signals.emit(:security, :tool_authorization_denied, %{
      agent_id: agent_id,
      denied_tools: denied_tool_names,
      denied_count: length(denied_tool_names),
      source: :generate_text_with_tools
    })
  rescue
    _ -> :ok
  end
end
