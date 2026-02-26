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
  alias Arbor.Gateway.MCP.AgentEndpoint
  alias Arbor.Gateway.MCP.ClientConnection
  alias Arbor.Gateway.MCP.ClientSupervisor
  alias Arbor.Gateway.MCP.EndpointRegistry
  alias Arbor.Gateway.MCP.ResourceBridge
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

  # -- MCP Resources --

  @doc """
  List resources from connected MCP servers in Arbor-compatible format.

  When `server_name` is given, returns resources from that server only.
  Otherwise returns resources from all connected servers.
  """
  @spec list_mcp_resources(String.t() | nil) :: [map()]
  def list_mcp_resources(server_name \\ nil)

  def list_mcp_resources(nil) do
    ClientSupervisor.list_connections()
    |> Enum.flat_map(fn {name, pid, :connected} ->
      case ClientConnection.list_resources(pid) do
        {:ok, resources} -> ResourceBridge.to_arbor_resources(name, resources)
        _ -> []
      end
    end)
  end

  def list_mcp_resources(server_name) do
    case ClientSupervisor.find_connection(server_name) do
      {:ok, pid} ->
        case ClientConnection.list_resources(pid) do
          {:ok, resources} -> ResourceBridge.to_arbor_resources(server_name, resources)
          _ -> []
        end

      :error ->
        []
    end
  end

  @doc """
  Read a resource from a connected MCP server.

  The result is wrapped with taint metadata (`:untrusted` level) since
  it originates from an external process.

  ## Options

  - `:timeout` — read timeout in ms (default: 30_000)
  - `:agent_id` — agent ID for capability authorization
  - `:skip_auth` — skip capability check (default: false)
  """
  @spec read_mcp_resource(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def read_mcp_resource(server_name, resource_uri, opts \\ []) do
    agent_id = Keyword.get(opts, :agent_id)
    skip_auth = Keyword.get(opts, :skip_auth, false)

    # Derive resource name from URI for authorization
    resource_name = resource_name_from_uri(server_name, resource_uri)

    with :ok <- maybe_authorize_resource(agent_id, server_name, resource_name, skip_auth),
         {:ok, pid} <- find_connection(server_name),
         {:ok, contents} <- ClientConnection.read_resource(pid, resource_uri, opts) do
      {:ok, ResourceBridge.taint_contents(contents, server_name, resource_uri)}
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

  # -- Agent MCP Endpoints (BEAM-native agent-to-agent) --

  @doc """
  Start an MCP endpoint for an agent, exposing its actions as MCP tools.

  Other agents can then connect via ExMCP's Local transport (`:native` mode)
  for zero-serialization agent-to-agent communication.

  ## Options

  - `:actions` — list of action modules to expose (default: all available)
  """
  @spec start_agent_endpoint(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_agent_endpoint(agent_id, opts \\ []) do
    endpoint_opts = Keyword.merge(opts, agent_id: agent_id)

    case AgentEndpoint.start_link(endpoint_opts) do
      {:ok, pid} ->
        tools = AgentEndpoint.list_tools(pid)
        EndpointRegistry.register(agent_id, pid, tools)
        {:ok, pid}

      error ->
        error
    end
  end

  @doc """
  Stop an agent's MCP endpoint.
  """
  @spec stop_agent_endpoint(String.t()) :: :ok | {:error, :not_found}
  def stop_agent_endpoint(agent_id) do
    case EndpointRegistry.lookup(agent_id) do
      {:ok, pid, _tools} ->
        EndpointRegistry.unregister(agent_id)
        GenServer.stop(pid, :normal)

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  List all active agent MCP endpoints.

  Returns `[{agent_id, endpoint_pid, tool_count}]`.
  """
  @spec list_agent_endpoints() :: [{String.t(), pid(), integer()}]
  def list_agent_endpoints do
    EndpointRegistry.list()
  end

  @doc """
  Connect to another agent's MCP endpoint as a client.

  Uses ExMCP's Local transport in `:native` mode for zero-serialization
  communication. Returns an `ExMCP.Client` pid that can be used with
  `ExMCP.Client.call_tool/3`, `ExMCP.Client.list_tools/1`, etc.

  ## Options

  - `:mode` — `:native` (default) or `:beam` (JSON-validated)
  """
  @spec connect_to_agent(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def connect_to_agent(target_agent_id, opts \\ []) do
    case EndpointRegistry.lookup(target_agent_id) do
      {:ok, endpoint_pid, _tools} ->
        mode = Keyword.get(opts, :mode, :native)
        transport = if mode == :native, do: :native, else: :beam

        ExMCP.Client.start_link(
          transport: transport,
          server: endpoint_pid
        )

      :error ->
        {:error, {:agent_endpoint_not_found, target_agent_id}}
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

  defp maybe_authorize_resource(nil, _server, _resource, _skip), do: :ok
  defp maybe_authorize_resource(_agent_id, _server, _resource, true), do: :ok

  defp maybe_authorize_resource(agent_id, server_name, resource_name, false) do
    ResourceBridge.authorize(agent_id, server_name, resource_name)
  end

  # Derive a short resource name from a URI for capability lookups.
  # Tries to find a matching cached resource name, falls back to URI basename.
  defp resource_name_from_uri(server_name, uri) do
    case ClientSupervisor.find_connection(server_name) do
      {:ok, pid} ->
        case ClientConnection.list_resources(pid) do
          {:ok, resources} ->
            case Enum.find(resources, &(&1["uri"] == uri)) do
              %{"name" => name} -> name
              _ -> URI.parse(uri) |> Map.get(:path, uri) |> Path.basename()
            end

          _ ->
            Path.basename(uri)
        end

      :error ->
        Path.basename(uri)
    end
  end
end
