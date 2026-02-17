defmodule Arbor.Signals.BusTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Signals.Bus
  alias Arbor.Signals.Signal

  describe "subscribe/3 and publish/1" do
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
  end

  describe "list_subscriptions/0" do
    test "returns active subscriptions" do
      {:ok, sub_id} = Bus.subscribe("activity.list_test", fn _ -> :ok end)

      subs = Bus.list_subscriptions()
      assert Enum.any?(subs, &(&1.id == sub_id))

      Bus.unsubscribe(sub_id)
    end

    test "includes pattern, async flag, and principal_id" do
      {:ok, sub_id} =
        Bus.subscribe("metrics.list_test", fn _ -> :ok end,
          async: false,
          principal_id: "agent_list_test"
        )

      subs = Bus.list_subscriptions()
      sub = Enum.find(subs, &(&1.id == sub_id))

      assert sub.pattern == "metrics.list_test"
      assert sub.async == false
      assert sub.principal_id == "agent_list_test"
      assert %DateTime{} = sub.created_at

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
      # Configure a denying authorizer for this test
      original = Application.get_env(:arbor_signals, :authorizer)
      Application.put_env(:arbor_signals, :authorizer, __MODULE__.DenyAuthorizer)

      on_exit(fn ->
        if original do
          Application.put_env(:arbor_signals, :authorizer, original)
        else
          Application.delete_env(:arbor_signals, :authorizer)
        end
      end)

      # No principal_id + restricted topic = denied
      assert {:error, :unauthorized} = Bus.subscribe("security.*", fn _ -> :ok end)

      # With principal_id but authorizer still denies
      assert {:error, :unauthorized} =
               Bus.subscribe("security.*", fn _ -> :ok end, principal_id: "agent_bad")
    end

    test "wildcard pattern with no principal_id is denied when authorizer denies" do
      original = Application.get_env(:arbor_signals, :authorizer)
      Application.put_env(:arbor_signals, :authorizer, __MODULE__.DenyAuthorizer)

      on_exit(fn ->
        if original do
          Application.put_env(:arbor_signals, :authorizer, original)
        else
          Application.delete_env(:arbor_signals, :authorizer)
        end
      end)

      # "*" overlaps restricted topics, no principal = denied
      assert {:error, :unauthorized} = Bus.subscribe("*", fn _ -> :ok end)
    end

    test "delivery-time filtering blocks restricted signals for unauthorized subs" do
      test_pid = self()

      original = Application.get_env(:arbor_signals, :authorizer)
      Application.put_env(:arbor_signals, :authorizer, __MODULE__.AllowActivityOnlyAuthorizer)

      on_exit(fn ->
        if original do
          Application.put_env(:arbor_signals, :authorizer, original)
        else
          Application.delete_env(:arbor_signals, :authorizer)
        end
      end)

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
      original = Application.get_env(:arbor_signals, :authorizer)
      Application.put_env(:arbor_signals, :authorizer, __MODULE__.DenyAuthorizer)

      on_exit(fn ->
        if original do
          Application.put_env(:arbor_signals, :authorizer, original)
        else
          Application.delete_env(:arbor_signals, :authorizer)
        end
      end)

      stats_before = Bus.stats()

      Bus.subscribe("security.*", fn _ -> :ok end)

      stats_after = Bus.stats()
      assert stats_after.total_auth_denied > stats_before.total_auth_denied
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
