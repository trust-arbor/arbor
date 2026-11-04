defmodule Arbor.Gateway.FeatureTest do
  use ExUnit.Case, async: false

  @feature Arbor.Gateway.Feature
  @forbidden_calls [
    {Application, :get_env, 2},
    {Application, :get_env, 3},
    {Application, :fetch_env, 2},
    {Application, :put_env, 3},
    {Application, :ensure_all_started, 1},
    {Application, :ensure_all_started, 2},
    {Supervisor, :start_link, 2},
    {Supervisor, :child_spec, 2},
    {GenServer, :start_link, 3},
    {Code, :ensure_loaded, 1},
    {Code, :ensure_loaded?, 1},
    {Module, :concat, 2},
    {:gen_tcp, :listen, 2},
    {:erlang, :make_ref, 0},
    {:erlang, :spawn, 1},
    {:erlang, :spawn, 3},
    {:erlang, :spawn_link, 1},
    {:erlang, :spawn_link, 3},
    {:erlang, :spawn_monitor, 1},
    {:erlang, :spawn_monitor, 3},
    {Task, :start, 1},
    {:ets, :new, 2},
    {:persistent_term, :put, 2},
    {Plug.Cowboy, :child_spec, 1},
    {:ranch, :child_spec, 5},
    {:cowboy_router, :compile, 1},
    {Arbor.Gateway.Router, :init, 1},
    {Arbor.Gateway.HttpServerOptions, :build, 1},
    {Arbor.Gateway.MCP.ClientSupervisor, :child_spec, 1},
    {Arbor.Gateway.MCP.EndpointRegistry, :child_spec, 1},
    {Arbor.Gateway.Chat.LifecycleAuthority, :child_spec, 1}
  ]

  test "no-server and real port-in-use branches preserve order and require no invented HTTP facts" do
    fixed = fixed_specs()

    assert children(%{
             mcp_client_enabled: false,
             start_server: false,
             http_admission: :not_requested
           }) == fixed

    assert children(%{
             mcp_client_enabled: true,
             start_server: false,
             http_admission: :not_requested
           }) == [Arbor.Gateway.MCP.ClientSupervisor.child_spec([]) | fixed]

    assert children(%{
             mcp_client_enabled: true,
             start_server: true,
             http_admission: :port_in_use,
             port: 4000
           }) == [Arbor.Gateway.MCP.ClientSupervisor.child_spec([]) | fixed]
  end

  test "available HTTP matrices equal actual fixed Router Cowboy Ranch and MCP producers" do
    for mcp_enabled <- [false, true],
        {port, ip, configured_idle, handler_timeout} <- [
          {0, {127, 0, 0, 1}, nil, 45_000},
          {4000, {127, 0, 0, 1}, 0, 1_000},
          {4040, {0, 0, 0, 0, 0, 0, 0, 1}, 60_001, 45_000},
          {4001, {127, 0, 0, 1}, -1, 2_000},
          {4002, {127, 0, 0, 1}, 60_000, 45_000}
        ] do
      snapshot = available(mcp_enabled, port, ip, configured_idle, handler_timeout)

      options =
        Arbor.Gateway.HttpServerOptions.build(
          port: port,
          ip: ip,
          http_idle_timeout_ms: configured_idle,
          handler_call_timeout_ms: handler_timeout
        )

      actual_http =
        Plug.Cowboy.child_spec(
          scheme: :http,
          plug: Arbor.Gateway.Router,
          options: options
        )

      mcp = if mcp_enabled, do: [Arbor.Gateway.MCP.ClientSupervisor.child_spec([])], else: []
      actual = children(snapshot)
      assert actual == mcp ++ fixed_specs() ++ [actual_http]
      http = List.last(actual)
      assert Enum.sort(Map.keys(http)) == [:id, :start, :type]
      assert http.id == {:ranch_embedded_sup, Arbor.Gateway.Router.HTTP}

      assert {:ranch_embedded_sup, :start_link,
              [Arbor.Gateway.Router.HTTP, :ranch_tcp, transport, :cowboy_clear, protocol]} =
               http.start

      assert transport.socket_opts == [port: port, ip: ip]
      assert transport.num_acceptors == 100
      assert transport.max_connections == 16_384
      assert protocol.idle_timeout == Keyword.fetch!(options[:protocol_options], :idle_timeout)

      assert protocol.env.dispatch == [
               {:_, [], [{:_, [], Plug.Cowboy.Handler, {Arbor.Gateway.Router, []}}]}
             ]
    end
  end

  test "missing conditional inputs contradictions unsupported scalars and injected plans are redacted" do
    complete = available(true, 4000, {127, 0, 0, 1}, nil, 45_000)

    for key <- [
          :mcp_client_enabled,
          :start_server,
          :http_admission,
          :port,
          :bind_ip,
          :http_idle_timeout_ms,
          :handler_call_timeout_ms
        ] do
      assert_redacted(Map.delete(complete, key))
    end

    for snapshot <- [
          nil,
          [],
          %{},
          %{mcp_client_enabled: true, start_server: true, http_admission: :not_requested},
          %{
            mcp_client_enabled: false,
            start_server: false,
            http_admission: :port_in_use,
            port: 4000
          },
          %{mcp_client_enabled: false, start_server: true, http_admission: :port_in_use},
          Map.put(complete, :http_admission, :not_observed),
          Map.put(complete, :mcp_client_enabled, :unknown),
          Map.put(complete, :port, -1),
          Map.put(complete, :port, 65_536),
          Map.put(complete, :bind_ip, {256, 0, 0, 1}),
          Map.put(complete, :handler_call_timeout_ms, 0),
          Map.put(complete, :http_idle_timeout_ms, fn -> "private" end),
          Map.put(complete, :dispatch, []),
          Map.put(complete, :ref, Arbor.Gateway.Router.HTTP),
          Map.put(complete, :child_plan, []),
          Map.put(complete, :mfa, {Code, :eval_string, ["not-code"]})
        ] do
      assert_redacted(snapshot)
    end
  end

  test "all supported branches render with no environment producer network startup or atom-builder calls" do
    apply(@feature, :health, [])

    {inactive, busy, available_mcp, available_no_mcp, refusal, health} =
      assert_passive(fn ->
        {
          children(%{
            mcp_client_enabled: false,
            start_server: false,
            http_admission: :not_requested
          }),
          children(%{
            mcp_client_enabled: true,
            start_server: true,
            http_admission: :port_in_use,
            port: 4000
          }),
          children(available(true, 4000, {127, 0, 0, 1}, nil, 45_000)),
          children(available(false, 0, {0, 0, 0, 0, 0, 0, 0, 1}, 0, 1_000)),
          refusal_kind(%{private_owner_value: "private-input-must-not-appear"}),
          apply(@feature, :health, [])
        }
      end)

    assert length(inactive) == 2
    assert length(busy) == 3
    assert length(available_mcp) == 4
    assert length(available_no_mcp) == 3
    assert refusal == :refused
    assert health == %{status: :unobserved}
  end

  test "static route metadata retains top-level owners guards and unobserved health" do
    routes = apply(@feature, :routes, [])

    assert %{
             kind: :mount,
             path: "/api/memory",
             owner: Arbor.Gateway.Memory.Router,
             coverage: :delegated
           } in routes

    assert %{
             kind: :mount,
             path: "/api/signals",
             owner: Arbor.Gateway.Signals.Router,
             coverage: :delegated
           } in routes

    assert %{
             kind: :mount,
             path: "/api/chat",
             owner: Arbor.Gateway.Chat.Router,
             coverage: :delegated
           } in routes

    assert %{
             kind: :mount,
             path: "/api/dev",
             owner: Arbor.Gateway.Dev.Router,
             coverage: :delegated,
             build_guard: %{mix_env: [:dev, :test]}
           } in routes

    assert %{
             kind: :route,
             method: "GET",
             path: "/health",
             owner: Arbor.Gateway.Router,
             defined_status: 200,
             health_scope: :liveness_definition
           } in routes

    assert apply(@feature, :action_modules, []) == []
    assert apply(@feature, :uri_prefixes, []) == []
    assert apply(@feature, :health, []) == %{status: :unobserved}
  end

  test "packaged metadata supplies conditional host keys and only public child IDs" do
    assert apply(@feature, :id, []) == :gateway
    assert apply(@feature, :requires, []) == [:core]
    refute function_exported?(@feature, :graphs, 0)
    refute function_exported?(@feature, :commands, 0)
    assert Application.fetch_env!(:arbor_gateway, :arbor_feature) == @feature
    metadata = Application.fetch_env!(:arbor_gateway, :arbor_feature_metadata)
    assert metadata.id == :gateway
    assert metadata.requires == [:core]
    assert metadata.dependency_role == :fixed_host_prerequisite
    assert metadata.contribution_scope == :direct_application_entrypoint

    assert metadata.snapshot_required_keys == [
             :mcp_client_enabled,
             :start_server,
             :http_admission
           ]

    assert metadata.snapshot_conditional_required_keys == %{
             http_admission: %{
               not_requested: [],
               port_in_use: [:port],
               available: [:port, :bind_ip, :http_idle_timeout_ms, :handler_call_timeout_ms]
             }
           }

    assert metadata.public_child_ids == [
             Arbor.Gateway.MCP.ClientSupervisor,
             Arbor.Gateway.MCP.EndpointRegistry,
             Arbor.Gateway.Chat.LifecycleAuthority,
             {:ranch_embedded_sup, Arbor.Gateway.Router.HTTP}
           ]

    refute Map.has_key?(metadata, :start)
    refute Map.has_key?(metadata, :args)
  end

  test "fixed Application HTTP builder and Router source pins force drift review" do
    assert_source_pin(
      "../../../lib/arbor/gateway/application.ex",
      "def51d6acd2b3ad76a5aef794863317b077956187e6ab568472e3b80175a381b"
    )

    assert_source_pin(
      "../../../lib/arbor/gateway/http_server_options.ex",
      "84cb2ab726ae86b77c06b4c850354a3194631c4612a07af1a20ba8cf860b2eee"
    )

    assert_source_pin(
      "../../../lib/arbor/gateway/router.ex",
      "1b96edc4c05841d379698fb3c24c349bf0fa2013e94b9a0f10409a9157aa192b"
    )
  end

  defp fixed_specs do
    [
      Arbor.Gateway.MCP.EndpointRegistry.child_spec([]),
      Arbor.Gateway.Chat.LifecycleAuthority.child_spec([])
    ]
  end

  defp available(mcp_enabled, port, ip, idle, handler_timeout) do
    %{
      mcp_client_enabled: mcp_enabled,
      start_server: true,
      http_admission: :available,
      port: port,
      bind_ip: ip,
      http_idle_timeout_ms: idle,
      handler_call_timeout_ms: handler_timeout
    }
  end

  defp assert_passive(fun) do
    caller = self()
    tracer = spawn(fn -> collect_calls([]) end)

    try do
      Enum.each(@forbidden_calls, fn {module, _function, _arity} ->
        Code.ensure_loaded?(module)
      end)

      Enum.each(@forbidden_calls, fn pattern ->
        assert :erlang.trace_pattern(pattern, true, [:local]) > 0
      end)

      :erlang.trace(caller, true, [:call, :arity, {:tracer, tracer}])
      result = fun.()
      :erlang.trace(caller, false, [:call, :arity])
      marker = :erlang.trace_delivered(caller)
      assert_receive {:trace_delivered, ^caller, ^marker}, 1_000
      send(tracer, {:collected, caller})
      assert_receive {:feature_calls, ^tracer, calls}, 1_000
      assert calls == []
      result
    after
      :erlang.trace(caller, false, [:call, :arity])
      Enum.each(@forbidden_calls, &:erlang.trace_pattern(&1, false, [:local]))
      Process.exit(tracer, :kill)
    end
  end

  defp collect_calls(calls) do
    receive do
      {:trace, _pid, :call, {module, function, arity}} when is_integer(arity) ->
        collect_calls([{module, function, arity} | calls])

      {:collected, caller} ->
        send(caller, {:feature_calls, self(), Enum.reverse(calls)})
    end
  end

  defp refusal_kind(snapshot) do
    children(snapshot)
    :accepted
  rescue
    ArgumentError -> :refused
  end

  defp assert_redacted(snapshot) do
    error = assert_raise ArgumentError, fn -> children(snapshot) end
    assert Exception.message(error) == "invalid feature snapshot"
  end

  defp children(snapshot), do: apply(@feature, :children, [snapshot])

  defp assert_source_pin(relative, expected) do
    bytes = File.read!(Path.expand(relative, __DIR__))
    actual = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    assert actual == expected
  end
end
