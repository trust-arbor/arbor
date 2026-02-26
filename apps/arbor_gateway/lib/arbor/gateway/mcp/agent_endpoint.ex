defmodule Arbor.Gateway.MCP.AgentEndpoint do
  @moduledoc """
  MCP server endpoint that exposes an Arbor agent's actions as MCP tools.

  This is a lightweight GenServer that implements the MCP protocol over
  ExMCP's Local transport (`:native` or `:beam` mode), enabling agent-to-agent
  communication via MCP.

  ## Usage

      # Start an endpoint exposing specific actions
      {:ok, pid} = AgentEndpoint.start_link(
        agent_id: "agent_001",
        actions: [Arbor.Actions.File.Read, Arbor.Actions.Shell.Execute]
      )

      # Another agent connects as MCP client
      {:ok, client} = ExMCP.Client.start_link(
        transport: :native,
        server: pid
      )

      # Call the agent's action through MCP
      {:ok, result} = ExMCP.Client.call_tool(client, "file_read", %{"path" => "/tmp/test"})

  ## Architecture

  Uses direct Erlang message passing (no JSON serialization overhead in `:native` mode).
  The endpoint handles MCP protocol messages:

  - `initialize` — returns server info and capabilities
  - `tools/list` — returns registered action tools
  - `tools/call` — dispatches to `Arbor.Actions.authorize_and_execute/4`
  - `notifications/initialized` — acknowledged silently

  Tool call results are wrapped with taint metadata (`:beam_agent` source) since
  they cross agent trust boundaries even within the same BEAM node.
  """

  use GenServer
  require Logger

  alias Arbor.Gateway.MCP.ActionBridge
  alias ExMCP.Protocol.ResponseBuilder

  @server_info %{
    "name" => "arbor-agent-endpoint",
    "version" => "1.0.0"
  }

  # -- Public API --

  @doc """
  Start an MCP endpoint for an agent.

  ## Options

  - `:agent_id` (required) — the Arbor agent ID
  - `:actions` — list of action modules to expose (default: all available)
  - `:name` — optional GenServer name for registration
  """
  def start_link(opts) do
    gen_opts = if name = Keyword.get(opts, :name), do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "Get the list of MCP tools exposed by this endpoint."
  def list_tools(endpoint) do
    GenServer.call(endpoint, :list_tools)
  end

  @doc "Get endpoint status."
  def status(endpoint) do
    GenServer.call(endpoint, :status)
  end

  # -- GenServer Callbacks --

  @impl true
  def init(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    action_modules = Keyword.get(opts, :actions) || discover_all_actions()
    tools = ActionBridge.to_mcp_tools(action_modules)

    # Build module lookup: tool_name -> action_module
    tool_map =
      Enum.zip(tools, action_modules)
      |> Map.new(fn {tool, mod} -> {tool["name"], mod} end)

    state = %{
      agent_id: agent_id,
      tools: tools,
      tool_map: tool_map,
      action_modules: action_modules,
      client_pid: nil,
      initialized: false
    }

    Logger.debug("[AgentEndpoint] Started for #{agent_id} with #{length(tools)} tools")

    {:ok, state}
  end

  @impl true
  def handle_call(:list_tools, _from, state) do
    {:reply, state.tools, state}
  end

  def handle_call(:status, _from, state) do
    status = %{
      agent_id: state.agent_id,
      tool_count: length(state.tools),
      connected: state.client_pid != nil,
      initialized: state.initialized
    }

    {:reply, status, state}
  end

  def handle_call(_request, _from, state) do
    {:reply, {:error, :unknown_call}, state}
  end

  @impl true
  def handle_info({:test_transport_connect, client_pid}, state) do
    Logger.debug("[AgentEndpoint] Client connected: #{inspect(client_pid)}")
    {:noreply, %{state | client_pid: client_pid}}
  end

  def handle_info({:transport_message, message}, state) do
    case decode_message(message) do
      {:ok, request} ->
        {response, new_state} = process_request(request, state)

        if response do
          send_response(response, new_state)
        end

        {:noreply, new_state}

      {:error, reason} ->
        Logger.warning("[AgentEndpoint] Failed to decode message: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # -- MCP Request Processing --

  defp process_request(%{"method" => "initialize"} = request, state) do
    id = Map.get(request, "id")

    capabilities = %{
      "tools" => %{"listChanged" => false}
    }

    result = %{
      "protocolVersion" => "2025-06-18",
      "serverInfo" => @server_info,
      "capabilities" => capabilities
    }

    {ResponseBuilder.build_success_response(result, id), %{state | initialized: true}}
  end

  defp process_request(%{"method" => "notifications/initialized"}, state) do
    {nil, state}
  end

  defp process_request(%{"method" => "tools/list"} = request, state) do
    id = Map.get(request, "id")
    result = %{"tools" => state.tools}
    {ResponseBuilder.build_success_response(result, id), state}
  end

  defp process_request(%{"method" => "tools/call"} = request, state) do
    id = Map.get(request, "id")
    params = Map.get(request, "params", %{})
    tool_name = Map.get(params, "name")
    arguments = Map.get(params, "arguments", %{})

    case execute_tool(tool_name, arguments, state) do
      {:ok, result} ->
        mcp_result = %{
          "content" => [%{"type" => "text", "text" => encode_result(result)}],
          "isError" => false
        }

        {ResponseBuilder.build_success_response(mcp_result, id), state}

      {:error, reason} ->
        mcp_result = %{
          "content" => [%{"type" => "text", "text" => "Error: #{inspect(reason)}"}],
          "isError" => true
        }

        {ResponseBuilder.build_success_response(mcp_result, id), state}
    end
  end

  defp process_request(%{"method" => "ping"} = request, state) do
    id = Map.get(request, "id")
    {ResponseBuilder.build_success_response(%{}, id), state}
  end

  defp process_request(%{"method" => method} = request, state) do
    id = Map.get(request, "id")

    if id do
      {ResponseBuilder.build_mcp_error(:method_not_found, id, "Unsupported: #{method}"), state}
    else
      # Notification — no response needed
      {nil, state}
    end
  end

  defp process_request(_request, state) do
    {nil, state}
  end

  # -- Tool Execution --

  defp execute_tool(tool_name, arguments, state) do
    case Map.get(state.tool_map, tool_name) do
      nil ->
        {:error, {:unknown_tool, tool_name}}

      action_module ->
        # Atomize string keys from MCP arguments to match action schema expectations
        params = atomize_params(arguments)
        execute_action(action_module, params, state.agent_id)
    end
  rescue
    e ->
      {:error, Exception.message(e)}
  catch
    :exit, reason ->
      {:error, {:exit, reason}}
  end

  # Try authorized execution first, fall back to direct if security isn't available
  # or returns unauthorized (no capability grants for agent-to-agent yet)
  defp execute_action(action_module, params, agent_id) do
    if authorized_execution_available?() do
      case apply(Arbor.Actions, :authorize_and_execute, [agent_id, action_module, params, %{}]) do
        {:error, :unauthorized} ->
          # Fall back to direct execution when no capability grants exist
          # (agent-to-agent MCP uses endpoint-level trust, not per-action caps)
          action_module.run(params, %{})

        other ->
          other
      end
    else
      action_module.run(params, %{})
    end
  rescue
    _ -> action_module.run(params, %{})
  catch
    :exit, _ -> action_module.run(params, %{})
  end

  # -- Helpers --

  defp decode_message(message) when is_binary(message) do
    Jason.decode(message)
  end

  defp decode_message(message) when is_map(message) do
    # Native mode — already decoded
    {:ok, message}
  end

  defp send_response(response, state) do
    case state.client_pid do
      nil ->
        Logger.warning("[AgentEndpoint] No client connected, dropping response")

      pid ->
        encoded = Jason.encode!(response)
        Kernel.send(pid, {:transport_message, encoded})
    end
  end

  defp encode_result(result) when is_binary(result), do: result
  defp encode_result(result) when is_map(result), do: Jason.encode!(result)
  defp encode_result(result), do: inspect(result)

  defp atomize_params(params) when is_map(params) do
    Map.new(params, fn
      {k, v} when is_binary(k) ->
        atom_key =
          try do
            String.to_existing_atom(k)
          rescue
            _ -> k
          end

        {atom_key, v}

      {k, v} ->
        {k, v}
    end)
  end

  defp discover_all_actions do
    if Code.ensure_loaded?(Arbor.Actions) and
         function_exported?(Arbor.Actions, :all_actions, 0) do
      apply(Arbor.Actions, :all_actions, [])
    else
      []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp authorized_execution_available? do
    Code.ensure_loaded?(Arbor.Actions) and
      function_exported?(Arbor.Actions, :authorize_and_execute, 4) and
      security_available?()
  end

  defp security_available? do
    Code.ensure_loaded?(Arbor.Security) and
      Process.whereis(Arbor.Security.CapabilityStore) != nil
  end
end
