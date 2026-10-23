defmodule Arbor.Gateway.MCP.ClientConnection do
  @moduledoc """
  Supervised GenServer wrapping an ExMCP.Client connection to an external MCP server.

  Handles:
  - Connection lifecycle (connect, health check, reconnect on failure)
  - Tool discovery and caching
  - Tool invocation with timeout handling and outcome classification
  - Status reporting

  Tool calls and resource reads run in the caller's process against the
  checked-out `ExMCP.Client`, never inside this GenServer: a slow call does not
  block the connection, and a caller that gives up leaves no call queued here
  to be sent after it stopped waiting.

  ## State

  The connection maintains a cached tool list that is refreshed on connect
  and can be manually refreshed via `refresh_tools/1`.

  First discovery auto-pins each tool's SHA-256 fingerprint (`name`,
  `description`, `inputSchema`) and presents it. Accepted pins are stored
  under the server's approved config identity and reloaded on process
  restart. A later refresh, `notifications/tools/list_changed`, or restart
  that changes a pinned tool quarantines it until
  `approve_tool_fingerprint/2` re-pins the observed definition.
  See `Arbor.Gateway.MCP.ToolFingerprintCore` and
  `Arbor.Gateway.MCP.ToolPinStore`.
  """

  use GenServer

  alias Arbor.Contracts.Tool.CallFailure
  alias Arbor.Gateway.MCP.CallOutcome
  alias Arbor.Gateway.MCP.ToolFingerprintCore
  alias Arbor.Gateway.MCP.ToolPinStore

  require Logger

  @health_check_interval 30_000
  @default_timeout 30_000
  # Checking out the client is a local state read; it sends nothing.
  @checkout_timeout 5_000

  defstruct [
    :server_name,
    :config,
    :client_pid,
    :agent_id,
    connection_status: :disconnected,
    tools: [],
    tool_pins: %{},
    pin_identity: nil,
    pin_store: :ok,
    quarantined_tools: [],
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

  @doc """
  Call a tool on the connected MCP server.

  Returns `{:ok, result}` when the tool answered, or
  `{:error, %Arbor.Contracts.Tool.CallFailure{}}` classified by
  `Arbor.Gateway.MCP.CallOutcome`: `:not_sent` when there was no connected
  client, `:refused` when the server rejected the request before running a
  tool, `:failed` when the tool answered with an error result, and `:unknown`
  when the call may have been delivered with no trustworthy answer — a
  timeout, an exit or a crash always reads as `:unknown`.

  The call is never retried: ExMCP gets `retry_policy: false` and
  `http_stream_retry: :safe_only` (its modern-stream default reissues a broken
  tool call at least once).
  """
  @spec call_tool(pid(), String.t(), map(), keyword()) ::
          {:ok, term()} | {:error, CallFailure.t()}
  def call_tool(pid, tool_name, arguments, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    case checkout_tool(pid, tool_name) do
      {:ok, client_pid, server_name} ->
        invoke_tool(client_pid, server_name, tool_name, arguments, timeout)

      {:error, {:fingerprint_changed, _name}, server_name} ->
        {:error, CallOutcome.fingerprint_changed(server_name, tool_name)}

      {:error, {:not_connected, status}, server_name} ->
        {:error, CallOutcome.not_connected(server_name, tool_name, status)}

      # The checkout only reads connection state, so an exit here sent nothing.
      {:exit, reason} ->
        {:error, CallOutcome.not_connected(nil, tool_name, {:exit, reason})}
    end
  end

  @doc """
  Refresh the cached tool list from the server.

  Newly seen names are auto-pinned (first-discovery). A pinned tool whose
  name, description, or inputSchema changed is quarantined and omitted from
  the returned list until `approve_tool_fingerprint/2`.
  """
  @spec refresh_tools(pid()) :: {:ok, [map()]} | {:error, term()}
  def refresh_tools(pid), do: GenServer.call(pid, :refresh_tools)

  @doc """
  Re-approve a quarantined tool, pinning its currently observed definition.

  This is the re-approval hook for a fingerprint mismatch. The new pin is
  written to `ToolPinStore` so a restart keeps the accepted definition.
  Existing server-connect approval and tool-call capabilities are unchanged.
  """
  @spec approve_tool_fingerprint(pid(), String.t()) :: {:ok, map()} | {:error, term()}
  def approve_tool_fingerprint(pid, tool_name) when is_binary(tool_name),
    do: GenServer.call(pid, {:approve_tool_fingerprint, tool_name})

  @doc "List discovered resources from the connected MCP server."
  @spec list_resources(pid()) :: {:ok, [map()]} | {:error, term()}
  def list_resources(pid), do: GenServer.call(pid, :list_resources)

  @doc "Read a specific resource from the connected MCP server."
  @spec read_resource(pid(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def read_resource(pid, uri, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    case checkout_client(pid) do
      {:ok, client_pid, _server_name} -> do_read_resource(client_pid, uri, timeout)
      {:error, {:not_connected, _status} = reason, _server_name} -> {:error, reason}
      {:exit, reason} -> {:error, {:exit, reason}}
    end
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

    identity = ToolPinStore.identity(config.server_name, config)
    {pins, pin_store} = load_pins(identity, config)

    state = %__MODULE__{
      server_name: config.server_name,
      config: config,
      agent_id: Map.get(config, :agent_id),
      tool_pins: pins,
      pin_identity: identity,
      pin_store: pin_store
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
      quarantined_tools: Enum.map(state.quarantined_tools, & &1["name"]),
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

  def handle_call(
        :checkout_client,
        _from,
        %{connection_status: :connected, client_pid: client_pid} = state
      )
      when is_pid(client_pid) do
    {:reply, {:ok, client_pid, state.server_name}, state}
  end

  def handle_call(:checkout_client, _from, state) do
    {:reply, {:error, {:not_connected, state.connection_status}, state.server_name}, state}
  end

  def handle_call(
        {:checkout_tool, tool_name},
        _from,
        %{connection_status: :connected, client_pid: client_pid} = state
      )
      when is_pid(client_pid) and is_binary(tool_name) do
    if quarantined_name?(state, tool_name) do
      {:reply, {:error, {:fingerprint_changed, tool_name}, state.server_name}, state}
    else
      {:reply, {:ok, client_pid, state.server_name}, state}
    end
  end

  def handle_call({:checkout_tool, _tool_name}, _from, state) do
    {:reply, {:error, {:not_connected, state.connection_status}, state.server_name}, state}
  end

  def handle_call(:list_resources, _from, %{connection_status: :connected} = state) do
    {:reply, {:ok, state.resources}, state}
  end

  def handle_call(:list_resources, _from, state) do
    {:reply, {:error, {:not_connected, state.connection_status}}, state}
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
        {state, admitted} = apply_tool_discovery(state, tools)
        {:reply, {:ok, admitted}, state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(:refresh_tools, _from, state) do
    {:reply, {:error, {:not_connected, state.connection_status}}, state}
  end

  def handle_call({:approve_tool_fingerprint, tool_name}, _from, state)
      when is_binary(tool_name) do
    case Enum.find(state.quarantined_tools, &(&1["name"] == tool_name)) do
      nil ->
        {:reply, {:error, :not_quarantined}, state}

      tool ->
        case ToolFingerprintCore.approve(state.tool_pins, tool) do
          {:ok, result} ->
            interpret_effects(result.effects, state)

            state =
              persist_pins(%{
                state
                | tool_pins: result.pins,
                  tools: state.tools ++ [result.tool],
                  quarantined_tools:
                    Enum.reject(state.quarantined_tools, &(&1["name"] == tool_name))
              })

            {:reply, {:ok, result.tool}, state}

          {:error, _} = error ->
            {:reply, error, state}
        end
    end
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

  def handle_info({:notification, "notifications/tools/list_changed", _params}, state) do
    {:noreply, refresh_discovered_tools(state)}
  end

  def handle_info(
        {:ex_mcp_subscription, _subscription, "notifications/tools/list_changed", _params},
        state
      ) do
    {:noreply, refresh_discovered_tools(state)}
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
        discovered_tools =
          if Map.get(state.config, :auto_discover, true) do
            case discover_tools(pid) do
              {:ok, tools} -> tools
              {:error, _} -> []
            end
          else
            []
          end

        {state, tools} = apply_tool_discovery(state, discovered_tools)

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
      :exit, reason ->
        Logger.debug("[ClientConnection] disconnect exited: #{inspect(reason)}")
        :ok
    end

    %{state | client_pid: nil, connection_status: :disconnected, tools: [], resources: []}
  end

  defp discover_tools(client_pid) do
    case ExMCP.Client.list_tools(client_pid, 10_000) do
      {:ok, %{tools: tools}} when is_list(tools) ->
        # ExMCP.Response struct — normalize tools to string-keyed maps
        {:ok, Enum.map(tools, &normalize_tool/1)}

      {:ok, %{"tools" => tools}} when is_list(tools) ->
        {:ok, Enum.map(tools, &normalize_tool/1)}

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
    e ->
      Logger.debug("[ClientConnection] discover_resources failed: #{Exception.message(e)}")
      {:ok, []}
  catch
    :exit, reason ->
      Logger.debug("[ClientConnection] discover_resources exited: #{inspect(reason)}")
      {:ok, []}
  end

  defp checkout_client(pid) do
    GenServer.call(pid, :checkout_client, @checkout_timeout)
  catch
    :exit, reason -> {:exit, reason}
  end

  defp checkout_tool(pid, tool_name) do
    GenServer.call(pid, {:checkout_tool, tool_name}, @checkout_timeout)
  catch
    :exit, reason -> {:exit, reason}
  end

  defp apply_tool_discovery(%{pin_store: :unreadable} = state, tools) do
    decision = ToolFingerprintCore.admit(state.tool_pins, tools, unknown: :quarantine)
    interpret_effects(decision.effects, state)

    state = %{
      state
      | tools: decision.admitted,
        quarantined_tools: decision.quarantined
    }

    {state, decision.admitted}
  end

  defp apply_tool_discovery(state, tools) do
    decision = ToolFingerprintCore.admit(state.tool_pins, tools)
    interpret_effects(decision.effects, state)

    state =
      persist_pins(%{
        state
        | tools: decision.admitted,
          tool_pins: decision.pins,
          quarantined_tools: decision.quarantined
      })

    {state, decision.admitted}
  end

  defp load_pins(identity, config) do
    case ToolPinStore.load(identity, pin_store_opts(config)) do
      {:ok, pins} ->
        {pins, :ok}

      {:error, :unreadable} ->
        Logger.error(
          "[MCP:#{config.server_name}] Tool pin store unreadable; refusing first-discovery"
        )

        {%{}, :unreadable}
    end
  end

  defp persist_pins(%{pin_identity: identity, pin_store: :ok} = state) when is_binary(identity) do
    case ToolPinStore.save(identity, state.tool_pins, pin_store_opts(state.config)) do
      :ok ->
        state

      {:error, reason} ->
        Logger.error("[MCP:#{state.server_name}] Failed to persist tool pins: #{inspect(reason)}")
        state
    end
  end

  defp persist_pins(state), do: state

  defp pin_store_opts(config) do
    case Map.get(config, :pin_store_dir) || Map.get(config, "pin_store_dir") do
      dir when is_binary(dir) and dir != "" -> [dir: dir]
      _other -> []
    end
  end

  defp refresh_discovered_tools(%{connection_status: :connected, client_pid: pid} = state)
       when is_pid(pid) do
    case discover_tools(pid) do
      {:ok, tools} ->
        {state, _admitted} = apply_tool_discovery(state, tools)
        state

      {:error, _} ->
        state
    end
  end

  defp refresh_discovered_tools(state), do: state

  defp quarantined_name?(state, tool_name) do
    Enum.any?(state.quarantined_tools, &(&1["name"] == tool_name))
  end

  defp interpret_effects(effects, state) do
    Enum.each(effects, fn
      {:emit, type, data} ->
        safe_emit(type, Map.put(data, :server_name, state.server_name))
    end)
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
  catch
    :exit, reason -> {:error, {:exit, reason}}
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

  # Runs in the caller's process. `format: :map` keeps ExMCP's raw error terms
  # (the :struct format folds a timeout and server JSON-RPC errors into one
  # ProtocolError), which CallOutcome needs to tell "never sent" from "may
  # have run".
  defp invoke_tool(client_pid, server_name, tool_name, arguments, timeout) do
    result =
      ExMCP.Client.call_tool(client_pid, tool_name, arguments,
        timeout: timeout,
        format: :map,
        retry_policy: false,
        http_stream_retry: :safe_only
      )

    case CallOutcome.returned(server_name, tool_name, result) do
      {:ok, %{"content" => content}} when is_list(content) -> {:ok, extract_content(content)}
      {:ok, %{content: content}} when is_list(content) -> {:ok, extract_content(content)}
      other -> other
    end
  catch
    :exit, reason -> {:error, CallOutcome.exited(server_name, tool_name, reason)}
    kind, reason -> {:error, CallOutcome.raised(server_name, tool_name, kind, reason)}
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

        :http ->
          [transport: :http, url: Map.fetch!(config, :url)]

        :sse ->
          [transport: :http, use_sse: true, url: Map.fetch!(config, :url)]

        :beam ->
          [transport: :beam, server: Map.fetch!(config, :server)]

        :test ->
          [transport: :test, server: Map.fetch!(config, :server)]
      end

    # Existing MCP servers and AgentEndpoint still speak the legacy initialize
    # handshake. rc.8 defaults to :prefer_modern (MCP 2026-07-28 / server/discover).
    base = Keyword.put(base, :protocol_mode, :legacy_only)

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
    try do
      Arbor.Signals.emit(:gateway, event_type, data)
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end
end
