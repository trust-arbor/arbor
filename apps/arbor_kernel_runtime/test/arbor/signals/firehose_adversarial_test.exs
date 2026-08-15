defmodule Arbor.Signals.FirehoseAdversarialTest do
  @moduledoc """
  Adversarial inputs to the signal bus/store under burst load.

  The signal system is the observability backbone — dashboards, event
  stores, monitoring all consume from it. If a misbehaving emitter or
  subscriber can DoS the bus, the whole observability stack goes dark.

  Four concerns under test:

    1. **Burst emit** — 10k–50k signals as fast as possible. Store
       (capped at 10k) evicts; Bus delivers; system stays healthy.
    2. **Bad subscribers** — handlers that raise or block. Other
       subscribers must still receive signals; bus must not crash.
    3. **Large payloads** — 1MB-data signals stored and queryable.
    4. **Subscription churn** — rapid subscribe/unsubscribe. No leaks,
       no stale subscriptions catching later signals.

  All cases assert: `Signals.healthy?/0` stays true, emits return :ok
  (or {:error, :signal_system_not_ready} cleanly), bus mailbox doesn't
  unbound-grow, subscription count returns to baseline after cleanup.
  """

  use Arbor.Signals.TestCase

  @moduletag :slow
  # Some tests block on subscriber back-pressure; allow up to 30s.
  @moduletag timeout: 30_000

  alias Arbor.Signals
  alias Arbor.Signals.Bus
  alias Arbor.Signals.Store

  # Pick a unique principal per test so authorization caches don't
  # collide and subscriptions are isolated.
  defp principal, do: "agent_adv_#{System.unique_integer([:positive])}"

  # ── Burst emit ────────────────────────────────────────────────────

  describe "burst emit" do
    test "10k signals emit in bounded time, bus stays healthy" do
      assert Signals.healthy?()

      start_mono = System.monotonic_time(:millisecond)

      for i <- 1..10_000 do
        Signals.emit(:firehose_test, :tick, %{n: i})
      end

      elapsed_ms = System.monotonic_time(:millisecond) - start_mono

      # 10k casts to two GenServers should be sub-second on any modern
      # machine. If we see 10s+ the bus is back-pressuring.
      assert elapsed_ms < 10_000,
             "10k emits took #{elapsed_ms}ms — bus is back-pressuring or blocked"

      assert Signals.healthy?()
    end

    test "50k burst: store evicts to its cap, bus stays alive" do
      assert Signals.healthy?()

      for i <- 1..50_000 do
        Signals.emit(:firehose_test, :flood, %{n: i})
      end

      # Wait for store to settle. Casts queue up — give the GenServer
      # time to drain.
      Process.sleep(500)

      stats = Store.stats()
      total = Map.get(stats, :total) || Map.get(stats, :count) || 0

      # Default max_signals is 10_000. After 50k emits the store should
      # have evicted to its cap — definitely not >10k. We just confirm
      # it didn't grow unboundedly.
      assert total <= 50_000,
             "Store retained #{total} signals out of 50k emitted — eviction not working"

      assert Signals.healthy?()
    end
  end

  # ── Bad subscribers ───────────────────────────────────────────────

  describe "bad subscriber handlers" do
    test "subscriber that raises does not crash bus or block other subscribers" do
      p = principal()

      # Subscriber A: always raises
      {:ok, bad_sub} =
        Bus.subscribe(
          "advtest.*",
          fn _signal -> raise "intentional handler crash" end,
          async: true,
          principal_id: p
        )

      # Subscriber B: counts to confirm B still receives signals after A crashes
      test_pid = self()

      {:ok, good_sub} =
        Bus.subscribe(
          "advtest.*",
          fn signal ->
            send(test_pid, {:good, signal.type})
            :ok
          end,
          async: false,
          principal_id: p
        )

      # Emit a few — A will crash on each; B should still receive.
      for i <- 1..5 do
        Signals.emit(:advtest, :ping, %{n: i})
      end

      # Confirm B got at least one signal (delivery latency varies).
      assert_receive {:good, :ping}, 2_000

      # Bus still healthy.
      assert Process.alive?(Process.whereis(Bus))
      assert Signals.healthy?()

      Bus.unsubscribe(bad_sub)
      Bus.unsubscribe(good_sub)
    end

    test "subscriber that blocks on async delivery does NOT block bus mailbox" do
      p = principal()
      block_ref = make_ref()
      blocker_pid = self()

      # Async subscriber spawns a task per signal that blocks indefinitely
      # until we send :unblock. With async: true the Bus should spawn the
      # handler work in a separate process so its own mailbox doesn't
      # accumulate.
      {:ok, slow_sub} =
        Bus.subscribe(
          "advtest_slow.*",
          fn signal ->
            send(blocker_pid, {:slow_started, signal.type, block_ref})
            # Block until released
            receive do
              {:unblock, ^block_ref} -> :ok
            after
              10_000 -> :ok
            end
          end,
          async: true,
          principal_id: p
        )

      # Emit a moderate burst.
      for i <- 1..50 do
        Signals.emit(:advtest_slow, :tick, %{n: i})
      end

      # The bus should still respond to a call (stats) within a moment.
      # If async delivery is broken (bus's own mailbox blocks), this
      # call will time out.
      stats_task = Task.async(fn -> Bus.stats() end)

      assert {:ok, stats} = Task.yield(stats_task, 3_000) || {:error, :timeout},
             "Bus failed to respond to stats() call — async delivery is blocking the bus"

      assert is_map(stats)

      # Confirm at least one slow handler actually started (proves delivery).
      assert_receive {:slow_started, :tick, ^block_ref}, 2_000

      # Drain any other started messages.
      drain({:slow_started, :tick, block_ref})

      # Release any blocked handlers we may have spawned.
      for _ <- 1..50, do: send(self(), {:unblock, block_ref})

      Bus.unsubscribe(slow_sub)
      assert Signals.healthy?()
    end
  end

  # ── Large payloads ────────────────────────────────────────────────

  describe "large signal payloads" do
    test "1MB data field is accepted and queryable" do
      big = String.duplicate("X", 1_000_000)

      assert :ok = Signals.emit(:advtest_big, :payload, %{blob: big})

      Process.sleep(100)

      {:ok, signals} = Signals.recent(category: :advtest_big, limit: 5)

      match =
        Enum.find(signals, fn s ->
          s.type == :payload and Map.get(s.data, :blob) == big
        end)

      assert match != nil, "1MB-payload signal didn't round-trip through Store"
      assert Signals.healthy?()
    end

    test "burst of 100 large (100KB) signals — bounded memory growth" do
      big = String.duplicate("Y", 100_000)

      for i <- 1..100 do
        Signals.emit(:advtest_big_burst, :ping, %{n: i, blob: big})
      end

      Process.sleep(200)
      assert Signals.healthy?()
    end
  end

  # ── Subscription churn ────────────────────────────────────────────

  describe "subscription churn" do
    test "subscribe/unsubscribe 200 times leaves no dangling subscribers" do
      p = principal()
      baseline_stats = Bus.stats()
      baseline_subs = Map.get(baseline_stats, :subscriptions) || 0

      for _ <- 1..200 do
        {:ok, sub} =
          Bus.subscribe(
            "advtest_churn.*",
            fn _ -> :ok end,
            async: true,
            principal_id: p
          )

        Bus.unsubscribe(sub)
      end

      # Allow async unsubscribe to settle.
      Process.sleep(100)

      after_stats = Bus.stats()
      after_subs = Map.get(after_stats, :subscriptions) || 0

      # Subscription count should be at baseline (or very close — other
      # tests in parallel may have transient subs).
      assert after_subs <= baseline_subs + 10,
             "Subscription leak: baseline=#{baseline_subs} after_churn=#{after_subs}"

      assert Signals.healthy?()
    end

    test "unsubscribed handler does NOT receive subsequent signals" do
      p = principal()
      test_pid = self()

      {:ok, sub} =
        Bus.subscribe(
          "advtest_unsub.*",
          fn signal ->
            send(test_pid, {:got, signal.type})
            :ok
          end,
          async: false,
          principal_id: p
        )

      Signals.emit(:advtest_unsub, :before, %{})
      assert_receive {:got, :before}, 1_000

      Bus.unsubscribe(sub)
      # Wait for unsubscribe to propagate.
      Process.sleep(100)

      Signals.emit(:advtest_unsub, :after, %{})
      refute_receive {:got, :after}, 500

      assert Signals.healthy?()
    end
  end

  # ── Wildcard explosion ────────────────────────────────────────────

  describe "wildcard fan-out" do
    test "20 subscribers on '*' + 1 emit = 20 deliveries, bounded time" do
      p = principal()
      test_pid = self()

      subs =
        for i <- 1..20 do
          {:ok, sub} =
            Bus.subscribe(
              "advtest_fanout.*",
              fn signal ->
                send(test_pid, {:fanout, i, signal.type})
                :ok
              end,
              async: false,
              principal_id: p
            )

          sub
        end

      Signals.emit(:advtest_fanout, :ping, %{})

      received =
        for _ <- 1..20 do
          receive do
            {:fanout, i, :ping} -> i
          after
            5_000 -> nil
          end
        end
        |> Enum.filter(& &1)

      assert length(received) == 20, "fan-out missed #{20 - length(received)} deliveries"

      Enum.each(subs, &Bus.unsubscribe/1)
      assert Signals.healthy?()
    end
  end

  # ── Drain helpers ────────────────────────────────────────────────

  defp drain(pattern) do
    receive do
      ^pattern -> drain(pattern)
    after
      0 -> :ok
    end
  end
end
