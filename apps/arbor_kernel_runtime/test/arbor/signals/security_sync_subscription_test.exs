defmodule Arbor.Signals.SecuritySyncSubscriptionTest do
  use Arbor.Signals.TestCase

  @moduletag :fast

  alias Arbor.Signals
  alias Arbor.Signals.Bus
  alias Arbor.Signals.Signal

  @authenticated_call_protocol :"$arbor_authenticated_call"

  @roles [
    nonce_cache: {
      :"Elixir.Arbor.Security.Identity.NonceCache",
      [:nonce_seen]
    },
    capability_store: {
      :"Elixir.Arbor.Security.CapabilityStore",
      [
        :capability_granted,
        :capability_revoked,
        :capabilities_revoked_all,
        :capabilities_cascade_revoked,
        :capabilities_scope_revoked
      ]
    },
    identity_registry: {
      :"Elixir.Arbor.Security.Identity.Registry",
      [
        :identity_registered,
        :identity_deregistered,
        :identity_suspended,
        :identity_resumed,
        :identity_revoked
      ]
    }
  ]

  setup do
    Arbor.Signals.Config.Testing.isolate_namespace()
    Arbor.Signals.Config.Testing.put(:authorizer, __MODULE__.DenyAuthorizer)
    Arbor.Signals.Config.Testing.delete(:allow_open_authorizer)

    Arbor.Signals.Config.Testing.put(
      :security_sync_subscribers,
      Map.new(@roles, fn {role, {owner, events}} ->
        {role,
         %{
           owner: owner,
           supervisor: self(),
           child_id: {:not_started, role},
           events: events
         }}
      end)
    )

    :ok
  end

  test "security regression: rejects unauthorized callers and non-allowlisted role events" do
    owner_pid = start_registered_owner(:"Elixir.Arbor.Security.Identity.NonceCache")

    # The local registered owner is trusted; callers cannot claim its role or
    # redirect delivery to themselves through this API.
    assert {:error, :unauthorized} = Signals.subscribe_security_sync(:nonce_cache, :nonce_seen)

    assert {:error, :unauthorized} =
             owner_subscribe(owner_pid, :nonce_cache, :identity_registered)

    assert {:error, :unauthorized} =
             owner_subscribe(owner_pid, :unknown_role, :nonce_seen)

    assert {:error, :unauthorized} =
             forged_call(Bus, owner_pid, {:subscribe_security_sync, :nonce_cache, :nonce_seen})

    assert {:ok, subscription_id, _bus_pid, delivery_ref} =
             owner_subscribe(owner_pid, :nonce_cache, :nonce_seen)

    assert is_reference(delivery_ref)

    assert {:error, :not_found} = Signals.unsubscribe(subscription_id)

    assert {:error, :not_found} =
             forged_call(Bus, owner_pid, {:unsubscribe, subscription_id})

    assert Enum.any?(Bus.list_subscriptions(), fn subscription ->
             subscription.pattern == "security.nonce_seen" and
               subscription.security_sync_owner == owner_pid
           end)

    assert Enum.all?(Bus.list_subscriptions(), &(not Map.has_key?(&1, :id)))

    assert {:error, :unauthorized} = Signals.subscribe("security.*", fn _signal -> :ok end)
  end

  test "security regression: a raw challenge cannot impersonate a sensitive sync owner" do
    owner_pid = start_registered_owner(:"Elixir.Arbor.Security.Identity.NonceCache")
    bus_pid = Process.whereis(Bus)
    reply_alias = :erlang.alias()
    request_ref = make_ref()
    caller_proof = :ets.new(__MODULE__, [:set, :private])

    on_exit(fn -> :erlang.unalias(reply_alias) end)

    send(owner_pid, {:block_mailbox, self()})
    assert_receive {:mailbox_blocked, ^owner_pid}

    true = :ets.give_away(caller_proof, owner_pid, :forged_authenticated_call)
    assert :ets.info(caller_proof, :owner) == owner_pid

    send(
      bus_pid,
      {@authenticated_call_protocol, :begin, owner_pid, request_ref, reply_alias, caller_proof,
       {:subscribe_security_sync, :nonce_cache, :nonce_seen}, 100}
    )

    assert eventually(fn ->
             state = :sys.get_state(bus_pid)
             :ets.info(state.authenticated_calls, :size) == 1
           end)

    assert {:messages, []} = Process.info(owner_pid, :messages)

    assert_raise ArgumentError, fn ->
      :ets.insert(caller_proof, {request_ref, :crypto.strong_rand_bytes(32)})
    end

    send(bus_pid, {
      :"ETS-TRANSFER",
      caller_proof,
      owner_pid,
      {@authenticated_call_protocol, :proof, request_ref, make_ref()}
    })

    assert_receive {@authenticated_call_protocol, :reply, ^bus_pid, ^request_ref,
                    {:error, :unauthorized}}

    refute Enum.any?(Bus.list_subscriptions(), fn subscription ->
             subscription.pattern == "security.nonce_seen" and
               subscription.security_sync_owner == owner_pid
           end)

    send(owner_pid, :release_mailbox)
  end

  test "security regression: raw calls cannot forge an authority-reducing publisher" do
    owner_pid = start_registered_owner(:"Elixir.Arbor.Security.CapabilityStore")

    assert {:ok, _subscription_handle, _bus_pid, _delivery_ref} =
             owner_subscribe(owner_pid, :capability_store, :capability_revoked)

    forged =
      Signal.new(:security, :capability_revoked, %{
        capability_ids: ["cap_raw_forged"],
        principal_id: "agent_victim"
      })

    assert {:error, :unauthorized} =
             forged_call(Bus, owner_pid, {:publish_local, forged})

    refute_receive {:owner_received_signal, ^owner_pid, %{type: :capability_revoked}}, 100

    assert :ok =
             owner_emit(
               owner_pid,
               :security,
               :capability_revoked,
               %{capability_ids: ["cap_legitimate"]},
               scope: :local
             )

    assert_receive {:owner_received_signal, ^owner_pid, %{type: :capability_revoked}}
  end

  test "security regression: public emit denies portable mutations when publisher config is invalid" do
    capability_owner_name = :"Elixir.Arbor.Security.CapabilityStore"
    nonce_owner_name = :"Elixir.Arbor.Security.Identity.NonceCache"
    capability_owner = start_registered_owner(capability_owner_name)
    nonce_owner = start_registered_owner(nonce_owner_name)

    assert {:ok, _subscription_handle, _bus_pid, _delivery_ref} =
             owner_subscribe(capability_owner, :capability_store, :capability_revoked)

    assert {:ok, _subscription_handle, _bus_pid, _delivery_ref} =
             owner_subscribe(nonce_owner, :nonce_cache, :nonce_seen)

    cases = [
      {:missing, :capability_revoked, capability_owner,
       fn ->
         Arbor.Signals.Config.Testing.delete(:security_sync_subscribers)
       end},
      {:missing_nonce, :nonce_seen, nonce_owner,
       fn ->
         Arbor.Signals.Config.Testing.delete(:security_sync_subscribers)
       end},
      {:malformed, :capability_revoked, capability_owner,
       fn ->
         Arbor.Signals.Config.Testing.put(:security_sync_subscribers, %{
           capability_store: %{owner: capability_owner_name, events: ["capability_revoked"]}
         })
       end},
      {:ambiguous, :capability_revoked, capability_owner,
       fn ->
         Arbor.Signals.Config.Testing.put(:security_sync_subscribers, %{
           capability_store: %{owner: capability_owner_name, events: [:capability_revoked]},
           conflicting_owner: %{owner: nonce_owner_name, events: [:capability_revoked]}
         })
       end}
    ]

    for {case_name, type, owner_pid, configure} <- cases do
      configure.()
      marker = "#{case_name}-#{System.unique_integer([:positive])}"
      before_stats = Signals.stats()

      assert {:error, :unauthorized} =
               Signals.emit(
                 :security,
                 type,
                 %{marker: marker},
                 scope: :cluster,
                 async: false
               )

      refute_receive {:owner_received_signal, ^owner_pid, %{type: ^type}}, 100
      after_stats = Signals.stats()

      assert after_stats.bus.total_published == before_stats.bus.total_published
      assert after_stats.relay.relayed_out == before_stats.relay.relayed_out
      assert after_stats.relay.batch_pending == before_stats.relay.batch_pending

      assert {:ok, recent} = Signals.recent(category: :security, type: type, limit: 100)
      refute Enum.any?(recent, &(Map.get(&1.data, :marker) == marker))
    end
  end

  test "security observability events remain available without publisher config" do
    Arbor.Signals.Config.Testing.delete(:security_sync_subscribers)
    before_published = Signals.stats().bus.total_published

    assert :ok =
             Signals.emit(
               :security,
               :publisher_config_observability_probe,
               %{},
               scope: :local,
               async: false
             )

    assert Signals.stats().bus.total_published == before_published + 1

    assert {:ok, [%Signal{type: :publisher_config_observability_probe} | _]} =
             Signals.recent(
               category: :security,
               type: :publisher_config_observability_probe,
               limit: 1
             )
  end

  test "security regression: empty subscriber map is unconfigured local-only transport" do
    Arbor.Signals.Config.Testing.delete(:security_sync_subscribers)
    refute Arbor.Signals.Config.security_sync_transport_configured?()
    refute Arbor.Signals.Config.security_sync_role_configured?(:nonce_cache)
    refute Arbor.Signals.authenticated_security_sync_transport?()

    Arbor.Signals.Config.Testing.put(:security_sync_subscribers, %{})
    refute Arbor.Signals.Config.security_sync_transport_configured?()
    refute Arbor.Signals.Config.security_sync_role_configured?(:nonce_cache)
    refute Arbor.Signals.authenticated_security_sync_transport?()
  end

  test "security regression: configured subscriber map is not authenticated transport" do
    assert Arbor.Signals.Config.security_sync_transport_configured?()
    refute Arbor.Signals.Config.authenticated_security_sync_transport?()
    refute Arbor.Signals.authenticated_security_sync_transport?()
  end

  test "security regression: missing or malformed security-sync config fails closed" do
    owner_name = :"Elixir.Arbor.Security.Identity.NonceCache"
    owner_pid = start_registered_owner(owner_name)

    Arbor.Signals.Config.Testing.delete(:security_sync_subscribers)
    assert {:error, :unauthorized} = owner_subscribe(owner_pid, :nonce_cache, :nonce_seen)

    Arbor.Signals.Config.Testing.put(:security_sync_subscribers, %{
      nonce_cache: %{owner: owner_name, events: ["nonce_seen"]}
    })

    assert {:error, :unauthorized} = owner_subscribe(owner_pid, :nonce_cache, :nonce_seen)

    for malformed_event <- [:*, :"foo.bar"] do
      Arbor.Signals.Config.Testing.put(:security_sync_subscribers, %{
        nonce_cache: %{owner: owner_name, events: [malformed_event]}
      })

      assert {:error, :unauthorized} =
               owner_subscribe(owner_pid, :nonce_cache, malformed_event)
    end
  end

  test "security regression: exact registered owners can subscribe only to their fixed events" do
    subscriptions =
      Enum.flat_map(@roles, fn {role, {owner_name, events}} ->
        owner_pid = start_registered_owner(owner_name)

        Enum.map(events, fn event ->
          assert {:ok, subscription_id, bus_pid, delivery_ref} =
                   owner_subscribe(owner_pid, role, event)

          assert bus_pid == Process.whereis(Bus)
          assert is_reference(delivery_ref)
          {subscription_id, owner_pid, role, event}
        end)
      end)

    listed = Bus.list_subscriptions()

    for {_subscription_handle, owner_pid, role, event} <- subscriptions do
      subscription =
        Enum.find(listed, fn listed_subscription ->
          listed_subscription.pattern == "security.#{event}" and
            listed_subscription.security_sync_owner == owner_pid
        end)

      assert subscription.pattern == "security.#{event}"
      assert subscription.principal_id == {:internal_security_sync, role}
      assert subscription.security_sync_owner == owner_pid
      refute Map.has_key?(subscription, :id)
      refute Map.has_key?(subscription, :unsubscribe_digest)
    end
  end

  test "security regression: owner exit removes stale internal subscriptions" do
    owner_pid = start_registered_owner(:"Elixir.Arbor.Security.Identity.NonceCache")

    assert {:ok, _subscription_handle, _bus_pid, _delivery_ref} =
             owner_subscribe(owner_pid, :nonce_cache, :nonce_seen)

    assert Enum.any?(Bus.list_subscriptions(), fn subscription ->
             subscription.pattern == "security.nonce_seen" and
               subscription.security_sync_owner == owner_pid
           end)

    Process.exit(owner_pid, :kill)

    assert eventually(fn ->
             not Enum.any?(Bus.list_subscriptions(), fn subscription ->
               subscription.pattern == "security.nonce_seen" and
                 subscription.security_sync_owner == owner_pid
             end)
           end)
  end

  test "security regression: reset preserves live internal subscriptions and owner monitors" do
    owner_pid = start_registered_owner(:"Elixir.Arbor.Security.Identity.NonceCache")

    assert {:ok, internal_id, _bus_pid, _delivery_ref} =
             owner_subscribe(owner_pid, :nonce_cache, :nonce_seen)

    assert {:ok, ordinary_id} = Signals.subscribe("activity.reset_test", fn _signal -> :ok end)

    assert :ok = Bus.reset()

    subscriptions = Bus.list_subscriptions()

    assert Enum.any?(subscriptions, fn subscription ->
             subscription.pattern == "security.nonce_seen" and
               subscription.security_sync_owner == owner_pid
           end)

    refute Enum.any?(subscriptions, &(&1.pattern == "activity.reset_test"))
    assert is_binary(internal_id)
    assert is_binary(ordinary_id)

    assert :ok = owner_emit(owner_pid, :security, :nonce_seen, %{}, scope: :local)
    assert_receive {:owner_received_signal, ^owner_pid, %{type: :nonce_seen}}

    Process.exit(owner_pid, :kill)

    assert eventually(fn ->
             not Enum.any?(Bus.list_subscriptions(), fn subscription ->
               subscription.pattern == "security.nonce_seen" and
                 subscription.security_sync_owner == owner_pid
             end)
           end)
  end

  test "security regression: a registered-name thief cannot become a security-sync owner" do
    owner_name = :"Elixir.Arbor.Security.Identity.NonceCache"
    owner_pid = start_registered_owner(owner_name)

    assert Process.unregister(owner_name)

    result =
      Task.async(fn ->
        true = Process.register(self(), owner_name)

        try do
          Signals.subscribe_security_sync(:nonce_cache, :nonce_seen)
        after
          if Process.whereis(owner_name) == self(), do: Process.unregister(owner_name)
        end
      end)
      |> Task.await()

    assert {:error, :unauthorized} = result
    assert Process.register(owner_pid, owner_name)
  end

  test "security regression: a registered-name thief cannot impersonate the Bus handshake" do
    owner_pid = start_registered_owner(:"Elixir.Arbor.Security.Identity.NonceCache")
    bus_pid = Process.whereis(Bus)
    assert Process.unregister(Bus)

    test_pid = self()

    impostor =
      spawn(fn ->
        true = Process.register(self(), Bus)
        send(test_pid, {:bus_impostor_ready, self()})
        bus_impostor_loop()
      end)

    assert_receive {:bus_impostor_ready, ^impostor}

    on_exit(fn ->
      if Process.alive?(impostor), do: Process.exit(impostor, :kill)

      if Process.alive?(bus_pid) and Process.whereis(Bus) == nil do
        Process.register(bus_pid, Bus)
      end
    end)

    result =
      try do
        owner_subscribe(owner_pid, :nonce_cache, :nonce_seen)
      after
        Process.exit(impostor, :kill)
        assert eventually(fn -> Process.whereis(Bus) == nil end)
        Process.register(bus_pid, Bus)
      end

    assert {:error, :unauthorized} = result
  end

  defmodule DenyAuthorizer do
    @behaviour Arbor.Signals.Behaviours.SubscriptionAuthorizer

    @impl true
    def authorize_subscription(_principal_id, _topic), do: {:error, :unauthorized}
  end

  defmodule TestOwner do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
    end

    @impl true
    def init(opts) do
      Process.flag(:sensitive, true)
      {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid)}}
    end

    @impl true
    def handle_info({:subscribe, reply_to, role, event}, state) do
      send(reply_to, {
        :subscribe_result,
        self(),
        Arbor.Signals.subscribe_security_sync(role, event)
      })

      {:noreply, state}
    end

    def handle_info({:signal_received, _delivery_ref, signal}, state) do
      send(state.test_pid, {:owner_received_signal, self(), signal})
      {:noreply, state}
    end

    def handle_info({:emit, reply_to, category, type, data, opts}, state) do
      send(reply_to, {:emit_result, self(), Arbor.Signals.emit(category, type, data, opts)})
      {:noreply, state}
    end

    def handle_info({:block_mailbox, reply_to}, state) do
      send(reply_to, {:mailbox_blocked, self()})

      receive do
        :release_mailbox -> :ok
      end

      {:noreply, state}
    end

    def handle_info(_message, state), do: {:noreply, state}
  end

  defp start_registered_owner(owner_name) do
    {role, {_owner, events}} =
      Enum.find(@roles, fn {_role, {owner, _events}} -> owner == owner_name end)

    child_id = {owner_name, System.unique_integer([:positive])}

    child_spec =
      Supervisor.child_spec(
        {TestOwner, name: owner_name, test_pid: self()},
        id: child_id
      )

    {:ok, supervisor} = Supervisor.start_link([child_spec], strategy: :one_for_one)
    owner_pid = Process.whereis(owner_name)

    subscribers = Arbor.Signals.Config.Testing.get(:security_sync_subscribers)

    Arbor.Signals.Config.Testing.put(
      :security_sync_subscribers,
      Map.put(subscribers, role, %{
        owner: owner_name,
        supervisor: supervisor,
        child_id: child_id,
        events: events
      })
    )

    on_exit(fn -> stop_supervisor_if_alive(supervisor) end)
    owner_pid
  end

  defp stop_supervisor_if_alive(supervisor) do
    if Process.alive?(supervisor) do
      try do
        Supervisor.stop(supervisor)
      catch
        :exit, _reason -> :ok
      end
    end
  end

  defp owner_subscribe(owner_pid, role, event) do
    send(owner_pid, {:subscribe, self(), role, event})
    assert_receive {:subscribe_result, ^owner_pid, result}
    result
  end

  defp owner_emit(owner_pid, category, type, data, opts) do
    send(owner_pid, {:emit, self(), category, type, data, opts})
    assert_receive {:emit_result, ^owner_pid, result}
    result
  end

  defp bus_impostor_loop do
    receive do
      {:"$gen_call", from, {:subscribe_security_sync, _role, _event}} ->
        GenServer.reply(from, {:ok, "sub_impostor", self(), make_ref()})
        bus_impostor_loop()

      _message ->
        bus_impostor_loop()
    end
  end

  defp forged_call(server, asserted_pid, message) do
    reply = :erlang.alias()
    tag = [:alias | reply]
    send(server, {:"$gen_call", {asserted_pid, tag}, message})

    try do
      receive do
        {^tag, result} -> result
      after
        2_000 -> flunk("forged Bus call did not settle")
      end
    after
      :erlang.unalias(reply)
    end
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
