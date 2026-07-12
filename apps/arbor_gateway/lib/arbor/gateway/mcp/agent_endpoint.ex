defmodule Arbor.Gateway.MCP.AgentEndpoint do
  @moduledoc """
  MCP server endpoint that exposes an Arbor agent's actions as MCP tools.

  This is a lightweight GenServer that implements the MCP protocol over
  ExMCP's BEAM-local transport (`:beam`), enabling agent-to-agent
  communication via MCP.

  ## Usage

      # Start an endpoint exposing specific actions
      {:ok, pid} = AgentEndpoint.start_link(
        agent_id: "agent_001",
        actions: [Arbor.Actions.File.Read, Arbor.Actions.Shell.Execute]
      )

      # Another agent connects as MCP client
      {:ok, client} = ExMCP.Client.start_link(
        transport: :beam,
        server: pid
      )

      # Call the agent's action through MCP
      {:ok, result} = ExMCP.Client.call_tool(client, "file_read", %{"path" => "/tmp/test"})

  ## Architecture

  Uses direct Erlang message passing without JSON serialization overhead.
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

  alias Arbor.Contracts.Security.{AuthContext, SignedRequest}
  alias Arbor.Gateway.MCP.{ActionBridge, EndpointRegistry}
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

  @doc false
  @spec authentication_payload(String.t()) :: String.t()
  def authentication_payload(agent_id) when is_binary(agent_id) do
    "arbor://gateway/agent-endpoint/authenticate/#{agent_id}"
  end

  # -- GenServer Callbacks --

  @impl true
  def init(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)

    with {:ok, auth_context} <-
           authenticate_endpoint(agent_id, Keyword.get(opts, :signed_request)) do
      action_modules = Keyword.get(opts, :actions) || discover_all_actions()
      tools = ActionBridge.to_mcp_tools(action_modules)

      # Build module lookup: tool_name -> action_module
      tool_map =
        Enum.zip(tools, action_modules)
        |> Map.new(fn {tool, mod} -> {tool["name"], mod} end)

      state = %{
        agent_id: agent_id,
        auth_context: auth_context,
        tools: tools,
        tool_map: tool_map,
        action_modules: action_modules,
        client_pid: nil,
        initialized: false
      }

      Logger.debug("[AgentEndpoint] Started for #{agent_id} with #{length(tools)} tools")

      {:ok, state}
    else
      {:error, reason} -> {:stop, {:endpoint_authentication_failed, reason}}
    end
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
      initialized: state.initialized,
      authenticated: match?(%AuthContext{identity_verified: true}, state.auth_context)
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
        execute_action(action_module, params, state)
    end
  rescue
    e ->
      {:error, Exception.message(e)}
  catch
    :exit, reason ->
      {:error, {:exit, reason}}
  end

  # Execute action through authorize_and_execute — no unauthenticated fallback.
  # If auth fails, the error propagates to the MCP client.
  defp execute_action(action_module, params, %{agent_id: agent_id} = state) do
    with {:ok, context} <- verify_endpoint_principal(state) do
      Arbor.Actions.authorize_and_execute(agent_id, action_module, params, context)
    end
  rescue
    e ->
      Logger.warning("[MCP AgentEndpoint] Action execution error: #{Exception.message(e)}")
      {:error, {:execution_error, Exception.message(e)}}
  catch
    :exit, reason ->
      Logger.warning("[MCP AgentEndpoint] Action execution exit: #{inspect(reason)}")
      {:error, {:execution_exit, reason}}
  end

  defp verify_endpoint_principal(%{agent_id: agent_id} = state) do
    with {:ok, endpoint_pid, _tools} when endpoint_pid == self() <-
           EndpointRegistry.lookup(agent_id),
         {:ok, context} <- authenticated_action_context(state) do
      {:ok, context}
    else
      {:ok, _other_pid, _tools} -> {:error, :endpoint_principal_unbound}
      :error -> {:error, :endpoint_principal_unbound}
      {:error, _reason} = error -> error
    end
  end

  defp authenticated_action_context(%{
         agent_id: agent_id,
         auth_context:
           %AuthContext{
             principal_id: agent_id,
             identity_verified: true,
             signed_request: %SignedRequest{agent_id: agent_id} = signed_request
           } = auth_context
       }) do
    {:ok, %{agent_id: agent_id, signed_request: signed_request, auth_context: auth_context}}
  end

  defp authenticated_action_context(_state), do: {:error, :endpoint_authentication_required}

  defp authenticate_endpoint(_agent_id, nil), do: {:ok, nil}

  defp authenticate_endpoint(agent_id, %SignedRequest{} = signed_request) do
    expected_payload = authentication_payload(agent_id)

    with :ok <- validate_endpoint_request(signed_request, agent_id, expected_payload),
         {:ok, ^agent_id} <- Arbor.Security.verify_request(signed_request) do
      auth_context =
        AuthContext.new(agent_id, signed_request: signed_request)
        |> AuthContext.mark_verified()

      {:ok, auth_context}
    else
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_endpoint_signed_request}
    end
  end

  defp authenticate_endpoint(_agent_id, _signed_request),
    do: {:error, :invalid_endpoint_signed_request}

  defp validate_endpoint_request(
         %SignedRequest{agent_id: agent_id, payload: payload},
         agent_id,
         payload
       ),
       do: :ok

  defp validate_endpoint_request(_signed_request, _agent_id, _payload),
    do: {:error, :endpoint_signed_request_mismatch}

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
    Arbor.Actions.all_actions()
  rescue
    e ->
      Logger.debug("[AgentEndpoint] discover_all_actions failed: #{Exception.message(e)}")
      []
  catch
    :exit, reason ->
      Logger.debug("[AgentEndpoint] discover_all_actions exited: #{inspect(reason)}")
      []
  end
end
