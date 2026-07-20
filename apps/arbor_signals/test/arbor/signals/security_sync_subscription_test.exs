defmodule Arbor.Signals.SecuritySyncSubscriptionTest do
  use Arbor.Signals.TestCase

  @moduletag :fast

  alias Arbor.Signals
  alias Arbor.Signals.Bus

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
    original_authorizer = Application.get_env(:arbor_signals, :authorizer)
    original_allow_open = Application.get_env(:arbor_signals, :allow_open_authorizer)
    original_subscribers = Application.get_env(:arbor_signals, :security_sync_subscribers)

    Application.put_env(:arbor_signals, :authorizer, __MODULE__.DenyAuthorizer)
    Application.delete_env(:arbor_signals, :allow_open_authorizer)

    Application.put_env(
      :arbor_signals,
      :security_sync_subscribers,
      Map.new(@roles, fn {role, {owner, events}} ->
        {role, %{owner: owner, events: events}}
      end)
    )

    on_exit(fn ->
      restore_env(:authorizer, original_authorizer)
      restore_env(:allow_open_authorizer, original_allow_open)
      restore_env(:security_sync_subscribers, original_subscribers)
    end)

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

    assert {:ok, subscription_id, _bus_pid} =
             owner_subscribe(owner_pid, :nonce_cache, :nonce_seen)

    assert {:error, :not_found} = Signals.unsubscribe(subscription_id)
    assert Enum.any?(Bus.list_subscriptions(), &(&1.id == subscription_id))

    assert {:error, :unauthorized} = Signals.subscribe("security.*", fn _signal -> :ok end)
  end

  test "security regression: missing or malformed security-sync config fails closed" do
    owner_name = :"Elixir.Arbor.Security.Identity.NonceCache"
    owner_pid = start_registered_owner(owner_name)

    Application.delete_env(:arbor_signals, :security_sync_subscribers)
    assert {:error, :unauthorized} = owner_subscribe(owner_pid, :nonce_cache, :nonce_seen)

    Application.put_env(:arbor_signals, :security_sync_subscribers, %{
      nonce_cache: %{owner: owner_name, events: ["nonce_seen"]}
    })

    assert {:error, :unauthorized} = owner_subscribe(owner_pid, :nonce_cache, :nonce_seen)

    for malformed_event <- [:*, :"foo.bar"] do
      Application.put_env(:arbor_signals, :security_sync_subscribers, %{
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
          assert {:ok, subscription_id, bus_pid} = owner_subscribe(owner_pid, role, event)
          assert bus_pid == Process.whereis(Bus)
          {subscription_id, owner_pid, role, event}
        end)
      end)

    listed = Bus.list_subscriptions()

    for {subscription_id, owner_pid, role, event} <- subscriptions do
      subscription = Enum.find(listed, &(&1.id == subscription_id))

      assert subscription.pattern == "security.#{event}"
      assert subscription.principal_id == {:internal_security_sync, role}
      assert subscription.security_sync_owner == owner_pid
    end
  end

  test "security regression: owner exit removes stale internal subscriptions" do
    owner_pid = start_registered_owner(:"Elixir.Arbor.Security.Identity.NonceCache")

    assert {:ok, subscription_id, _bus_pid} =
             owner_subscribe(owner_pid, :nonce_cache, :nonce_seen)

    assert Enum.any?(Bus.list_subscriptions(), &(&1.id == subscription_id))

    Process.exit(owner_pid, :kill)

    assert eventually(fn ->
             not Enum.any?(Bus.list_subscriptions(), &(&1.id == subscription_id))
           end)
  end

  test "security regression: reset preserves live internal subscriptions and owner monitors" do
    owner_pid = start_registered_owner(:"Elixir.Arbor.Security.Identity.NonceCache")

    assert {:ok, internal_id, _bus_pid} =
             owner_subscribe(owner_pid, :nonce_cache, :nonce_seen)

    assert {:ok, ordinary_id} = Signals.subscribe("activity.reset_test", fn _signal -> :ok end)

    assert :ok = Bus.reset()

    subscriptions = Bus.list_subscriptions()
    assert Enum.any?(subscriptions, &(&1.id == internal_id))
    refute Enum.any?(subscriptions, &(&1.id == ordinary_id))

    assert :ok = Signals.emit(:security, :nonce_seen, %{}, scope: :local)
    assert_receive {:owner_received_signal, ^owner_pid, %{type: :nonce_seen}}

    Process.exit(owner_pid, :kill)

    assert eventually(fn ->
             not Enum.any?(Bus.list_subscriptions(), &(&1.id == internal_id))
           end)
  end

  defmodule DenyAuthorizer do
    @behaviour Arbor.Signals.Behaviours.SubscriptionAuthorizer

    @impl true
    def authorize_subscription(_principal_id, _topic), do: {:error, :unauthorized}
  end

  defp start_registered_owner(owner_name) do
    test_pid = self()

    owner_pid =
      spawn(fn ->
        true = Process.register(self(), owner_name)
        send(test_pid, {:security_sync_owner_ready, self()})
        owner_loop(test_pid)
      end)

    assert_receive {:security_sync_owner_ready, ^owner_pid}
    on_exit(fn -> if Process.alive?(owner_pid), do: Process.exit(owner_pid, :kill) end)
    owner_pid
  end

  defp owner_loop(test_pid) do
    receive do
      {:subscribe, reply_to, role, event} ->
        send(reply_to, {:subscribe_result, self(), Signals.subscribe_security_sync(role, event)})
        owner_loop(test_pid)

      {:signal_received, signal} ->
        send(test_pid, {:owner_received_signal, self(), signal})
        owner_loop(test_pid)
    end
  end

  defp owner_subscribe(owner_pid, role, event) do
    send(owner_pid, {:subscribe, self(), role, event})
    assert_receive {:subscribe_result, ^owner_pid, result}
    result
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

  defp restore_env(key, nil), do: Application.delete_env(:arbor_signals, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_signals, key, value)
end
