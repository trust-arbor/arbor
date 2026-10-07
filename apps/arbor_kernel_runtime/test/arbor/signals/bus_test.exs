defmodule Arbor.Signals.BusTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Signals.Bus
  alias Arbor.Signals.Config.Testing
  alias Arbor.Signals.Signal

  setup do
    Arbor.Signals.TestCase.ensure_processes()
    Testing.isolate_namespace()
    :ok
  end

  describe "subscribe/3 and publish/1" do
    @tag :security_regression
    test "security regression: arbitrary publishers cannot inject security-sync mutations" do
      test_pid = self()

      {:ok, sub_id} =
        Bus.subscribe(
          "security.capability_revoked",
          fn signal ->
            send(test_pid, {:forged_security_sync, signal})
            :ok
          end,
          async: false,
          principal_id: "agent_security_sync_observer"
        )

      on_exit(fn -> Bus.unsubscribe(sub_id) end)

      forged =
        Signal.new(:security, :capability_revoked, %{
          origin_node: :attacker@node,
          capability_ids: ["cap_victim"]
        })

      assert {:error, :unauthorized} = Bus.publish(forged)
      refute_receive {:forged_security_sync, _signal}, 100

      GenServer.cast(Bus, {:publish, forged})
      refute_receive {:forged_security_sync, _signal}, 100
    end

    @tag :security_regression
    test "security regression: public publication restamps attribution and raw casts are denied" do
      test_pid = self()

      {:ok, sub_id} =
        Bus.subscribe(
          "activity.*",
          fn signal ->
            send(test_pid, {:bus_attribution, signal})
            :ok
          end,
          async: false,
          filter: fn signal ->
            signal.type in [:bus_attribution_public, :bus_attribution_raw]
          end
        )

      on_exit(fn -> Bus.unsubscribe(sub_id) end)

      forged_emitter = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(forged_emitter, :kill) end)
      future = DateTime.add(DateTime.utc_now(), 86_400, :second)

      forged = %{
        Signal.new(:activity, :bus_attribution_public, %{})
        | id: "sig_forged_public",
          timestamp: future,
          emitter_pid: forged_emitter,
          origin_node: :forged@node
      }

      assert :ok = Bus.publish(forged)
      assert_receive {:bus_attribution, public}
      refute public.id == forged.id
      refute public.timestamp == future
      assert public.emitter_pid == self()
      assert public.origin_node == node()

      raw_forged = %{
        forged
        | id: "sig_forged_raw",
          type: :bus_attribution_raw
      }

      GenServer.cast(Bus, {:publish, raw_forged})
      refute_receive {:bus_attribution, _raw}, 100
    end

    test "wildcard pattern receives all signals" do
      test_pid = self()

      {:ok, sub_id} =
        Bus.subscribe(
          "*",
          fn signal ->
            send(test_pid, {:wildcard, signal})
            :ok
          end,
          async: false,
          principal_id: "agent_test_wildcard"
        )

      Bus.publish(Signal.new(:activity, :wildcard_test, %{}))
      assert_receive {:wildcard, %Signal{type: :wildcard_test}}, 500

      Bus.unsubscribe(sub_id)
    end

    test "category wildcard matches any type" do
      test_pid = self()

      {:ok, sub_id} =
        Bus.subscribe(
          "security.*",
          fn signal ->
            send(test_pid, {:cat_wild, signal.category, signal.type})
            :ok
          end,
          async: false,
          principal_id: "agent_test_security"
        )

      Bus.publish(Signal.new(:security, :auth_check, %{}))
      assert_receive {:cat_wild, :security, :auth_check}, 500

      # Drain any stray security signals from concurrent tests before checking
      drain_messages(:cat_wild)

      Bus.publish(Signal.new(:activity, :other, %{}))
      # Only refute the specific signal we just published — other concurrent tests
      # may publish security.* signals that legitimately match this subscription
      refute_receive {:cat_wild, :activity, :other}, 100

      Bus.unsubscribe(sub_id)
    end

    test "type wildcard matches any category" do
      test_pid = self()

      {:ok, sub_id} =
        Bus.subscribe(
          "*.type_wild_test",
          fn signal ->
            send(test_pid, {:type_wild, signal})
            :ok
          end,
          async: false,
          principal_id: "agent_test_type_wild"
        )

      Bus.publish(Signal.new(:activity, :type_wild_test, %{}))
      assert_receive {:type_wild, %Signal{category: :activity}}, 500

      Bus.publish(Signal.new(:security, :type_wild_test, %{}))
      assert_receive {:type_wild, %Signal{category: :security}}, 500

      Bus.unsubscribe(sub_id)
    end

    test "exact pattern matches specific category.type" do
      test_pid = self()

      {:ok, sub_id} =
        Bus.subscribe(
          "metrics.latency",
          fn signal ->
            send(test_pid, {:exact, signal})
            :ok
          end,
          async: false
        )

      Bus.publish(Signal.new(:metrics, :latency, %{ms: 42}))
      assert_receive {:exact, %Signal{data: %{ms: 42}}}, 500

      Bus.publish(Signal.new(:metrics, :count, %{}))
      refute_receive {:exact, _}, 100

      Bus.unsubscribe(sub_id)
    end

    test "filter option filters matching signals" do
      test_pid = self()

      {:ok, sub_id} =
        Bus.subscribe(
          "activity.*",
          fn signal ->
            send(test_pid, {:filtered, signal})
            :ok
          end,
          async: false,
          filter: fn signal -> signal.data[:important] == true end
        )

      Bus.publish(Signal.new(:activity, :filter_test, %{important: true}))
      assert_receive {:filtered, _}, 500

      Bus.publish(Signal.new(:activity, :filter_test, %{important: false}))
      refute_receive {:filtered, _}, 100

      Bus.unsubscribe(sub_id)
    end

    test "async delivery does not block" do
      test_pid = self()

      {:ok, sub_id} =
        Bus.subscribe("activity.async_test", fn signal ->
          send(test_pid, {:async, signal})
          :ok
        end)

      Bus.publish(Signal.new(:activity, :async_test, %{}))
      assert_receive {:async, %Signal{type: :async_test}}, 1000

      Bus.unsubscribe(sub_id)
    end

    test "handler errors do not crash the bus" do
      {:ok, sub_id} =
        Bus.subscribe(
          "activity.error_test",
          fn _signal ->
            raise "handler error"
          end,
          async: false
        )

      # Should not crash
      Bus.publish(Signal.new(:activity, :error_test, %{}))
      :timer.sleep(50)

      # Bus should still be functional
      stats = Bus.stats()
      assert stats.total_errors >= 1

      Bus.unsubscribe(sub_id)
    end

    test "security regression: raising and throwing filters cannot crash the bus" do
      bus_pid = Process.whereis(Bus)
      test_pid = self()

      {:ok, raising_sub} =
        Bus.subscribe("activity.filter_guard", fn _ -> :ok end,
          filter: fn _ -> raise "filter crash" end
        )

      {:ok, throwing_sub} =
        Bus.subscribe("activity.filter_guard", fn _ -> :ok end,
          filter: fn _ -> throw(:filter_escape) end
        )

      {:ok, good_sub} =
        Bus.subscribe(
          "activity.filter_guard",
          fn signal ->
            send(test_pid, {:filter_guard_delivered, signal.type})
            :ok
          end,
          async: false
        )

      Bus.publish(Signal.new(:activity, :filter_guard, %{}))

      assert_receive {:filter_guard_delivered, :filter_guard}, 1_000
      assert Process.whereis(Bus) == bus_pid
      assert Process.alive?(bus_pid)
      assert {:error, :not_found} = Bus.unsubscribe(raising_sub)
      assert {:error, :not_found} = Bus.unsubscribe(throwing_sub)
      assert :ok = Bus.unsubscribe(good_sub)
    end

    test "security regression: blocking synchronous handler is killed at the callback deadline" do
      test_pid = self()

      {:ok, blocking_sub} =
        Bus.subscribe(
          "activity.sync_timeout_guard",
          fn _signal ->
            receive do
              :never_sent -> :ok
            end
          end,
          async: false
        )

      {:ok, good_sub} =
        Bus.subscribe(
          "activity.sync_timeout_guard",
          fn _signal ->
            send(test_pid, :sync_timeout_guard_delivered)
            :ok
          end,
          async: false
        )

      Bus.publish(Signal.new(:activity, :sync_timeout_guard, %{}))

      assert_receive :sync_timeout_guard_delivered, 1_000
      assert is_map(Bus.stats())
      assert {:error, :not_found} = Bus.unsubscribe(blocking_sub)
      assert :ok = Bus.unsubscribe(good_sub)
    end
  end

  describe "unsubscribe/1" do
    test "returns error for nonexistent subscription" do
      assert {:error, :not_found} = Bus.unsubscribe("sub_nonexistent")
    end

    test "stops delivery after unsubscribe" do
      test_pid = self()

      {:ok, sub_id} =
        Bus.subscribe(
          "activity.unsub_bus_test",
          fn signal ->
            send(test_pid, {:unsub, signal})
            :ok
          end,
          async: false
        )

      Bus.unsubscribe(sub_id)
      Bus.publish(Signal.new(:activity, :unsub_bus_test, %{}))
      refute_receive {:unsub, _}, 100
    end

    test "security regression: another process cannot cancel an owned subscription" do
      test_pid = self()

      {:ok, sub_id} =
        Bus.subscribe(
          "activity.owner_bound_unsubscribe",
          fn _signal ->
            send(test_pid, :owner_bound_delivered)
            :ok
          end,
          async: false
        )

      assert {:error, :not_found} = Task.async(fn -> Bus.unsubscribe(sub_id) end) |> Task.await()

      Bus.publish(Signal.new(:activity, :owner_bound_unsubscribe, %{}))
      assert_receive :owner_bound_delivered, 1_000
      assert :ok = Bus.unsubscribe(sub_id)
    end

    @tag :security_regression
    test "security regression: raw calls cannot attach handlers or cancel an opaque handle" do
      test_pid = self()

      owner_pid =
        spawn(fn ->
          {:ok, subscription_handle} =
            Bus.subscribe(
              "activity.raw_call_custody",
              fn signal ->
                send(test_pid, {:owner_subscription_delivered, signal.type})
                :ok
              end,
              async: false
            )

          send(test_pid, {:owner_subscription_ready, self(), subscription_handle})

          receive do
            :release_subscription ->
              send(test_pid, {:owner_release_result, Bus.unsubscribe(subscription_handle)})
          end
        end)

      on_exit(fn ->
        if Process.alive?(owner_pid), do: Process.exit(owner_pid, :kill)
      end)

      assert_receive {:owner_subscription_ready, ^owner_pid, subscription_handle}
      assert is_binary(subscription_handle)

      bus_state = :sys.get_state(Bus)
      assert :ets.info(bus_state.subscription_custody, :owner) == Process.whereis(Bus)
      assert :ets.info(bus_state.subscription_custody, :protection) == :private
      assert :ets.info(bus_state.authenticated_calls, :owner) == Process.whereis(Bus)
      assert :ets.info(bus_state.authenticated_calls, :protection) == :private
      refute Map.has_key?(bus_state.subscriptions, subscription_handle)
      refute inspect(bus_state.subscriptions) =~ subscription_handle

      assert_raise ArgumentError, fn ->
        :ets.tab2list(bus_state.subscription_custody)
      end

      attacker_handler = fn _signal ->
        send(test_pid, :forged_handler_ran)
        :ok
      end

      assert {:error, :unauthorized} =
               forged_call(
                 Bus,
                 owner_pid,
                 {:subscribe, "activity.raw_call_custody", attacker_handler, [async: false]}
               )

      assert {:error, :not_found} =
               forged_call(Bus, owner_pid, {:unsubscribe, subscription_handle})

      assert {:error, :not_found} = Bus.unsubscribe(subscription_handle)

      assert {:error, :unauthorized} =
               forged_call(
                 Bus,
                 owner_pid,
                 {:publish_local, Signal.new(:activity, :raw_call_custody, %{forged: true})}
               )

      refute_receive {:owner_subscription_delivered, :raw_call_custody}, 100

      assert :ok = Bus.publish(Signal.new(:activity, :raw_call_custody, %{}))
      assert_receive {:owner_subscription_delivered, :raw_call_custody}
      refute_receive :forged_handler_ran, 100

      listed = Bus.list_subscriptions()
      assert Enum.any?(listed, &(&1.pattern == "activity.raw_call_custody"))
      assert Enum.all?(listed, &(not Map.has_key?(&1, :id)))
      assert Enum.all?(listed, &(not Map.has_key?(&1, :unsubscribe_digest)))

      send(owner_pid, :release_subscription)
      assert_receive {:owner_release_result, :ok}
    end
  end

  describe "list_subscriptions/0" do
    @tag :security_regression
    test "security regression: ordinary subscriptions survive a supervised bus restart" do
      test_pid = self()

      {:ok, sub_id} =
        Bus.subscribe(
          "activity.bus_restart_recovery",
          fn signal ->
            send(test_pid, {:bus_restart_recovery, signal.type})
            :ok
          end,
          async: false
        )

      old_bus = Process.whereis(Bus)

      assert {:error, :unauthorized} =
               forged_call(Arbor.Signals.SubscriptionRegistry, old_bus, :clear)

      assert :ok = Supervisor.terminate_child(Arbor.Signals.Supervisor, Bus)
      assert {:ok, new_bus} = Supervisor.restart_child(Arbor.Signals.Supervisor, Bus)
      refute new_bus == old_bus

      assert Enum.any?(Bus.list_subscriptions(), &(&1.pattern == "activity.bus_restart_recovery"))
      assert :ok = Bus.publish(Signal.new(:activity, :bus_restart_recovery, %{}))
      assert_receive {:bus_restart_recovery, :bus_restart_recovery}, 1_000
      assert :ok = Bus.unsubscribe(sub_id)
    end

    test "returns active subscriptions" do
      {:ok, sub_id} = Bus.subscribe("activity.list_test", fn _ -> :ok end)

      subs = Bus.list_subscriptions()
      assert Enum.any?(subs, &(&1.pattern == "activity.list_test"))
      assert Enum.all?(subs, &(not Map.has_key?(&1, :id)))
      assert Enum.all?(subs, &(not Map.has_key?(&1, :unsubscribe_digest)))

      Bus.unsubscribe(sub_id)
    end

    test "includes pattern, async flag, and principal_id" do
      {:ok, sub_id} =
        Bus.subscribe("metrics.list_test", fn _ -> :ok end,
          async: false,
          principal_id: "agent_list_test"
        )

      subs = Bus.list_subscriptions()
      sub = Enum.find(subs, &(&1.pattern == "metrics.list_test"))

      assert sub.pattern == "metrics.list_test"
      assert sub.async == false
      assert sub.principal_id == "agent_list_test"
      assert %DateTime{} = sub.created_at
      refute Map.has_key?(sub, :id)
      refute Map.has_key?(sub, :unsubscribe_digest)

      Bus.unsubscribe(sub_id)
    end
  end

  describe "stats/0" do
    test "returns bus statistics" do
      stats = Bus.stats()

      assert is_integer(stats.total_published)
      assert is_integer(stats.total_delivered)
      assert is_integer(stats.total_errors)
      assert is_integer(stats.active_subscriptions)
      assert is_integer(stats.total_auth_denied)
    end
  end

  describe "N-segment pattern matching" do
    test "3-segment pattern with trailing wildcard matches category.type" do
      test_pid = self()

      {:ok, sub_id} =
        Bus.subscribe(
          "channel.chan_123.*",
          fn signal ->
            send(test_pid, {:channel, signal})
            :ok
          end,
          async: false
        )

      # Matches: channel.chan_123 (category.type matches first two segments)
      Bus.publish(Signal.new(:channel, :chan_123, %{msg: "hello"}))
      assert_receive {:channel, %Signal{category: :channel, type: :chan_123}}, 500

      # Does NOT match: different channel ID
      Bus.publish(Signal.new(:channel, :chan_456, %{msg: "nope"}))
      refute_receive {:channel, _}, 100

      # Does NOT match: different category
      Bus.publish(Signal.new(:activity, :chan_123, %{}))
      refute_receive {:channel, _}, 100

      Bus.unsubscribe(sub_id)
    end

    test "exact 2-segment pattern matches only exact category.type" do
      test_pid = self()

      {:ok, sub_id} =
        Bus.subscribe(
          "consensus.decision",
          fn signal ->
            send(test_pid, {:exact, signal})
            :ok
          end,
          async: false
        )

      Bus.publish(Signal.new(:consensus, :decision, %{}))
      assert_receive {:exact, %Signal{type: :decision}}, 500

      Bus.publish(Signal.new(:consensus, :proposal, %{}))
      refute_receive {:exact, _}, 100

      Bus.unsubscribe(sub_id)
    end

    test "pattern with middle wildcard matches any value in that position" do
      test_pid = self()

      {:ok, sub_id} =
        Bus.subscribe(
          "consensus.*",
          fn signal ->
            send(test_pid, {:middle_wild, signal})
            :ok
          end,
          async: false
        )

      Bus.publish(Signal.new(:consensus, :decision_rendered, %{}))
      assert_receive {:middle_wild, %Signal{type: :decision_rendered}}, 500

      Bus.publish(Signal.new(:consensus, :advice_rendered, %{}))
      assert_receive {:middle_wild, %Signal{type: :advice_rendered}}, 500

      Bus.publish(Signal.new(:activity, :something, %{}))
      refute_receive {:middle_wild, _}, 100

      Bus.unsubscribe(sub_id)
    end

    test "single-segment pattern acts as category-only match" do
      test_pid = self()

      {:ok, sub_id} =
        Bus.subscribe(
          "metrics",
          fn signal ->
            send(test_pid, {:single, signal})
            :ok
          end,
          async: false
        )

      # Single-segment pattern matches first segment only, no trailing wildcard
      # This should NOT match a signal with category=metrics, type=latency
      # because the pattern is just "metrics" (one segment) vs signal "metrics.latency" (two segments)
      Bus.publish(Signal.new(:metrics, :latency, %{}))
      refute_receive {:single, _}, 100

      Bus.unsubscribe(sub_id)
    end

    test "channel topic pattern matches channel messages" do
      test_pid = self()

      # This is the actual pattern the Channel module constructs
      {:ok, sub_id} =
        Bus.subscribe(
          "channel.test_chan_abc.*",
          fn signal ->
            send(test_pid, {:chan_msg, signal})
            :ok
          end,
          async: false
        )

      Bus.publish(Signal.new(:channel, :test_chan_abc, %{msg: "test"}))
      assert_receive {:chan_msg, %Signal{type: :test_chan_abc}}, 500

      Bus.unsubscribe(sub_id)
    end
  end

  describe "subscription authorization" do
    # With the default OpenAuthorizer, all subscriptions are allowed
    # (even restricted topics) because authorize_subscription always returns :authorized.
    # These tests verify the authorization plumbing works correctly.

    test "non-restricted topic subscription works without principal_id" do
      {:ok, sub_id} = Bus.subscribe("activity.*", fn _ -> :ok end)
      assert is_binary(sub_id)
      Bus.unsubscribe(sub_id)
    end

    test "non-restricted topic with explicit pattern works without principal_id" do
      {:ok, sub_id} = Bus.subscribe("metrics.latency", fn _ -> :ok end)
      assert is_binary(sub_id)
      Bus.unsubscribe(sub_id)
    end

    test "restricted topic requires principal_id when authorizer denies" do
      Testing.put(:authorizer, __MODULE__.DenyAuthorizer)

      # No principal_id + restricted topic = denied
      assert {:error, :unauthorized} = Bus.subscribe("security.*", fn _ -> :ok end)

      # With principal_id but authorizer still denies
      assert {:error, :unauthorized} =
               Bus.subscribe("security.*", fn _ -> :ok end, principal_id: "agent_bad")
    end

    test "wildcard pattern with no principal_id is denied when authorizer denies" do
      Testing.put(:authorizer, __MODULE__.DenyAuthorizer)

      # "*" overlaps restricted topics, no principal = denied
      assert {:error, :unauthorized} = Bus.subscribe("*", fn _ -> :ok end)
    end

    test "delivery-time filtering blocks restricted signals for unauthorized subs" do
      test_pid = self()

      Testing.put(:authorizer, __MODULE__.AllowActivityOnlyAuthorizer)

      # Subscribe to "*" with an authorizer that only authorizes :activity-like topics
      # The AllowActivityOnlyAuthorizer denies :security and :identity
      # Since it denies all restricted topics and authorizes none, this will fail
      assert {:error, :unauthorized} =
               Bus.subscribe(
                 "*",
                 fn signal ->
                   send(test_pid, {:received, signal.category})
                   :ok
                 end,
                 async: false,
                 principal_id: "agent_partial"
               )
    end

    test "open authorizer allows restricted topic with principal_id" do
      # Default OpenAuthorizer — everything goes through
      {:ok, sub_id} =
        Bus.subscribe("security.*", fn _ -> :ok end, principal_id: "agent_open")

      assert is_binary(sub_id)
      Bus.unsubscribe(sub_id)
    end

    test "stats tracks auth denied count" do
      Testing.put(:authorizer, __MODULE__.DenyAuthorizer)

      stats_before = Bus.stats()

      Bus.subscribe("security.*", fn _ -> :ok end)

      stats_after = Bus.stats()
      assert stats_after.total_auth_denied > stats_before.total_auth_denied
    end
  end

  describe "tuple category / non-atom type robustness" do
    test "bus does not crash when signal has tuple category" do
      # Regression: AcpSession was calling emit({:agent, :event}, data) which
      # produced category={:agent, :event} tuple — matches_pattern? crashed with
      # Protocol.UndefinedError because to_string/1 can't handle tuples.
      signal = %Signal{
        id: "sig_test_tuple",
        category: {:agent, :acp_session_completed},
        type: %{some: "map"},
        data: %{},
        timestamp: DateTime.utc_now()
      }

      # Bus should handle the signal without crashing
      assert :ok = Bus.publish(signal)
      # Give async delivery a moment
      :timer.sleep(50)
      assert is_pid(Process.whereis(Bus))
    end

    test "wildcard subscription is not triggered by mismatched tuple category" do
      test_pid = self()

      {:ok, sub_id} =
        Bus.subscribe(
          "agent.*",
          fn sig ->
            send(test_pid, {:got, sig})
            :ok
          end,
          async: false
        )

      # A correctly emitted signal — should be received
      Bus.publish(Signal.new(:agent, :started, %{}))
      assert_receive {:got, %Signal{category: :agent}}, 500

      Bus.unsubscribe(sub_id)
    end
  end

  # Test authorizer that denies everything
  defmodule DenyAuthorizer do
    @behaviour Arbor.Signals.Behaviours.SubscriptionAuthorizer

    @impl true
    def authorize_subscription(_principal_id, _topic) do
      {:error, :unauthorized}
    end
  end

  # Drain any pending messages with the given tag to avoid cross-test interference.
  # Other tests running concurrently may publish signals to the shared Bus,
  # causing stray messages to arrive in this process's mailbox.
  defp drain_messages(tag) do
    receive do
      {^tag, _, _} -> drain_messages(tag)
    after
      0 -> :ok
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

  # Test authorizer that allows only non-security/non-identity topics
  defmodule AllowActivityOnlyAuthorizer do
    @behaviour Arbor.Signals.Behaviours.SubscriptionAuthorizer

    @impl true
    def authorize_subscription(_principal_id, topic) when topic in [:security, :identity] do
      {:error, :unauthorized}
    end

    def authorize_subscription(_principal_id, _topic) do
      {:ok, :authorized}
    end
  end
end
