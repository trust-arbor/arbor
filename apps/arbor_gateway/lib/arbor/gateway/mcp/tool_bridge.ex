defmodule Arbor.Gateway.MCP.ToolBridge do
  @moduledoc """
  Bridges MCP server tools into Arbor's capability-based action system.

  Converts MCP tool schemas to Arbor-compatible tool definitions and handles
  capability authorization for tool invocations.

  ## Capability URIs

  Each MCP tool is mapped to a capability URI:

      arbor://mcp/<server-name>/<tool-name>

  For example, connecting a GitHub MCP server named "github" that exposes
  a `create_issue` tool produces:

      arbor://mcp/github/create_issue

  ## Taint

  All MCP tool outputs are tagged as `:untrusted` with `:external` source,
  since they come from outside the Arbor security boundary.
  """

  @doc """
  Convert an MCP tool definition to an Arbor-compatible tool map.

  The returned map follows the same shape as Arbor action tool definitions,
  making MCP tools interchangeable with native actions from the agent's perspective.
  """
  @spec to_arbor_tool(String.t(), map()) :: map()
  def to_arbor_tool(server_name, %{"name" => name} = tool) do
    %{
      name: "mcp.#{server_name}.#{name}",
      description: Map.get(tool, "description", "MCP tool: #{name}"),
      input_schema: normalize_schema(Map.get(tool, "inputSchema", %{})),
      source: :mcp,
      server_name: server_name,
      mcp_tool_name: name,
      capability_uri: capability_uri(server_name, name)
    }
  end

  @doc """
  Convert all tools from an MCP server to Arbor-compatible format.
  """
  @spec to_arbor_tools(String.t(), [map()]) :: [map()]
  def to_arbor_tools(server_name, tools) when is_list(tools) do
    Enum.map(tools, &to_arbor_tool(server_name, &1))
  end

  @doc """
  Build the capability URI for an MCP tool.

      iex> ToolBridge.capability_uri("github", "create_issue")
      "arbor://mcp/github/create_issue"
  """
  @spec capability_uri(String.t(), String.t()) :: String.t()
  def capability_uri(server_name, tool_name) do
    "arbor://mcp/#{server_name}/#{tool_name}"
  end

  @doc """
  Check if an agent has the capability to call an MCP tool.

  Uses Arbor.Security.authorize/3 when available, falls back to permissive
  mode when security infrastructure isn't running (dev/test).
  """
  @spec authorize(String.t(), String.t(), String.t()) ::
          :ok | {:error, :unauthorized, String.t()}
  def authorize(agent_id, server_name, tool_name) do
    uri = capability_uri(server_name, tool_name)

    if security_available?() do
      case apply(Arbor.Security, :authorize, [agent_id, uri, %{action: :execute}]) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          {:error, :unauthorized,
           "Agent #{agent_id} lacks capability: #{uri} (#{inspect(reason)})"}
      end
    else
      # Permissive mode when security not running
      :ok
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  @doc """
  Wrap an MCP tool result with taint metadata.

  MCP outputs are tagged as `:untrusted` since they originate from
  external processes outside the Arbor trust boundary.
  """
  @spec taint_result(term(), String.t(), String.t()) :: map()
  def taint_result(result, server_name, tool_name) do
    %{
      value: result,
      taint: %{
        level: :untrusted,
        sensitivity: :internal,
        confidence: :plausible,
        source: "mcp:#{server_name}/#{tool_name}",
        sanitizations: 0
      }
    }
  end

  @doc """
  Parse an Arbor tool name back to server_name and tool_name.

  Returns `{:ok, server_name, tool_name}` or `:error`.

      iex> ToolBridge.parse_tool_name("mcp.github.create_issue")
      {:ok, "github", "create_issue"}
  """
  @spec parse_tool_name(String.t()) :: {:ok, String.t(), String.t()} | :error
  def parse_tool_name("mcp." <> rest) do
    case String.split(rest, ".", parts: 2) do
      [server_name, tool_name] when server_name != "" and tool_name != "" ->
        {:ok, server_name, tool_name}

      _ ->
        :error
    end
  end

  def parse_tool_name(_), do: :error

  # -- Private --

  defp normalize_schema(%{"type" => _} = schema), do: schema

  defp normalize_schema(schema) when is_map(schema) do
    Map.put_new(schema, "type", "object")
  end

  defp normalize_schema(_), do: %{"type" => "object", "properties" => %{}}

  defp security_available? do
    Code.ensure_loaded?(Arbor.Security) and
      function_exported?(Arbor.Security, :authorize, 3) and
      Process.whereis(Arbor.Security.CapabilityStore) != nil
  end
end
