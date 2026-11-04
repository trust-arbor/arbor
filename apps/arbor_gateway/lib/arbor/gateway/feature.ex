defmodule Arbor.Gateway.Feature do
  @moduledoc """
  Passive renderer for the current Gateway HTTP-only Application wiring.

  Every snapshot has mcp_client_enabled, start_server and http_admission.
  Exact supported branches are:
  * start_server: false, http_admission: :not_requested: no other keys.
  * start_server: true, http_admission: :port_in_use: also port.
  * start_server: true, http_admission: :available: also port, bind_ip,
    http_idle_timeout_ms and handler_call_timeout_ms.

  Flags must be booleans; port is 0..65535; bind_ip is an IPv4 or IPv6 tuple;
  the handler budget is a positive integer; configured idle timeout is nil or
  an integer. Unsupported effective inputs are unresolved outside the callback,
  not a new startup policy. These are complete trusted owner snapshots, never
  proof that a caller performed admission. This function performs no probe.

  The HTTP map derives only from those owner scalars, the audited
  HttpServerOptions idle-timeout rule and the fixed current HTTP constructor.
  It accepts no ref, dispatch, producer module, normalized child plan or MFA.
  No child-spec producer, router initializer, Module.concat, Ranch, listener,
  configuration read or new reference is invoked. Malformed calls raise a
  fixed redacted ArgumentError. All existing Application startup remains owned
  by Application.start/2.

  Empty action/URI lists mean no additional DIRECT Application entrypoint
  global contribution here, not absent tools or resource URIs. Routes preserve
  mount/delegation ownership and compile guards as data. Liveness definition
  is distinct from measured health; health remains unobserved.
  """

  @behaviour Arbor.Contracts.Feature

  @invalid_snapshot "invalid feature snapshot"
  @base_keys [:mcp_client_enabled, :start_server, :http_admission]
  @http_ref Arbor.Gateway.Router.HTTP
  @dispatch [
    {:_, [], [{:_, [], Plug.Cowboy.Handler, {Arbor.Gateway.Router, []}}]}
  ]

  @impl true
  def id, do: :gateway

  @impl true
  def requires, do: [:core]

  @impl true
  @spec children(map()) :: [Supervisor.child_spec()]
  def children(
        %{
          mcp_client_enabled: mcp_enabled,
          start_server: server_enabled,
          http_admission: admission
        } = snapshot
      )
      when is_boolean(mcp_enabled) and is_boolean(server_enabled) do
    http = http_children(snapshot, server_enabled, admission)

    mcp_children(mcp_enabled) ++
      [
        %{
          id: Arbor.Gateway.MCP.EndpointRegistry,
          start: {Arbor.Gateway.MCP.EndpointRegistry, :start_link, [[]]}
        },
        %{
          id: Arbor.Gateway.Chat.LifecycleAuthority,
          start: {Arbor.Gateway.Chat.LifecycleAuthority, :start_link, [[]]}
        }
      ] ++ http
  end

  def children(_snapshot), do: invalid_snapshot!()

  @impl true
  def action_modules, do: []

  @impl true
  def uri_prefixes, do: []

  @impl true
  def routes do
    [
      %{
        kind: :route,
        method: "GET",
        path: "/health",
        owner: Arbor.Gateway.Router,
        defined_status: 200,
        health_scope: :liveness_definition
      },
      %{
        kind: :mount,
        path: "/mcp",
        owner: ExMCP.HttpPlug,
        handler: Arbor.Gateway.MCP.Handler,
        coverage: :delegated
      },
      %{
        kind: :mount,
        path: "/api/memory",
        owner: Arbor.Gateway.Memory.Router,
        coverage: :delegated
      },
      %{
        kind: :mount,
        path: "/api/signals",
        owner: Arbor.Gateway.Signals.Router,
        coverage: :delegated
      },
      %{kind: :mount, path: "/api/chat", owner: Arbor.Gateway.Chat.Router, coverage: :delegated},
      %{
        kind: :mount,
        path: "/api/dev",
        owner: Arbor.Gateway.Dev.Router,
        coverage: :delegated,
        build_guard: %{mix_env: [:dev, :test]}
      },
      %{kind: :fallback, owner: Arbor.Gateway.Router, defined_status: 404}
    ]
  end

  @impl true
  def health, do: %{status: :unobserved}

  defp mcp_children(true) do
    [
      %{
        id: Arbor.Gateway.MCP.ClientSupervisor,
        start: {Arbor.Gateway.MCP.ClientSupervisor, :start_link, [[]]},
        type: :supervisor
      }
    ]
  end

  defp mcp_children(false), do: []

  defp http_children(snapshot, false, :not_requested) do
    if exact_keys?(snapshot, @base_keys), do: [], else: invalid_snapshot!()
  end

  defp http_children(%{port: port} = snapshot, true, :port_in_use) do
    if exact_keys?(snapshot, @base_keys ++ [:port]) and valid_port?(port) do
      []
    else
      invalid_snapshot!()
    end
  end

  defp http_children(
         %{
           port: port,
           bind_ip: ip,
           http_idle_timeout_ms: configured_idle,
           handler_call_timeout_ms: handler_timeout
         } = snapshot,
         true,
         :available
       ) do
    keys = @base_keys ++ [:port, :bind_ip, :http_idle_timeout_ms, :handler_call_timeout_ms]

    if exact_keys?(snapshot, keys) and valid_port?(port) and valid_ip?(ip) and
         (is_nil(configured_idle) or is_integer(configured_idle)) and
         is_integer(handler_timeout) and handler_timeout > 0 do
      [http_child(port, ip, configured_idle, handler_timeout)]
    else
      invalid_snapshot!()
    end
  end

  defp http_children(_snapshot, _server_enabled, _admission), do: invalid_snapshot!()

  defp http_child(port, ip, configured_idle, handler_timeout) do
    floor = handler_timeout + 15_000

    idle_timeout =
      if is_integer(configured_idle) and configured_idle > floor,
        do: configured_idle,
        else: floor

    transport_options = %{
      num_acceptors: 100,
      max_connections: 16_384,
      socket_opts: [port: port, ip: ip]
    }

    protocol_options = %{
      env: %{dispatch: @dispatch},
      idle_timeout: idle_timeout,
      stream_handlers: [:cowboy_telemetry_h, :cowboy_stream_h]
    }

    %{
      id: {:ranch_embedded_sup, @http_ref},
      start:
        {:ranch_embedded_sup, :start_link,
         [@http_ref, :ranch_tcp, transport_options, :cowboy_clear, protocol_options]},
      type: :supervisor
    }
  end

  defp valid_port?(port), do: is_integer(port) and port >= 0 and port <= 65_535

  defp valid_ip?(ip) when is_tuple(ip) and tuple_size(ip) == 4 do
    ip |> Tuple.to_list() |> Enum.all?(&(is_integer(&1) and &1 >= 0 and &1 <= 255))
  end

  defp valid_ip?(ip) when is_tuple(ip) and tuple_size(ip) == 8 do
    ip |> Tuple.to_list() |> Enum.all?(&(is_integer(&1) and &1 >= 0 and &1 <= 65_535))
  end

  defp valid_ip?(_ip), do: false

  defp exact_keys?(map, keys) do
    map_size(map) == length(keys) and Enum.all?(keys, &Map.has_key?(map, &1))
  end

  defp invalid_snapshot!, do: raise(ArgumentError, @invalid_snapshot)
end
