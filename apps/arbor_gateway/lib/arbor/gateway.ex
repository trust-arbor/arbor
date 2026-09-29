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

      # Call a specific tool (capability-checked for the calling agent)
      {:ok, result} = Arbor.Gateway.call_mcp_tool("github", "create_issue", %{
        "owner" => "org", "repo" => "project", "title" => "Bug report"
      }, agent_id: agent_id)

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
  - `:agent_id` — owning agent ID. An agent-bound connection requires that
    agent to hold the exact approval capability for this config
    (`Arbor.Security.mcp_server_approval_uri/2`, granted by
    `Arbor.Agent.set_mcp_config/2`); otherwise `{:error, :mcp_server_not_approved}`.
    Operator connections without `:agent_id` are not gated here.
  """
  @spec connect_mcp_server(String.t(), map()) :: {:ok, pid()} | {:error, term()}
  def connect_mcp_server(server_name, config) do
    with :ok <- authorize_mcp_server_connect(server_name, config) do
      ClientSupervisor.start_connection(server_name, config)
    end
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
    |> Enum.flat_map(fn
      {name, pid, :connected} ->
        case ClientConnection.list_tools(pid) do
          {:ok, tools} -> ToolBridge.to_arbor_tools(name, tools)
          _ -> []
        end

      # A disconnected/unhealthy server (e.g. retrying with backoff) must not
      # take down the listing for every other server (Imp review D7).
      _not_connected ->
        []
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
  - `:agent_id` — agent ID for capability authorization. Required unless
    `skip_auth: true`; omitting it returns `{:error, :missing_agent_id}`.
  - `:skip_auth` — skip capability check (default: false). Only the literal
    `true` skips; this is the sole bypass.

  ## Errors

  - `{:error, :missing_agent_id}` — no agent id and no explicit `skip_auth: true`.
  - `{:error, :unauthorized, reason}` — the agent lacks the tool capability.
  - `{:error, {:not_connected, server_name}}` — no connection exists for the
    server.
  - `{:error, %Arbor.Contracts.Tool.CallFailure{}}` — the call reached the
    connection and failed; `outcome` says whether it may have taken effect
    (see `Arbor.Gateway.MCP.ClientConnection.call_tool/4`).
  """
  @spec call_mcp_tool(String.t(), String.t(), map(), keyword()) ::
          {:ok, map()}
          | {:error,
             :missing_agent_id
             | {:not_connected, String.t()}
             | Arbor.Contracts.Tool.CallFailure.t()}
          | {:error, :unauthorized, term()}
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
    |> Enum.flat_map(fn
      {name, pid, :connected} ->
        case ClientConnection.list_resources(pid) do
          {:ok, resources} -> ResourceBridge.to_arbor_resources(name, resources)
          _ -> []
        end

      # A disconnected/unhealthy server (e.g. retrying with backoff) must not
      # take down the listing for every other server (Imp review D7).
      _not_connected ->
        []
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
  - `:agent_id` — agent ID for capability authorization. Required unless
    `skip_auth: true`; omitting it returns `{:error, :missing_agent_id}`.
  - `:skip_auth` — skip capability check (default: false). Only the literal
    `true` skips; this is the sole bypass.
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

  # -- Agent MCP Endpoints (BEAM-local agent-to-agent) --

  @doc """
  Start an MCP endpoint for an agent, exposing its actions as MCP tools.

  Other agents can then connect via ExMCP's BEAM-local transport
  for zero-serialization agent-to-agent communication.

  ## Options

  - `:actions` — list of action modules to expose (default: all available)
  - `:signed_request` — typed proof signed over
    `agent_endpoint_authentication_payload/1`; tool execution fails closed
    without a verified proof
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
  Return the exact payload an agent must sign to authenticate an MCP endpoint.

  This function returns only the public challenge text. It does not load a key,
  sign on behalf of a scalar agent id, or grant action authority.
  """
  @spec agent_endpoint_authentication_payload(String.t()) :: String.t()
  def agent_endpoint_authentication_payload(agent_id) do
    AgentEndpoint.authentication_payload(agent_id)
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

  Uses ExMCP's BEAM-local transport for zero-serialization
  communication. Returns an `ExMCP.Client` pid that can be used with
  `ExMCP.Client.call_tool/3`, `ExMCP.Client.list_tools/1`, etc.
  """
  @spec connect_to_agent(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def connect_to_agent(target_agent_id, _opts \\ []) do
    case EndpointRegistry.lookup(target_agent_id) do
      {:ok, endpoint_pid, _tools} ->
        ExMCP.Client.start_link(
          transport: :beam,
          server: endpoint_pid,
          protocol_mode: :legacy_only
        )

      :error ->
        {:error, {:agent_endpoint_not_found, target_agent_id}}
    end
  end

  # -- Private helpers --

  # Imp review D7 (2026-09-28): an agent-bound connection spawns the configured
  # command or dials the configured URL as that agent, so it needs the
  # operator's exact approval of this config. Before this, any mcp_servers entry
  # in profile metadata was connected unchecked on the agent's next start. The
  # check uses the kernel Security.authorize (no trust JIT-minting), so only an
  # explicit grant approves. A crash while checking denies.
  defp authorize_mcp_server_connect(server_name, config) do
    case Map.get(config, :agent_id) || Map.get(config, "agent_id") do
      nil ->
        :ok

      agent_id when is_binary(agent_id) and agent_id != "" ->
        with {:ok, uri} <- Arbor.Security.mcp_server_approval_uri(server_name, config),
             {:ok, :authorized} <-
               Arbor.Security.authorize(agent_id, uri, :execute, verify_identity: false) do
          :ok
        else
          _denied -> {:error, :mcp_server_not_approved}
        end

      _malformed ->
        {:error, :mcp_server_not_approved}
    end
  rescue
    _ -> {:error, :mcp_server_not_approved}
  catch
    _, _ -> {:error, :mcp_server_not_approved}
  end

  # FAIL CLOSED (Imp review D2, 2026-09-27): only an explicit `skip_auth: true`
  # bypasses the capability check. A missing or blank `:agent_id` is a denial,
  # never an implicit skip — the old `nil -> :ok` clause let any caller that
  # dropped the option reach an external MCP server with no authorization.
  defp maybe_authorize(_agent_id, _server, _tool, true), do: :ok

  defp maybe_authorize(agent_id, server_name, tool_name, _skip)
       when is_binary(agent_id) and agent_id != "" do
    ToolBridge.authorize(agent_id, server_name, tool_name)
  end

  defp maybe_authorize(_agent_id, _server, _tool, _skip), do: {:error, :missing_agent_id}

  defp find_connection(server_name) do
    case ClientSupervisor.find_connection(server_name) do
      {:ok, pid} -> {:ok, pid}
      :error -> {:error, {:not_connected, server_name}}
    end
  end

  # Same fail-closed rule as maybe_authorize/4 (Imp review D2).
  defp maybe_authorize_resource(_agent_id, _server, _resource, true), do: :ok

  defp maybe_authorize_resource(agent_id, server_name, resource_name, _skip)
       when is_binary(agent_id) and agent_id != "" do
    ResourceBridge.authorize(agent_id, server_name, resource_name)
  end

  defp maybe_authorize_resource(_agent_id, _server, _resource, _skip),
    do: {:error, :missing_agent_id}

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
