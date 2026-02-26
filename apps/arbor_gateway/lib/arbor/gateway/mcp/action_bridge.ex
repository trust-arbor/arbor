defmodule Arbor.Gateway.MCP.ActionBridge do
  @moduledoc """
  Bridges Arbor action modules into MCP tool definitions.

  This is the reverse of `ToolBridge` — converts Arbor's native actions into
  MCP-compatible tool schemas for agent-to-agent communication.

  ## Usage

      tools = ActionBridge.to_mcp_tools([Arbor.Actions.File.Read, Arbor.Actions.Shell.Execute])
      # => [%{"name" => "file_read", "description" => "...", "inputSchema" => %{...}}, ...]
  """

  @doc """
  Convert an Arbor action module to an MCP tool definition.

  Uses `action_module.to_tool()` which produces a `parameters_schema` already
  in JSON Schema format, then maps it to MCP's expected structure.
  """
  @spec to_mcp_tool(module()) :: map()
  def to_mcp_tool(action_module) when is_atom(action_module) do
    tool = action_module.to_tool()

    %{
      "name" => tool.name,
      "description" => tool.description || "Arbor action: #{tool.name}",
      "inputSchema" => tool.parameters_schema || %{"type" => "object", "properties" => %{}}
    }
  rescue
    _ ->
      %{
        "name" => module_to_name(action_module),
        "description" => "Arbor action: #{module_to_name(action_module)}",
        "inputSchema" => %{"type" => "object", "properties" => %{}}
      }
  end

  @doc """
  Convert a list of Arbor action modules to MCP tool definitions.
  """
  @spec to_mcp_tools([module()]) :: [map()]
  def to_mcp_tools(action_modules) when is_list(action_modules) do
    Enum.map(action_modules, &to_mcp_tool/1)
  end

  @doc """
  Build MCP tool definitions from all available Arbor actions.

  Uses the Arbor.Actions facade when available, falls back to empty list.
  """
  @spec all_mcp_tools() :: [map()]
  def all_mcp_tools do
    if Code.ensure_loaded?(Arbor.Actions) and
         function_exported?(Arbor.Actions, :all_actions, 0) do
      apply(Arbor.Actions, :all_actions, [])
      |> to_mcp_tools()
    else
      []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  # Fallback name extraction from module atom
  defp module_to_name(module) do
    module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
  end
end
