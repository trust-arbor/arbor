defmodule Arbor.Security.SignalTransportBindingSecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Security.Config
  alias Arbor.Security.SignalSync

  @fixture_key :signal_transport_binding_fixture
  @owned_sync_key {__MODULE__, :owned_sync}
  @events [:capability_revoked, :identity_suspended, :nonce_seen]

  defmodule Provider do
    @moduledoc false

    defmacro __using__(opts) do
      except = Keyword.get(opts, :except)

      quote do
        @moduledoc false
        alias Arbor.Security.SignalTransportBindingSecurityRegressionTest, as: Fixture

        unless unquote(except) == :configured do
          def security_sync_transport_configured?,
            do: Fixture.dispatch(__MODULE__, :configured, [])
        end

        unless unquote(except) == :role do
          def security_sync_role_configured?(role),
            do: Fixture.dispatch(__MODULE__, :role, [role])
        end

        unless unquote(except) == :subscribe do
          def subscribe_security_sync(role, event),
            do: Fixture.dispatch(__MODULE__, :subscribe, [role, event])
        end

        unless unquote(except) == :unsubscribe do
          def unsubscribe(handle), do: Fixture.dispatch(__MODULE__, :unsubscribe, [handle])
        end

        unless unquote(except) == :admit do
          def admit_remote_security_mutation?(event),
            do: Fixture.dispatch(__MODULE__, :admit, [event])
        end

        unless unquote(except) == :emit do
          def emit(category, event, data, opts),
            do: Fixture.dispatch(__MODULE__, :emit, [category, event, data, opts])
        end
      end
    end
  end

  defmodule ProviderA do
    use Provider
  end

  defmodule ProviderB do
    use Provider
  end

  defmodule MissingConfiguredProvider do
    use Provider, except: :configured
  end

  defmodule MissingRoleProvider do
    use Provider, except: :role
  end

  defmodule MissingSubscribeProvider do
    use Provider, except: :subscribe
  end

  defmodule MissingUnsubscribeProvider do
    use Provider, except: :unsubscribe
  end

  defmodule MissingAdmissionProvider do
    use Provider, except: :admit
  end

  defmodule MissingEmitProvider do
    use Provider, except: :emit
  end

  defmodule IncompleteUnconfiguredProvider do
    @moduledoc false
    def security_sync_transport_configured?, do: false
    def security_sync_role_configured?(_role), do: false
  end

  setup do
    previous =
      Map.new([:signal_transport, :distributed_signals, @fixture_key], fn key ->
        {key, Application.fetch_env(:arbor_security, key)}
      end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:arbor_security, key, value)
        {key, :error} -> Application.delete_env(:arbor_security, key)
      end)
    end)

    fixture = %{
      observer: self(),
      token: make_ref(),
      bus: start_bus(),
      responses: %{},
      refs: new_refs()
    }

    Application.put_env(:arbor_security, @fixture_key, fixture)
    Application.put_env(:arbor_security, :signal_transport, ProviderA)
    Application.put_env(:arbor_security, :distributed_signals, true)

    {:ok, fixture: fixture}
  end

  test "security regression: only explicit nil selects local authority" do
    Application.put_env(:arbor_security, :signal_transport, nil)
    refute Config.distributed_signals_enabled?()
    assert {:ok, nil} = SignalSync.establish(:nonce_cache, [:nonce_seen], true)
    assert {:ok, nil} = SignalSync.establish(:nonce_cache, [:nonce_seen], false)
    refute SignalSync.admit_remote_security_mutation?(nil, :capability_revoked)
    assert {:error, _reason} = SignalSync.emit(nil, :security, :nonce_seen, %{}, [])

    for invalid <- [false, 42, "transport", %{module: ProviderA}] do
      Application.put_env(:arbor_security, :signal_transport, invalid)
      assert Config.distributed_signals_enabled?()
      assert {:error, _reason} = SignalSync.establish(:nonce_cache, [:nonce_seen], true)
    end
  end

  test "security regression: an incomplete provider cannot hide behind an unconfigured answer" do
    Application.put_env(:arbor_security, :signal_transport, IncompleteUnconfiguredProvider)
    assert Config.distributed_signals_enabled?()
    assert {:error, _reason} = SignalSync.establish(:nonce_cache, [:nonce_seen], true)
  end

  for provider <- [
        MissingConfiguredProvider,
        MissingRoleProvider,
        MissingSubscribeProvider,
        MissingUnsubscribeProvider,
        MissingAdmissionProvider,
        MissingEmitProvider
      ] do
    test "security regression: #{inspect(provider)} cannot be selected as a complete transport" do
      Application.put_env(:arbor_security, :signal_transport, unquote(provider))
      assert Config.distributed_signals_enabled?()

      assert {:error, :security_sync_provider_unavailable} =
               SignalSync.establish(:nonce_cache, [:nonce_seen], true)
    end
  end

  for callback <- [:configured, :role],
      {failure, expected_reason} <- [
        {:raise, :security_sync_provider_unavailable},
        {:throw, :security_sync_provider_unavailable},
        {:exit, :security_sync_provider_unavailable},
        {:non_boolean, :invalid_security_sync_provider_response},
        {nil, :invalid_security_sync_provider_response}
      ] do
    test "security regression: #{callback} #{failure} cannot silently disable configured sync",
         %{fixture: %{token: token}} do
      callback = unquote(callback)
      failure = unquote(failure)
      put_response({ProviderA, callback}, fault(failure))

      assert Config.distributed_signals_enabled?()

      assert {:error, unquote(expected_reason)} =
               SignalSync.establish(:nonce_cache, [:nonce_seen], true)

      refute_received {:transport_callback, ^token, _provider, :subscribe, _caller, _args}
    end
  end

  test "a complete provider may explicitly report an unconfigured transport", %{
    fixture: %{token: token}
  } do
    put_response({ProviderA, :configured}, false)
    refute Config.distributed_signals_enabled?()
    assert {:ok, nil} = SignalSync.establish(:nonce_cache, [:nonce_seen], true)
    refute_received {:transport_callback, ^token, _provider, :subscribe, _caller, _args}
  end

  test "an unconfigured role creates no subscription", %{fixture: %{token: token}} do
    put_response({ProviderA, :role}, false)
    assert Config.distributed_signals_enabled?()
    assert {:ok, nil} = SignalSync.establish(:nonce_cache, [:nonce_seen], true)
    refute_received {:transport_callback, ^token, _provider, :subscribe, _caller, _args}
  end

  test "security regression: obsolete three-element subscription success is rejected",
       %{fixture: fixture} do
    put_response({ProviderA, :subscribe, :nonce_seen}, {:ok, "legacy-handle", fixture.bus})
    assert {:error, _reason} = SignalSync.establish(:nonce_cache, [:nonce_seen], true)
  end

  test "security regression: malformed subscription identities cannot acquire delivery custody",
       %{fixture: fixture} do
    invalid_results = [
      {:ok, "", fixture.bus, make_ref()},
      {:ok, nil, fixture.bus, make_ref()},
      {:ok, "handle", :not_a_pid, make_ref()},
      {:ok, "handle", fixture.bus, :not_a_reference}
    ]

    for result <- invalid_results do
      put_response({ProviderA, :subscribe, :nonce_seen}, result)
      assert {:error, _reason} = SignalSync.establish(:nonce_cache, [:nonce_seen], true)
    end

    # A rejected response must not poison the caller's private custody anchor.
    delete_response({ProviderA, :subscribe, :nonce_seen})
    with_sync(:nonce_cache, [:nonce_seen], fn _sync -> :ok end)
  end

  test "security regression: a subscription callback failure cannot poison delivery custody" do
    for failure <- [:raise, :throw, :exit] do
      put_response({ProviderA, :subscribe, :nonce_seen}, fault(failure))
      assert {:error, _reason} = SignalSync.establish(:nonce_cache, [:nonce_seen], true)
    end

    delete_response({ProviderA, :subscribe, :nonce_seen})
    with_sync(:nonce_cache, [:nonce_seen], fn _sync -> :ok end)
  end

  test "security regression: a dead transport owner cannot acquire delivery custody",
       %{fixture: fixture} do
    dead_bus = start_bus()
    monitor = Process.monitor(dead_bus)
    stop_bus(dead_bus)
    assert_receive {:DOWN, ^monitor, :process, ^dead_bus, :normal}, 1_000

    put_response(
      {ProviderA, :subscribe, :nonce_seen},
      {:ok, "dead-owner-handle", dead_bus, make_ref()}
    )

    assert {:error, _reason} = SignalSync.establish(:nonce_cache, [:nonce_seen], true)
    token = fixture.token
    owner = self()

    assert_received {:transport_callback, ^token, ProviderA, :unsubscribe, ^owner,
                     ["dead-owner-handle"]}

    delete_response({ProviderA, :subscribe, :nonce_seen})
    with_sync(:nonce_cache, [:nonce_seen], fn _sync -> :ok end)
  end

  test "security regression: subscription failure cleans up previously acquired handles",
       %{fixture: %{token: token}} do
    put_response({ProviderA, :subscribe, :identity_suspended}, {:error, :fixture_unavailable})

    assert {:error, _reason} =
             SignalSync.establish(
               :capability_store,
               [:capability_revoked, :identity_suspended],
               true
             )

    handle = handle(ProviderA, :capability_revoked)
    owner = self()
    assert_received {:transport_callback, ^token, ProviderA, :unsubscribe, ^owner, [^handle]}
  end

  test "security regression: mixed transport owners release both handles", %{fixture: fixture} do
    other_bus = start_bus()

    put_response(
      {ProviderA, :subscribe, :identity_suspended},
      {:ok, "other-owner-handle", other_bus, make_ref()}
    )

    assert {:error, _reason} =
             SignalSync.establish(
               :capability_store,
               [:capability_revoked, :identity_suspended],
               true
             )

    token = fixture.token
    owner = self()
    first_handle = handle(ProviderA, :capability_revoked)

    assert_received {:transport_callback, ^token, ProviderA, :unsubscribe, ^owner,
                     [^first_handle]}

    assert_received {:transport_callback, ^token, ProviderA, :unsubscribe, ^owner,
                     ["other-owner-handle"]}
  end

  test "security regression: callbacks remain in the establishing owner and visible state has no delivery credential",
       %{fixture: fixture} do
    with_sync(:nonce_cache, [:nonce_seen], fn sync ->
      token = fixture.token
      owner = self()
      delivery_ref = Map.fetch!(fixture.refs, {ProviderA, :nonce_seen})

      assert_received {:transport_callback, ^token, ProviderA, :configured, ^owner, []}
      assert_received {:transport_callback, ^token, ProviderA, :role, ^owner, [:nonce_cache]}

      assert_received {:transport_callback, ^token, ProviderA, :subscribe, ^owner,
                       [:nonce_cache, :nonce_seen]}

      refute delivery_ref in visible_references(sync)
      assert SignalSync.admit_delivery?(sync, delivery_ref, %{data: %{}})
      refute SignalSync.admit_delivery?(sync, make_ref(), %{data: %{}})
      refute SignalSync.admit_delivery?(sync, sync.bus_monitor_ref, %{data: %{}})
    end)
  end

  test "security regression: one provider is pinned across subscription, admission, emission and release",
       %{fixture: fixture} do
    first =
      {:ok, handle(ProviderA, :capability_revoked), fixture.bus,
       Map.fetch!(fixture.refs, {ProviderA, :capability_revoked})}

    put_response({ProviderA, :subscribe, :capability_revoked}, {:swap_provider, ProviderB, first})
    put_response({ProviderB, :admit}, true)

    with_sync(:capability_store, [:capability_revoked, :identity_suspended], fn sync ->
      assert Application.fetch_env!(:arbor_security, :signal_transport) == ProviderB
      assert sync.transport == ProviderA
      assert SignalSync.admit_remote_security_mutation?(sync, :capability_revoked)
      refute SignalSync.admit_remote_security_mutation?(sync, :identity_resumed)

      data = %{capability_ids: ["cap_fixture"], origin_node: node()}
      opts = [scope: :cluster]
      assert :ok = SignalSync.emit(sync, :security, :capability_revoked, data, opts)

      token = fixture.token
      owner = self()

      assert_received {:transport_callback, ^token, ProviderA, :subscribe, ^owner,
                       [:capability_store, :identity_suspended]}

      assert_received {:transport_callback, ^token, ProviderA, :emit, ^owner,
                       [:security, :capability_revoked, ^data, ^opts]}

      assert_received {:transport_callback, ^token, ProviderA, :admit, ^owner,
                       [:capability_revoked]}

      assert_received {:transport_callback, ^token, ProviderA, :admit, ^owner,
                       [:identity_resumed]}

      assert :ok = release_current_sync()
      refute_received {:transport_callback, ^token, ProviderB, _callback, _caller, _args}

      for event <- [:capability_revoked, :identity_suspended] do
        handle = handle(ProviderA, event)
        assert_received {:transport_callback, ^token, ProviderA, :unsubscribe, ^owner, [^handle]}
      end
    end)
  end

  test "security regression: owner restart invalidates old references and resubscribes through the pinned provider",
       %{fixture: fixture} do
    with_sync(:nonce_cache, [:nonce_seen], fn sync ->
      Application.put_env(:arbor_security, :signal_transport, ProviderB)
      old_ref = Map.fetch!(fixture.refs, {ProviderA, :nonce_seen})
      assert SignalSync.admit_delivery?(sync, old_ref, %{data: %{}})

      stop_bus(fixture.bus)
      monitor_ref = sync.bus_monitor_ref
      bus = fixture.bus
      assert_receive {:DOWN, ^monitor_ref, :process, ^bus, :normal}, 1_000

      assert {:ok, down} =
               SignalSync.handle_info({:DOWN, monitor_ref, :process, bus, :normal}, sync)

      remember_sync(down)
      refute SignalSync.admit_delivery?(down, old_ref, %{data: %{}})

      replacement = start_bus()
      new_ref = make_ref()

      update_fixture(
        &%{&1 | bus: replacement, refs: Map.put(&1.refs, {ProviderA, :nonce_seen}, new_ref)}
      )

      assert_receive retry = {:arbor_security_sync_resubscribe, :nonce_cache, 1}, 1_000
      assert {:ok, restarted} = SignalSync.handle_info(retry, down)
      remember_sync(restarted)

      assert restarted.transport == ProviderA
      assert restarted.bus_pid == replacement
      assert restarted.resubscribe_attempt == 0
      refute SignalSync.admit_delivery?(restarted, old_ref, %{data: %{}})
      assert SignalSync.admit_delivery?(restarted, new_ref, %{data: %{}})

      token = fixture.token
      refute_received {:transport_callback, ^token, ProviderB, _callback, _caller, _args}
    end)
  end

  test "security regression: callback exceptions cannot widen remote admission or escape emission" do
    with_sync(:nonce_cache, [:nonce_seen], fn sync ->
      for failure <- [:raise, :throw, :exit] do
        put_response({ProviderA, :admit}, fault(failure))
        put_response({ProviderA, :emit}, fault(failure))
        refute SignalSync.admit_remote_security_mutation?(sync, :capability_revoked)
        assert {:error, _reason} = SignalSync.emit(sync, :security, :nonce_seen, %{}, [])
      end

      put_response({ProviderA, :admit}, :not_a_boolean)
      refute SignalSync.admit_remote_security_mutation?(sync, :capability_revoked)
      put_response({ProviderA, :emit}, :not_a_valid_effect)

      assert {:error, :invalid_security_sync_provider_response} =
               SignalSync.emit(sync, :security, :nonce_seen, %{}, [])
    end)
  end

  test "security regression: unavailable unsubscribe still releases private custody" do
    for failure <- [:raise, :throw, :exit] do
      with_sync(:nonce_cache, [:nonce_seen], fn _sync ->
        put_response({ProviderA, :unsubscribe}, fault(failure))
        assert :ok = release_current_sync()
        delete_response({ProviderA, :unsubscribe})

        assert {:ok, replacement} = SignalSync.establish(:nonce_cache, [:nonce_seen], true)
        remember_sync(replacement)
      end)
    end
  end

  test "security regression: transport selection cannot turn off the signed-request peer gate" do
    key = {Config, :test_inject_cluster_peers_present}
    previous = Process.get(key, :missing)

    try do
      :ok = Config.inject_test_cluster_peers_present(true)

      for transport <- [nil, ProviderA, ProviderB] do
        Application.put_env(:arbor_security, :signal_transport, transport)

        assert {:error, :cluster_replay_protection_unavailable} =
                 Config.admit_cluster_signed_request_replay_protection()
      end
    after
      if previous == :missing, do: Process.delete(key), else: Process.put(key, previous)
    end
  end

  @doc false
  def dispatch(provider, callback, args) do
    fixture = Application.fetch_env!(:arbor_security, @fixture_key)
    send(fixture.observer, {:transport_callback, fixture.token, provider, callback, self(), args})

    specific =
      case {callback, args} do
        {:subscribe, [_role, event]} -> {provider, callback, event}
        _ -> {provider, callback}
      end

    response =
      case Map.fetch(fixture.responses, specific) do
        {:ok, value} ->
          value

        :error ->
          Map.get_lazy(fixture.responses, {provider, callback}, fn ->
            default_response(provider, callback, args, fixture)
          end)
      end

    case response do
      {:raise, _reason} ->
        raise ArgumentError, "transport fixture rejected callback"

      {:throw, reason} ->
        throw(reason)

      {:exit, reason} ->
        exit(reason)

      {:swap_provider, replacement, value} ->
        Application.put_env(:arbor_security, :signal_transport, replacement)
        value

      value ->
        value
    end
  end

  defp default_response(_provider, callback, _args, _fixture)
       when callback in [:configured, :role],
       do: true

  defp default_response(provider, :subscribe, [_role, event], fixture),
    do: {:ok, handle(provider, event), fixture.bus, Map.fetch!(fixture.refs, {provider, event})}

  defp default_response(_provider, :admit, [event], _fixture), do: event == :capability_revoked
  defp default_response(_provider, _callback, _args, _fixture), do: :ok

  defp handle(provider, event), do: "opaque-#{provider}-#{event}"

  defp new_refs do
    Map.new(
      for provider <- [ProviderA, ProviderB],
          event <- @events,
          do: {{provider, event}, make_ref()}
    )
  end

  defp put_response(key, response),
    do: update_fixture(&%{&1 | responses: Map.put(&1.responses, key, response)})

  defp delete_response(key),
    do: update_fixture(&%{&1 | responses: Map.delete(&1.responses, key)})

  defp update_fixture(fun) do
    fixture = Application.fetch_env!(:arbor_security, @fixture_key)
    Application.put_env(:arbor_security, @fixture_key, fun.(fixture))
  end

  defp fault(:raise), do: {:raise, :fixture_failure}
  defp fault(:throw), do: {:throw, :fixture_failure}
  defp fault(:exit), do: {:exit, :fixture_failure}
  defp fault(:non_boolean), do: :not_a_boolean
  defp fault(nil), do: nil

  defp with_sync(role, events, fun) do
    assert {:ok, %SignalSync{} = sync} = SignalSync.establish(role, events, true)
    remember_sync(sync)

    try do
      fun.(sync)
    after
      assert :ok = release_current_sync()
    end
  end

  defp remember_sync(sync), do: Process.put(@owned_sync_key, sync)

  defp release_current_sync do
    case Process.delete(@owned_sync_key) do
      nil -> :ok
      sync -> SignalSync.release(sync)
    end
  end

  defp start_bus do
    owner = self()
    token = make_ref()

    bus =
      spawn(fn ->
        monitor = Process.monitor(owner)
        send(owner, {:fixture_bus_ready, token, self()})

        receive do
          {:fixture_bus_stop, ^token} -> :ok
          {:DOWN, ^monitor, :process, ^owner, _reason} -> :ok
        end
      end)

    assert_receive {:fixture_bus_ready, ^token, ^bus}, 1_000
    Process.put({__MODULE__, :bus, bus}, token)
    bus
  end

  defp stop_bus(bus) do
    token = Process.get({__MODULE__, :bus, bus})
    assert is_reference(token)
    send(bus, {:fixture_bus_stop, token})
  end

  defp visible_references(term) when is_reference(term), do: [term]

  defp visible_references(term) when is_map(term),
    do:
      Enum.flat_map(Map.to_list(term), fn {key, value} ->
        visible_references(key) ++ visible_references(value)
      end)

  defp visible_references(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.flat_map(&visible_references/1)

  defp visible_references(term) when is_list(term), do: Enum.flat_map(term, &visible_references/1)
  defp visible_references(_term), do: []
end
