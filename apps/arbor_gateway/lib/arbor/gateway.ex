defmodule Arbor.Gateway do
  @moduledoc """
  Arbor Gateway — HTTP entry point and MCP integration hub.

  Provides:
  - **Bridge**: Claude Code tool authorization via PreToolUse hooks
  - **MCP Server**: Exposes Arbor actions as MCP tools (via `/mcp` endpoint)
  - **MCP Client**: Connects to external MCP servers, exposing their tools to agents
  - **Dev tools**: Runtime evaluation, recompile, system info (dev only)
  - **Health**: Liveness checks

  ## Architecture

  ```
  HTTP Request
       ↓
  Arbor.Gateway.Router
       ├── /health                      → liveness check
       ├── /api/bridge/authorize_tool   → Claude Code authorization
       ├── /mcp                         → MCP server (ExMCP.HttpPlug)
       └── /api/dev/*                   → development tools

  MCP Client Infrastructure
       ↓
  ClientSupervisor (DynamicSupervisor)
       └── ClientConnection (per external MCP server)
            ├── ExMCP.Client (transport: stdio/http/sse/beam)
            └── ToolBridge (MCP tools → Arbor capabilities)
  ```

  ## MCP Client Usage

      # Connect to an external MCP server
      {:ok, pid} = Arbor.Gateway.connect_mcp_server("github", %{
        transport: :stdio,
        command: ["npx", "-y", "@modelcontextprotocol/server-github"],
        env: %{"GITHUB_TOKEN" => System.get_env("GITHUB_TOKEN")}
      })

      # List tools from all connected servers
      tools = Arbor.Gateway.list_mcp_tools()

      # Call a specific tool
      {:ok, result} = Arbor.Gateway.call_mcp_tool("github", "create_issue", %{
        "owner" => "org", "repo" => "project", "title" => "Bug report"
      })

  ## Configuration

      config :arbor_gateway,
        port: 4000,
        mcp_workspace: "~/.arbor/workspace"
  """

  alias Arbor.Gateway.Bridge.ClaudeSession
  alias Arbor.Gateway.MCP.ClientConnection
  alias Arbor.Gateway.MCP.ClientSupervisor
  alias Arbor.Gateway.MCP.ToolBridge

  # -- Bridge --

  @doc """
  Authorize a tool call from a Claude Code session.

  ## Returns

  - `{:ok, :authorized}` — tool is allowed
  - `{:ok, :authorized, updated_input}` — tool is allowed with modified parameters
  - `{:error, :unauthorized, reason}` — tool is blocked
  """
  defdelegate authorize(session_id, tool_name, tool_input, cwd),
    to: ClaudeSession,
    as: :authorize_tool

  @doc """
  Ensure a Claude session is registered as an Arbor agent.

  Sessions are automatically registered on first tool call, but this can be
  called explicitly to pre-register a session.
  """
  defdelegate register_session(session_id, cwd), to: ClaudeSession, as: :ensure_registered

  @doc """
  Get the Arbor agent ID for a Claude session.
  """
  defdelegate agent_id(session_id), to: ClaudeSession, as: :to_agent_id

  # -- MCP Client --

  @doc """
  Connect to an external MCP server.

  Starts a supervised connection that automatically discovers available tools.

  ## Config

  - `:transport` — `:stdio`, `:http`, `:sse`, or `:beam` (required)
  - `:command` — command for stdio transport
  - `:url` — URL for HTTP/SSE transport
  - `:env` — environment variables for stdio transport
  - `:agent_id` — owning agent ID (for capability scoping)
  """
  @spec connect_mcp_server(String.t(), map()) :: {:ok, pid()} | {:error, term()}
  def connect_mcp_server(server_name, config) do
    ClientSupervisor.start_connection(server_name, config)
  end

  @doc """
  Disconnect from an external MCP server.
  """
  @spec disconnect_mcp_server(String.t()) :: :ok | {:error, :not_found}
  def disconnect_mcp_server(server_name) do
    ClientSupervisor.stop_connection(server_name)
  end

  @doc """
  List all active MCP server connections with their status.

  Returns `[{server_name, pid, connection_status}]`.
  """
  @spec list_mcp_connections() :: [{String.t(), pid(), atom()}]
  def list_mcp_connections do
    ClientSupervisor.list_connections()
  end

  @doc """
  List tools from connected MCP servers in Arbor-compatible format.

  When `server_name` is given, returns tools from that server only.
  Otherwise returns tools from all connected servers.
  """
  @spec list_mcp_tools(String.t() | nil) :: [map()]
  def list_mcp_tools(server_name \\ nil)

  def list_mcp_tools(nil) do
    ClientSupervisor.list_connections()
    |> Enum.flat_map(fn {name, pid, :connected} ->
      case ClientConnection.list_tools(pid) do
        {:ok, tools} -> ToolBridge.to_arbor_tools(name, tools)
        _ -> []
      end
    end)
  end

  def list_mcp_tools(server_name) do
    case ClientSupervisor.find_connection(server_name) do
      {:ok, pid} ->
        case ClientConnection.list_tools(pid) do
          {:ok, tools} -> ToolBridge.to_arbor_tools(server_name, tools)
          _ -> []
        end

      :error ->
        []
    end
  end

  @doc """
  Call a tool on a connected MCP server.

  The result is wrapped with taint metadata (`:untrusted` level) since
  it originates from an external process.

  ## Options

  - `:timeout` — call timeout in ms (default: 30_000)
  - `:agent_id` — agent ID for capability authorization
  - `:skip_auth` — skip capability check (default: false)
  """
  @spec call_mcp_tool(String.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def call_mcp_tool(server_name, tool_name, arguments, opts \\ []) do
    # Authorization check
    agent_id = Keyword.get(opts, :agent_id)
    skip_auth = Keyword.get(opts, :skip_auth, false)

    with :ok <- maybe_authorize(agent_id, server_name, tool_name, skip_auth),
         {:ok, pid} <- find_connection(server_name),
         {:ok, result} <- ClientConnection.call_tool(pid, tool_name, arguments, opts) do
      {:ok, ToolBridge.taint_result(result, server_name, tool_name)}
    end
  end

  @doc """
  Get the status of a specific MCP server connection.
  """
  @spec mcp_server_status(String.t()) :: {:ok, map()} | {:error, :not_found}
  def mcp_server_status(server_name) do
    case ClientSupervisor.find_connection(server_name) do
      {:ok, pid} -> ClientConnection.status(pid)
      :error -> {:error, :not_found}
    end
  end

  # -- Private helpers --

  defp maybe_authorize(nil, _server, _tool, _skip), do: :ok
  defp maybe_authorize(_agent_id, _server, _tool, true), do: :ok

  defp maybe_authorize(agent_id, server_name, tool_name, false) do
    ToolBridge.authorize(agent_id, server_name, tool_name)
  end

  defp find_connection(server_name) do
    case ClientSupervisor.find_connection(server_name) do
      {:ok, pid} -> {:ok, pid}
      :error -> {:error, {:not_connected, server_name}}
    end
  end
end
