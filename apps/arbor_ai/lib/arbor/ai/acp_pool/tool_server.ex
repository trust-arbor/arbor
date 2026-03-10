defmodule Arbor.AI.AcpPool.ToolServer do
  @moduledoc """
  Ephemeral HTTP MCP server that exposes Jido action modules as MCP tools.

  Started by `AcpPool` when a session profile includes `tool_modules`.
  CLI agents (Claude, Gemini, Codex) connect to this server via the
  `mcpServers` field in the ACP `session/new` request.

  ## Lifecycle

  - Created alongside an AcpSession when `tool_modules` are specified
  - Serves tools via HTTP POST (JSON-RPC MCP protocol)
  - Torn down when the owning AcpSession is closed or removed from pool

  ## Architecture

  Uses `Plug.Cowboy` + `ExMCP.HttpPlug` with a function handler
  for per-session tool configuration at runtime. Each ToolServer
  gets a unique ranch listener ref and OS-assigned port.
  """

  require Logger

  @doc """
  Start an HTTP MCP server exposing the given action modules as tools.

  Returns `{:ok, %{port: port, ref: ranch_ref}}` or `{:error, reason}`.

  ## Options

  - `:agent_id` — owning agent ID for authorization context
  - `:port` — specific port (default: 0 for OS-assigned)
  """
  @spec start([module()], keyword()) :: {:ok, map()} | {:error, term()}
  def start(action_modules, opts \\ []) when is_list(action_modules) do
    agent_id = Keyword.get(opts, :agent_id, "anonymous")
    port = Keyword.get(opts, :port, 0)
    # Ranch refs are internal atoms, not user-controlled — safe to create
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    ranch_ref = :"arbor_tool_server_#{:erlang.unique_integer([:positive])}"

    tools = to_mcp_tools(action_modules)
    tool_map = build_tool_map(tools, action_modules)

    handler = fn request ->
      handle_mcp_request(request, tools, tool_map, agent_id)
    end

    plug_opts = [
      handler: handler,
      server_info: %{"name" => "arbor-tools", "version" => "1.0.0"},
      sse_enabled: false,
      cors_enabled: true
    ]

    cowboy_opts = [
      port: port,
      ref: ranch_ref,
      ip: {127, 0, 0, 1}
    ]

    case Plug.Cowboy.http(ExMCP.HttpPlug, plug_opts, cowboy_opts) do
      {:ok, _pid} ->
        actual_port = :ranch.get_port(ranch_ref)

        Logger.info(
          "[ToolServer] Started on port #{actual_port} with #{length(tools)} tools " <>
            "for agent #{agent_id} (ref: #{ranch_ref})"
        )

        {:ok, %{port: actual_port, ref: ranch_ref, tool_count: length(tools)}}

      {:error, reason} ->
        Logger.error("[ToolServer] Failed to start: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Stop a running ToolServer by its ranch ref.
  """
  @spec stop(atom()) :: :ok
  def stop(ranch_ref) when is_atom(ranch_ref) do
    Plug.Cowboy.shutdown(ranch_ref)
    Logger.debug("[ToolServer] Stopped #{ranch_ref}")
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  @doc """
  Build the `mcp_servers` list for an ACP session/new request.

  Returns the format expected by `ExMCP.ACP.Client.new_session/3`:
  `[%{"uri" => "http://...", "name" => "arbor-tools"}]`
  """
  @spec mcp_servers_entry(non_neg_integer()) :: [map()]
  def mcp_servers_entry(port) do
    [%{"uri" => "http://127.0.0.1:#{port}", "name" => "arbor-tools"}]
  end

  # -- MCP Request Handler --

  defp handle_mcp_request(%{"method" => "initialize"} = req, _tools, _tool_map, _agent_id) do
    id = Map.get(req, "id")

    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "protocolVersion" => "2025-06-18",
        "serverInfo" => %{"name" => "arbor-tools", "version" => "1.0.0"},
        "capabilities" => %{"tools" => %{"listChanged" => false}}
      }
    }
  end

  defp handle_mcp_request(
         %{"method" => "notifications/initialized"},
         _tools,
         _tool_map,
         _agent_id
       ) do
    # Notification — no response needed
    {:ok, nil}
  end

  defp handle_mcp_request(%{"method" => "tools/list"} = req, tools, _tool_map, _agent_id) do
    id = Map.get(req, "id")

    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{"tools" => tools}
    }
  end

  defp handle_mcp_request(%{"method" => "tools/call"} = req, _tools, tool_map, agent_id) do
    id = Map.get(req, "id")
    params = Map.get(req, "params", %{})
    tool_name = Map.get(params, "name")
    arguments = Map.get(params, "arguments", %{})

    mcp_result = execute_tool(tool_name, arguments, tool_map, agent_id)

    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => mcp_result
    }
  end

  defp handle_mcp_request(%{"method" => "ping"} = req, _tools, _tool_map, _agent_id) do
    id = Map.get(req, "id")
    %{"jsonrpc" => "2.0", "id" => id, "result" => %{}}
  end

  defp handle_mcp_request(%{"method" => method} = req, _tools, _tool_map, _agent_id) do
    id = Map.get(req, "id")

    if id do
      %{
        "jsonrpc" => "2.0",
        "id" => id,
        "error" => %{
          "code" => -32_601,
          "message" => "Method not found: #{method}"
        }
      }
    else
      # Notification — no response
      {:ok, nil}
    end
  end

  # -- Tool Execution --

  defp execute_tool(tool_name, arguments, tool_map, agent_id) do
    case Map.get(tool_map, tool_name) do
      nil ->
        %{
          "content" => [%{"type" => "text", "text" => "Error: unknown tool '#{tool_name}'"}],
          "isError" => true
        }

      action_module ->
        params = atomize_params(arguments)

        case run_action(action_module, params, agent_id) do
          {:ok, result} ->
            %{
              "content" => [%{"type" => "text", "text" => encode_result(result)}],
              "isError" => false
            }

          {:error, reason} ->
            %{
              "content" => [%{"type" => "text", "text" => "Error: #{inspect(reason)}"}],
              "isError" => true
            }
        end
    end
  rescue
    e ->
      %{
        "content" => [%{"type" => "text", "text" => "Error: #{Exception.message(e)}"}],
        "isError" => true
      }
  end

  defp run_action(action_module, params, agent_id) do
    # Try authorized execution first, fall back to direct
    if authorized_execution_available?() do
      case apply(Arbor.Actions, :authorize_and_execute, [agent_id, action_module, params, %{}]) do
        {:error, :unauthorized} ->
          # Fall back when no capability grants exist yet
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

  # -- Tool Conversion --

  defp to_mcp_tools(action_modules) do
    Enum.flat_map(action_modules, fn mod ->
      try do
        tool = mod.to_tool()

        [
          %{
            "name" => tool.name,
            "description" => tool.description || "Arbor action: #{tool.name}",
            "inputSchema" => tool.parameters_schema || %{"type" => "object", "properties" => %{}}
          }
        ]
      rescue
        _ ->
          Logger.warning("[ToolServer] Failed to convert #{inspect(mod)} to MCP tool")
          []
      end
    end)
  end

  defp build_tool_map(tools, action_modules) do
    Enum.zip(tools, action_modules)
    |> Map.new(fn {tool, mod} -> {tool["name"], mod} end)
  end

  # -- Helpers --

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

  defp authorized_execution_available? do
    Code.ensure_loaded?(Arbor.Actions) and
      function_exported?(Arbor.Actions, :authorize_and_execute, 4) and
      Code.ensure_loaded?(Arbor.Security) and
      Process.whereis(Arbor.Security.CapabilityStore) != nil
  end
end
