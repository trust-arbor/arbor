defmodule Arbor.AI.AcpPool.ToolServer do
  @moduledoc """
  Ephemeral HTTP MCP server that exposes Jido action modules as MCP tools.

  Started by `AcpPool` when a session profile includes `tool_modules`.
  CLI agents (Claude, Gemini, Codex) connect to this server via the
  `mcpServers` field in the ACP `session/new` request. The emitted entry uses
  the standard ACP HTTP descriptor with string keys.

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
  - `:workspace` — directory the agent's session is bound to. Passed in
    the per-call `context[:workspace]` so file actions can scope path
    resolution + prevent traversal escapes outside the workspace.
  - `:port` — specific port (default: 0 for OS-assigned)
  - `:bind` — IP to bind to (default: `{127, 0, 0, 1}`; use `{0, 0, 0, 0}` for remote access)
  """
  @spec start([module()], keyword()) :: {:ok, map()} | {:error, term()}
  def start(action_modules, opts \\ []) when is_list(action_modules) do
    agent_id = Keyword.get(opts, :agent_id, "anonymous")
    workspace = Keyword.get(opts, :workspace)
    port = Keyword.get(opts, :port, 0)
    bind_ip = Keyword.get(opts, :bind, {127, 0, 0, 1})
    # Ranch refs are internal atoms, not user-controlled — safe to create
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    ranch_ref = :"arbor_tool_server_#{:erlang.unique_integer([:positive])}"

    tools = to_mcp_tools(action_modules)
    tool_map = build_tool_map(tools, action_modules)
    exec_context = build_exec_context(workspace)

    handler = fn request ->
      handle_mcp_request(request, tools, tool_map, agent_id, exec_context)
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
      ip: bind_ip
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
        Logger.error("[ToolServer] Failed to start: #{Arbor.LLM.inspect_external_reason(reason)}")
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
  `[%{"type" => "http", "name" => "arbor-tools", "url" => "http://...", "headers" => []}]`

  Pass a `host` option for remote-accessible servers (default: "127.0.0.1").
  """
  @spec mcp_servers_entry(non_neg_integer(), keyword()) :: [map()]
  def mcp_servers_entry(port, opts \\ []) do
    host = Keyword.get(opts, :host, "127.0.0.1")

    [
      %{
        "type" => "http",
        "name" => "arbor-tools",
        "url" => "http://#{host}:#{port}",
        "headers" => []
      }
    ]
  end

  # -- MCP Request Handler --

  defp handle_mcp_request(
         %{"method" => "initialize"} = req,
         _tools,
         _tool_map,
         _agent_id,
         _exec_context
       ) do
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
         _agent_id,
         _exec_context
       ) do
    # Notification — no response needed
    {:ok, nil}
  end

  defp handle_mcp_request(
         %{"method" => "tools/list"} = req,
         tools,
         _tool_map,
         _agent_id,
         _exec_context
       ) do
    id = Map.get(req, "id")

    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{"tools" => tools}
    }
  end

  defp handle_mcp_request(
         %{"method" => "tools/call"} = req,
         _tools,
         tool_map,
         agent_id,
         exec_context
       ) do
    id = Map.get(req, "id")
    params = Map.get(req, "params", %{})
    tool_name = Map.get(params, "name")
    arguments = Map.get(params, "arguments", %{})

    mcp_result = execute_tool(tool_name, arguments, tool_map, agent_id, exec_context)

    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => mcp_result
    }
  end

  defp handle_mcp_request(
         %{"method" => "ping"} = req,
         _tools,
         _tool_map,
         _agent_id,
         _exec_context
       ) do
    id = Map.get(req, "id")
    %{"jsonrpc" => "2.0", "id" => id, "result" => %{}}
  end

  defp handle_mcp_request(
         %{"method" => method} = req,
         _tools,
         _tool_map,
         _agent_id,
         _exec_context
       ) do
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

  defp execute_tool(tool_name, arguments, tool_map, agent_id, exec_context) do
    case Map.get(tool_map, tool_name) do
      nil ->
        %{
          "content" => [%{"type" => "text", "text" => "Error: unknown tool '#{tool_name}'"}],
          "isError" => true
        }

      action_module ->
        params = atomize_params(arguments)

        case run_action(action_module, params, agent_id, exec_context) do
          {:ok, result} ->
            %{
              "content" => [%{"type" => "text", "text" => encode_result(result)}],
              "isError" => false
            }

          {:error, reason} ->
            %{
              "content" => [%{"type" => "text", "text" => "Error: #{bounded_reason(reason)}"}],
              "isError" => true
            }
        end
    end
  rescue
    e ->
      %{
        "content" => [
          %{"type" => "text", "text" => "Error: #{Arbor.LLM.external_exception_message(e)}"}
        ],
        "isError" => true
      }
  catch
    kind, reason ->
      %{
        "content" => [%{"type" => "text", "text" => "Error: #{kind}: #{bounded_reason(reason)}"}],
        "isError" => true
      }
  end

  defp run_action(action_module, params, agent_id, exec_context) do
    case Application.get_env(:arbor_ai, :acp_action_runner) do
      fun when is_function(fun, 4) ->
        # DI seam: a configured runner stands in for the authorize-and-execute
        # path. Used by tests to exercise MCP plumbing without the full
        # arbor_security/arbor_actions stack (arbor_actions is L6 and not a dep
        # of arbor_ai, so it can't be loaded in this lib's isolated test env).
        # Production leaves this unset.
        run_via_runner(fun, action_module, params, agent_id, exec_context)

      _ ->
        authorized_run(action_module, params, agent_id, exec_context)
    end
  end

  defp run_via_runner(fun, action_module, params, agent_id, exec_context) do
    fun.(action_module, params, agent_id, exec_context)
  rescue
    e -> {:error, {:action_runner_error, Arbor.LLM.external_exception_message(e)}}
  catch
    kind, reason ->
      {:error, {:action_runner_failure, kind, Arbor.LLM.sanitize_external_reason(reason)}}
  end

  # SECURITY (codex authz.acp-toolserver-direct-fallback, HIGH): the ONLY way an
  # action may execute here is a SUCCESSFUL Arbor.Actions.authorize_and_execute/4
  # (it authorizes AND runs the action). Pre-fix, FOUR branches fell through to a
  # direct action_module.run/2: an explicit {:error, :unauthorized} denial, an
  # unavailable security subsystem, and any rescue/catch from the auth wrapper.
  # Each was a full capability bypass — a spawned CLI agent (whose tools reach
  # this server) could run any exposed Jido action with NO grant, and the
  # fallback context didn't even carry agent_id. We now fail closed in every
  # non-authorized case and never call action_module.run/2 directly. This means
  # ACP tools require the security subsystem to be available (the default
  # posture); a denial or an unavailable subsystem returns an error to the
  # caller instead of silently executing.
  defp authorized_run(action_module, params, agent_id, exec_context) do
    if authorized_execution_available?() do
      # exec_context carries workspace + any other per-handler context built at
      # ToolServer.start/2 (taint policy is auto-injected by authorize_and_execute
      # from config — not threaded here).
      apply(Arbor.Actions, :authorize_and_execute, [
        agent_id,
        action_module,
        params,
        exec_context
      ])
    else
      {:error, :security_unavailable}
    end
  rescue
    e -> {:error, {:authorization_error, Arbor.LLM.external_exception_message(e)}}
  catch
    kind, reason ->
      {:error, {:authorization_failure, kind, Arbor.LLM.sanitize_external_reason(reason)}}
  end

  # Per-handler context that flows into each tool call. Workspace scopes
  # file actions; absence means "no workspace constraint". Add fields
  # here as more action subsystems need per-session context.
  defp build_exec_context(nil), do: %{}
  defp build_exec_context(workspace) when is_binary(workspace), do: %{workspace: workspace}
  defp build_exec_context(_), do: %{}

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
          Logger.warning(
            "[ToolServer] Failed to convert #{Arbor.LLM.inspect_external_reason(mod)} to MCP tool"
          )

          []
      catch
        _kind, _reason ->
          []
      end
    end)
  end

  defp build_tool_map(tools, action_modules) do
    Enum.zip(tools, action_modules)
    |> Map.new(fn {tool, mod} -> {tool["name"], mod} end)
  end

  # -- Helpers --

  defp encode_result(result) when is_binary(result) and byte_size(result) <= 65_536,
    do: String.replace_invalid(result, "")

  defp encode_result(result) when is_binary(result), do: bounded_reason(result)

  defp encode_result(result) when is_map(result) do
    with :ok <-
           Arbor.LLM.validate_decoded_term(result,
             max_bytes: 65_536,
             max_nodes: 2_000,
             max_depth: 16,
             max_map_keys: 512,
             max_list_items: 2_000
           ),
         {:ok, encoded} <- Jason.encode(result),
         true <- byte_size(encoded) <= 65_536 do
      encoded
    else
      _invalid -> bounded_reason(result)
    end
  rescue
    _exception -> bounded_reason(result)
  catch
    _kind, _reason -> bounded_reason(result)
  end

  defp encode_result(result), do: bounded_reason(result)

  defp bounded_reason(reason), do: Arbor.LLM.inspect_external_reason(reason)

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
