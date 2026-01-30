defmodule Arbor.Signals.BusTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Signals.Bus
  alias Arbor.Signals.Signal

  describe "subscribe/3 and publish/1" do
    test "wildcard pattern receives all signals" do
      test_pid = self()

      {:ok, sub_id} =
        Bus.subscribe("*", fn signal ->
          send(test_pid, {:wildcard, signal})
          :ok
        end, async: false)

      Bus.publish(Signal.new(:activity, :wildcard_test, %{}))
      assert_receive {:wildcard, %Signal{type: :wildcard_test}}, 500

      Bus.unsubscribe(sub_id)
    end

    test "category wildcard matches any type" do
      test_pid = self()

      {:ok, sub_id} =
        Bus.subscribe("security.*", fn signal ->
          send(test_pid, {:cat_wild, signal})
          :ok
        end, async: false)

      Bus.publish(Signal.new(:security, :auth_check, %{}))
      assert_receive {:cat_wild, %Signal{type: :auth_check}}, 500

      Bus.publish(Signal.new(:activity, :other, %{}))
      refute_receive {:cat_wild, _}, 100

      Bus.unsubscribe(sub_id)
    end

    test "type wildcard matches any category" do
      test_pid = self()

      {:ok, sub_id} =
        Bus.subscribe("*.type_wild_test", fn signal ->
          send(test_pid, {:type_wild, signal})
          :ok
        end, async: false)

      Bus.publish(Signal.new(:activity, :type_wild_test, %{}))
      assert_receive {:type_wild, %Signal{category: :activity}}, 500

      Bus.publish(Signal.new(:security, :type_wild_test, %{}))
      assert_receive {:type_wild, %Signal{category: :security}}, 500

      Bus.unsubscribe(sub_id)
    end

    test "exact pattern matches specific category.type" do
      test_pid = self()

      {:ok, sub_id} =
        Bus.subscribe("metrics.latency", fn signal ->
          send(test_pid, {:exact, signal})
          :ok
        end, async: false)

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
        Bus.subscribe("activity.error_test", fn _signal ->
          raise "handler error"
        end, async: false)

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
        Bus.subscribe("activity.unsub_bus_test", fn signal ->
          send(test_pid, {:unsub, signal})
          :ok
        end, async: false)

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

    test "includes pattern and async flag" do
      {:ok, sub_id} = Bus.subscribe("metrics.list_test", fn _ -> :ok end, async: false)

      subs = Bus.list_subscriptions()
      sub = Enum.find(subs, &(&1.id == sub_id))

      assert sub.pattern == "metrics.list_test"
      assert sub.async == false
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
    end
  end
end
