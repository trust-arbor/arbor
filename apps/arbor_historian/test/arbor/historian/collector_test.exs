defmodule Arbor.Historian.CollectorTest do
  use ExUnit.Case, async: true

  alias Arbor.Historian.Collector
  alias Arbor.Historian.StreamRegistry
  alias Arbor.Historian.TestHelpers
  alias Arbor.Persistence.EventLog.ETS, as: PersistenceETS

  setup do
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    ctx = TestHelpers.start_test_historian(:"collector_#{System.unique_integer([:positive])}")
    %{ctx: ctx}
  end

  describe "collect/2" do
    test "collects a signal and increments event count", %{ctx: ctx} do
      signal = TestHelpers.build_signal()
      assert :ok = Collector.collect(ctx.collector, signal)
      assert Collector.event_count(ctx.collector) == 1
    end

    test "persists event to EventLog", %{ctx: ctx} do
      signal = TestHelpers.build_signal(category: :activity, type: :agent_started)
      Collector.collect(ctx.collector, signal)

      {:ok, events} = PersistenceETS.read_stream("global", name: ctx.event_log)
      assert length(events) == 1
      assert hd(events).type == "arbor.historian.activity:agent_started"
    end

    test "routes to multiple streams", %{ctx: ctx} do
      signal = TestHelpers.build_agent_signal("a1", category: :security, type: :auth)
      Collector.collect(ctx.collector, signal)

      {:ok, global} = PersistenceETS.read_stream("global", name: ctx.event_log)
      {:ok, agent} = PersistenceETS.read_stream("agent:a1", name: ctx.event_log)
      {:ok, category} = PersistenceETS.read_stream("category:security", name: ctx.event_log)

      assert length(global) == 1
      assert length(agent) == 1
      assert length(category) == 1
    end

    test "updates StreamRegistry", %{ctx: ctx} do
      signal = TestHelpers.build_signal()
      Collector.collect(ctx.collector, signal)

      streams = StreamRegistry.list_streams(ctx.registry)
      assert "global" in streams

      {:ok, meta} = StreamRegistry.get_stream(ctx.registry, "global")
      assert meta.event_count >= 1
    end

    test "collects multiple signals", %{ctx: ctx} do
      for i <- 1..5 do
        # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
        signal = TestHelpers.build_signal(type: :"event_#{i}")
        Collector.collect(ctx.collector, signal)
      end

      assert Collector.event_count(ctx.collector) == 5
    end
  end

  describe "filter option" do
    test "skips signals that don't pass filter" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"filter_test_#{System.unique_integer([:positive])}"
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      event_log_name = :"el_#{name}"
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      registry_name = :"reg_#{name}"

      {:ok, _} = PersistenceETS.start_link(name: event_log_name)
      {:ok, _} = StreamRegistry.start_link(name: registry_name)

      filter = fn signal -> signal.type != :skip_me end

      {:ok, collector} =
        Collector.start_link(
          # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
          name: :"coll_#{name}",
          event_log: event_log_name,
          registry: registry_name,
          subscribe: false,
          filter: filter
        )

      # Should be collected
      Collector.collect(collector, TestHelpers.build_signal(type: :keep_me))
      # Should be filtered out
      Collector.collect(collector, TestHelpers.build_signal(type: :skip_me))

      assert Collector.event_count(collector) == 1
    end
  end

  describe "filter error handling" do
    test "collects signal when filter function raises" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"error_filter_#{System.unique_integer([:positive])}"
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      event_log_name = :"el_#{name}"
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      registry_name = :"reg_#{name}"

      {:ok, _} = PersistenceETS.start_link(name: event_log_name)
      {:ok, _} = StreamRegistry.start_link(name: registry_name)

      # Filter that always raises
      filter = fn _signal -> raise "boom" end

      {:ok, collector} =
        Collector.start_link(
          # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
          name: :"coll_#{name}",
          event_log: event_log_name,
          registry: registry_name,
          subscribe: false,
          filter: filter
        )

      # The rescue clause in should_collect? returns true,
      # so the signal IS collected despite the filter raising
      signal = TestHelpers.build_signal(type: :error_filter_test)
      assert :ok = Collector.collect(collector, signal)
      assert Collector.event_count(collector) == 1
    end

    test "does not crash the collector when filter raises" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"crash_filter_#{System.unique_integer([:positive])}"
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      event_log_name = :"el_#{name}"
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      registry_name = :"reg_#{name}"

      {:ok, _} = PersistenceETS.start_link(name: event_log_name)
      {:ok, _} = StreamRegistry.start_link(name: registry_name)

      filter = fn _signal -> raise "unexpected error" end

      {:ok, collector} =
        Collector.start_link(
          # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
          name: :"coll_#{name}",
          event_log: event_log_name,
          registry: registry_name,
          subscribe: false,
          filter: filter
        )

      # Collect two signals - collector should survive both
      signal1 = TestHelpers.build_signal(type: :first)
      signal2 = TestHelpers.build_signal(type: :second)
      assert :ok = Collector.collect(collector, signal1)
      assert :ok = Collector.collect(collector, signal2)
      assert Collector.event_count(collector) == 2

      # Collector is still alive - use the PID directly
      assert Process.alive?(collector)
    end
  end

  describe "handle_info/2" do
    test "processes signal messages" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"info_test_#{System.unique_integer([:positive])}"
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      event_log_name = :"el_#{name}"
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      registry_name = :"reg_#{name}"
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      coll_name = :"coll_#{name}"

      {:ok, _} = PersistenceETS.start_link(name: event_log_name)
      {:ok, _} = StreamRegistry.start_link(name: registry_name)

      {:ok, _pid} =
        Collector.start_link(
          name: coll_name,
          event_log: event_log_name,
          registry: registry_name,
          subscribe: false
        )

      # Simulate what the subscription handler does: send {:signal, signal}
      signal = TestHelpers.build_signal(type: :info_test)
      pid = Process.whereis(coll_name)
      send(pid, {:signal, signal})

      # Give the GenServer time to process the message
      Process.sleep(50)

      assert Collector.event_count(coll_name) == 1
    end

    test "ignores unknown messages" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"unknown_msg_#{System.unique_integer([:positive])}"
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      event_log_name = :"el_#{name}"
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      registry_name = :"reg_#{name}"
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      coll_name = :"coll_#{name}"

      {:ok, _} = PersistenceETS.start_link(name: event_log_name)
      {:ok, _} = StreamRegistry.start_link(name: registry_name)

      {:ok, _pid} =
        Collector.start_link(
          name: coll_name,
          event_log: event_log_name,
          registry: registry_name,
          subscribe: false
        )

      pid = Process.whereis(coll_name)
      send(pid, :unexpected_message)
      send(pid, {:random, "data"})

      # Give the GenServer time to process
      Process.sleep(50)

      # Collector should still be alive and have no events
      assert Process.alive?(pid)
      assert Collector.event_count(coll_name) == 0
    end
  end

  describe "stats/1" do
    test "returns collector statistics", %{ctx: ctx} do
      stats = Collector.stats(ctx.collector)

      assert is_map(stats)
      assert stats.event_count == 0
      assert stats.subscribed == false
      assert stats.event_log == ctx.event_log
    end

    test "updates stats after collecting events", %{ctx: ctx} do
      signal = TestHelpers.build_signal()
      Collector.collect(ctx.collector, signal)

      stats = Collector.stats(ctx.collector)
      assert stats.event_count == 1
      assert stats.registry == ctx.registry
    end
  end

  describe "terminate/2" do
    test "handles terminate with nil subscription_id" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"term_nil_#{System.unique_integer([:positive])}"
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      event_log_name = :"el_#{name}"
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      registry_name = :"reg_#{name}"
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      coll_name = :"coll_#{name}"

      {:ok, _} = PersistenceETS.start_link(name: event_log_name)
      {:ok, _} = StreamRegistry.start_link(name: registry_name)

      {:ok, _pid} =
        Collector.start_link(
          name: coll_name,
          event_log: event_log_name,
          registry: registry_name,
          subscribe: false
        )

      pid = Process.whereis(coll_name)
      ref = Process.monitor(pid)

      # Stop the collector cleanly - terminate/2 with nil subscription_id
      GenServer.stop(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
    end
  end
end
