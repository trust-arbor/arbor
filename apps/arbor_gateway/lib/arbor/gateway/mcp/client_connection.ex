defmodule Arbor.Gateway.MCP.ClientConnection do
  @moduledoc """
  Supervised GenServer wrapping an ExMCP.Client connection to an external MCP server.

  Handles:
  - Connection lifecycle (connect, health check, reconnect on failure)
  - Tool discovery and caching
  - Tool invocation with timeout handling
  - Status reporting

  ## State

  The connection maintains a cached tool list that is refreshed on connect
  and can be manually refreshed via `refresh_tools/1`.
  """

  use GenServer

  require Logger

  @health_check_interval 30_000
  @default_timeout 30_000

  defstruct [
    :server_name,
    :config,
    :client_pid,
    :agent_id,
    connection_status: :disconnected,
    tools: [],
    resources: [],
    server_info: nil,
    last_error: nil,
    connect_attempts: 0
  ]

  # -- Child spec for DynamicSupervisor --

  def child_spec(config) do
    %{
      id: {__MODULE__, config.server_name},
      start: {__MODULE__, :start_link, [config]},
      restart: :transient,
      shutdown: 5_000
    }
  end

  def start_link(config) do
    GenServer.start_link(__MODULE__, config)
  end

  # -- Public API --

  @doc "Get full status of this connection."
  @spec status(pid()) :: {:ok, map()} | {:error, term()}
  def status(pid), do: GenServer.call(pid, :status)

  @doc "Get the server name for this connection."
  @spec server_name(pid()) :: String.t()
  def server_name(pid), do: GenServer.call(pid, :server_name)

  @doc "List discovered tools from the connected MCP server."
  @spec list_tools(pid()) :: {:ok, [map()]} | {:error, term()}
  def list_tools(pid), do: GenServer.call(pid, :list_tools)

  @doc "Call a tool on the connected MCP server."
  @spec call_tool(pid(), String.t(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def call_tool(pid, tool_name, arguments, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    GenServer.call(pid, {:call_tool, tool_name, arguments, timeout}, timeout + 5_000)
  end

  @doc "Refresh the cached tool list from the server."
  @spec refresh_tools(pid()) :: {:ok, [map()]} | {:error, term()}
  def refresh_tools(pid), do: GenServer.call(pid, :refresh_tools)

  @doc "List discovered resources from the connected MCP server."
  @spec list_resources(pid()) :: {:ok, [map()]} | {:error, term()}
  def list_resources(pid), do: GenServer.call(pid, :list_resources)

  @doc "Read a specific resource from the connected MCP server."
  @spec read_resource(pid(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def read_resource(pid, uri, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    GenServer.call(pid, {:read_resource, uri, timeout}, timeout + 5_000)
  end

  @doc "Refresh the cached resource list from the server."
  @spec refresh_resources(pid()) :: {:ok, [map()]} | {:error, term()}
  def refresh_resources(pid), do: GenServer.call(pid, :refresh_resources)

  @doc "Disconnect from the MCP server."
  @spec disconnect(pid()) :: :ok
  def disconnect(pid), do: GenServer.call(pid, :disconnect)

  # -- GenServer Callbacks --

  @impl true
  def init(config) do
    # Trap exits so linked ExMCP.Client crashes don't kill this GenServer
    Process.flag(:trap_exit, true)

    state = %__MODULE__{
      server_name: config.server_name,
      config: config,
      agent_id: Map.get(config, :agent_id)
    }

    # Connect asynchronously to avoid blocking supervisor
    send(self(), :connect)

    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      server_name: state.server_name,
      connection_status: state.connection_status,
      tool_count: length(state.tools),
      tools: Enum.map(state.tools, & &1["name"]),
      resource_count: length(state.resources),
      resources: Enum.map(state.resources, & &1["name"]),
      server_info: state.server_info,
      agent_id: state.agent_id,
      last_error: state.last_error,
      connect_attempts: state.connect_attempts
    }

    {:reply, {:ok, status}, state}
  end

  def handle_call(:server_name, _from, state) do
    {:reply, state.server_name, state}
  end

  def handle_call(:list_tools, _from, %{connection_status: :connected} = state) do
    {:reply, {:ok, state.tools}, state}
  end

  def handle_call(:list_tools, _from, state) do
    {:reply, {:error, {:not_connected, state.connection_status}}, state}
  end

  def handle_call({:call_tool, tool_name, arguments, timeout}, _from, state) do
    case state.connection_status do
      :connected ->
        result = do_call_tool(state.client_pid, tool_name, arguments, timeout)
        {:reply, result, state}

      other ->
        {:reply, {:error, {:not_connected, other}}, state}
    end
  end

  def handle_call(:list_resources, _from, %{connection_status: :connected} = state) do
    {:reply, {:ok, state.resources}, state}
  end

  def handle_call(:list_resources, _from, state) do
    {:reply, {:error, {:not_connected, state.connection_status}}, state}
  end

  def handle_call({:read_resource, uri, timeout}, _from, state) do
    case state.connection_status do
      :connected ->
        result = do_read_resource(state.client_pid, uri, timeout)
        {:reply, result, state}

      other ->
        {:reply, {:error, {:not_connected, other}}, state}
    end
  end

  def handle_call(:refresh_resources, _from, %{connection_status: :connected} = state) do
    case discover_resources(state.client_pid) do
      {:ok, resources} ->
        {:reply, {:ok, resources}, %{state | resources: resources}}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(:refresh_resources, _from, state) do
    {:reply, {:error, {:not_connected, state.connection_status}}, state}
  end

  def handle_call(:refresh_tools, _from, %{connection_status: :connected} = state) do
    case discover_tools(state.client_pid) do
      {:ok, tools} ->
        {:reply, {:ok, tools}, %{state | tools: tools}}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(:refresh_tools, _from, state) do
    {:reply, {:error, {:not_connected, state.connection_status}}, state}
  end

  def handle_call(:disconnect, _from, state) do
    new_state = do_disconnect(state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_info(:connect, state) do
    new_state = do_connect(state)
    {:noreply, new_state}
  end

  def handle_info(:health_check, %{connection_status: :connected} = state) do
    case ExMCP.Client.ping(state.client_pid, 5_000) do
      {:ok, _} ->
        schedule_health_check()
        {:noreply, state}

      {:error, reason} ->
        Logger.warning("[MCP:#{state.server_name}] Health check failed: #{inspect(reason)}")
        new_state = %{state | connection_status: :unhealthy, last_error: reason}
        send(self(), :reconnect)
        {:noreply, new_state}
    end
  end

  def handle_info(:health_check, state) do
    # Not connected — skip health check
    {:noreply, state}
  end

  def handle_info(:reconnect, state) do
    new_state = do_disconnect(state)
    send(self(), :connect)
    {:noreply, new_state}
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, %{client_pid: pid} = state) do
    Logger.warning("[MCP:#{state.server_name}] Client process died: #{inspect(reason)}")
    new_state = %{state | client_pid: nil, connection_status: :disconnected, last_error: reason}

    # Schedule reconnect with backoff
    delay = min(state.connect_attempts * 2_000, 30_000)
    Process.send_after(self(), :connect, delay)
    {:noreply, new_state}
  end

  # Handle EXIT from linked ExMCP.Client processes
  def handle_info({:EXIT, pid, reason}, %{client_pid: pid} = state) do
    Logger.warning("[MCP:#{state.server_name}] Client exited: #{inspect(reason)}")
    new_state = %{state | client_pid: nil, connection_status: :disconnected, last_error: reason}

    delay = min(state.connect_attempts * 2_000, 30_000)
    Process.send_after(self(), :connect, delay)
    {:noreply, new_state}
  end

  # Ignore EXIT from processes we don't track (e.g. spawned by ExMCP internally)
  def handle_info({:EXIT, _pid, _reason}, state) do
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("[MCP:#{state.server_name}] Unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    do_disconnect(state)
    :ok
  end

  # -- Private --

  defp do_connect(state) do
    state = %{state | connect_attempts: state.connect_attempts + 1}

    Logger.info("[MCP:#{state.server_name}] Connecting (attempt #{state.connect_attempts})...")

    client_opts = build_client_opts(state.config)

    case safe_start_client(client_opts) do
      {:ok, pid} ->
        Process.monitor(pid)

        # Discover tools if auto_discover is enabled (default: true)
        tools =
          if Map.get(state.config, :auto_discover, true) do
            case discover_tools(pid) do
              {:ok, tools} -> tools
              {:error, _} -> []
            end
          else
            []
          end

        # Discover resources if auto_discover is enabled
        resources =
          if Map.get(state.config, :auto_discover, true) do
            case discover_resources(pid) do
              {:ok, resources} -> resources
              {:error, _} -> []
            end
          else
            []
          end

        # Get server info
        server_info =
          case ExMCP.Client.server_info(pid) do
            {:ok, info} -> info
            _ -> nil
          end

        Logger.info(
          "[MCP:#{state.server_name}] Connected. #{length(tools)} tools, #{length(resources)} resources available."
        )

        safe_emit(:mcp_connected, %{
          server_name: state.server_name,
          tool_count: length(tools),
          tools: Enum.map(tools, & &1["name"]),
          resource_count: length(resources),
          resources: Enum.map(resources, & &1["name"])
        })

        schedule_health_check()

        %{
          state
          | client_pid: pid,
            connection_status: :connected,
            tools: tools,
            resources: resources,
            server_info: server_info,
            last_error: nil,
            connect_attempts: 0
        }

      {:error, reason} ->
        Logger.warning("[MCP:#{state.server_name}] Connection failed: #{inspect(reason)}")

        # Retry with exponential backoff (cap at 60s)
        delay = min(state.connect_attempts * 2_000, 60_000)
        Process.send_after(self(), :connect, delay)

        %{state | connection_status: :disconnected, last_error: reason}
    end
  end

  defp do_disconnect(%{client_pid: nil} = state) do
    %{state | connection_status: :disconnected}
  end

  defp do_disconnect(%{client_pid: pid} = state) do
    try do
      ExMCP.Client.disconnect(pid)
    catch
      :exit, _ -> :ok
    end

    %{state | client_pid: nil, connection_status: :disconnected, tools: [], resources: []}
  end

  defp discover_tools(client_pid) do
    case ExMCP.Client.list_tools(client_pid, 10_000) do
      {:ok, %{tools: tools}} when is_list(tools) ->
        # ExMCP.Response struct — normalize tools to string-keyed maps
        {:ok, Enum.map(tools, &normalize_tool/1)}

      {:ok, %{"tools" => tools}} when is_list(tools) ->
        {:ok, tools}

      {:ok, _other} ->
        {:ok, []}

      {:error, _} = error ->
        error
    end
  end

  defp discover_resources(client_pid) do
    case ExMCP.Client.list_resources(client_pid, 10_000) do
      {:ok, %{resources: resources}} when is_list(resources) ->
        # ExMCP.Response struct — normalize to string-keyed maps
        {:ok, Enum.map(resources, &normalize_resource/1)}

      {:ok, %{"resources" => resources}} when is_list(resources) ->
        {:ok, resources}

      {:ok, _other} ->
        {:ok, []}

      {:error, _} = error ->
        error
    end
  rescue
    _ -> {:ok, []}
  catch
    :exit, _ -> {:ok, []}
  end

  defp do_read_resource(client_pid, uri, timeout) do
    case ExMCP.Client.read_resource(client_pid, uri, timeout: timeout) do
      {:ok, %{contents: contents}} when is_list(contents) ->
        # ExMCP.Response struct
        {:ok, normalize_resource_contents(contents)}

      {:ok, %{"contents" => contents}} when is_list(contents) ->
        {:ok, normalize_resource_contents(contents)}

      {:ok, result} ->
        {:ok, result}

      {:error, _} = error ->
        error
    end
  end

  defp normalize_resource(resource) when is_map(resource) do
    %{
      "uri" => Map.get(resource, :uri) || Map.get(resource, "uri"),
      "name" => Map.get(resource, :name) || Map.get(resource, "name"),
      "description" => Map.get(resource, :description) || Map.get(resource, "description", ""),
      "mimeType" => Map.get(resource, :mimeType) || Map.get(resource, "mimeType", "")
    }
  end

  defp normalize_resource_contents(contents) when is_list(contents) do
    Enum.map(contents, fn content ->
      %{
        "uri" => Map.get(content, :uri) || Map.get(content, "uri"),
        "text" => Map.get(content, :text) || Map.get(content, "text"),
        "blob" => Map.get(content, :blob) || Map.get(content, "blob"),
        "mimeType" => Map.get(content, :mimeType) || Map.get(content, "mimeType")
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()
    end)
  end

  defp do_call_tool(client_pid, tool_name, arguments, timeout) do
    case ExMCP.Client.call_tool(client_pid, tool_name, arguments, timeout) do
      {:ok, %{content: content}} when is_list(content) ->
        # ExMCP.Response struct
        {:ok, extract_content(content)}

      {:ok, %{"content" => content}} when is_list(content) ->
        {:ok, extract_content(content)}

      {:ok, result} ->
        {:ok, result}

      {:error, _} = error ->
        error
    end
  end

  defp extract_content(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{type: "text", text: text} -> text
      %{"type" => "text", "text" => text} -> text
      %{type: "image", data: data} -> %{type: :image, data: data}
      %{"type" => "image", "data" => data} -> %{type: :image, data: data}
      other -> other
    end)
    |> case do
      [single] -> single
      multiple -> multiple
    end
  end

  defp extract_content(other), do: other

  # Normalize a tool map to ensure string keys are present (for ToolBridge compatibility)
  defp normalize_tool(tool) when is_map(tool) do
    %{
      "name" => Map.get(tool, :name) || Map.get(tool, "name"),
      "description" => Map.get(tool, :description) || Map.get(tool, "description", ""),
      "inputSchema" => Map.get(tool, :inputSchema) || Map.get(tool, "inputSchema", %{})
    }
  end

  defp safe_start_client(opts) do
    ExMCP.Client.start_link(opts)
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp build_client_opts(config) do
    transport = Map.get(config, :transport, :stdio)

    base =
      case transport do
        :stdio ->
          command = Map.get(config, :command, [])

          command =
            case command do
              cmd when is_binary(cmd) -> [cmd]
              cmd when is_list(cmd) -> cmd
            end

          opts = [transport: :stdio, command: command]

          case Map.get(config, :env) do
            nil -> opts
            env when is_map(env) -> Keyword.put(opts, :env, Map.to_list(env))
          end

        http when http in [:http, :sse] ->
          [transport: http, url: Map.fetch!(config, :url)]

        :beam ->
          [transport: :beam, server: Map.fetch!(config, :server)]

        :native ->
          [transport: :native, server: Map.fetch!(config, :server)]

        :test ->
          [transport: :test, server: Map.fetch!(config, :server)]
      end

    # Add name if provided
    case Map.get(config, :name) do
      nil -> base
      name -> Keyword.put(base, :name, name)
    end
  end

  defp schedule_health_check do
    Process.send_after(self(), :health_check, @health_check_interval)
  end

  defp safe_emit(event_type, data) do
    if Code.ensure_loaded?(Arbor.Signals) and
         function_exported?(Arbor.Signals, :emit, 3) do
      try do
        Arbor.Signals.emit(:gateway, event_type, data)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end
  end
end
