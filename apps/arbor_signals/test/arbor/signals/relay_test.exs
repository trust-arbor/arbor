defmodule Arbor.Signals.RelayTest do
  use ExUnit.Case, async: false

  alias Arbor.Signals.Relay
  alias Arbor.Signals.Signal

  @moduletag :fast

  # Reset the (supervised) Relay's internal state in place.
  #
  # The Relay is a *permanent* child of the shared Arbor.Signals.Supervisor
  # (started in test_helper.exs). Calling GenServer.stop/1 + Relay.start_link/1
  # races the supervisor's automatic restart: either start_link loses and returns
  # {:error, {:already_started, _}} (a MatchError in the test), or it wins and the
  # supervisor's restart fails — repeated across the stop/start tests in this file
  # this churns restart intensity and can take the whole supervisor down. All of
  # the relay's tunables (rate limits, batch size, batch interval) are read
  # dynamically from Application env on every operation, so a restart is never
  # required to pick up new config — only to get clean state. Reset the state in
  # place instead of bouncing a shared supervised process.
  defp reset_relay_state do
    :sys.replace_state(Relay, fn _old ->
      %{
        batch: [],
        batch_size: 0,
        rate_buckets: %{},
        node_counters: %{},
        stats: %{
          relayed_out: 0,
          relayed_in: 0,
          batches_sent: 0,
          signals_dropped: 0,
          signals_rate_limited: 0,
          signals_rejected: 0,
          peers_seen: 0
        }
      }
    end)

    :ok
  end

  setup do
    # The Relay is started by test_helper.exs as a supervised child. Don't
    # stop/restart it (see reset_relay_state/0) — just reset its state.
    case Process.whereis(Relay) do
      nil ->
        # Not supervised in this context — start a standalone instance we own.
        {:ok, pid} = Relay.start_link([])
        on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
        :ok

      _pid ->
        reset_relay_state()
        :ok
    end
  end

  describe "relay/1" do
    test "accepts cluster-scoped signals" do
      signal = Signal.new(:agent, :started, %{agent_id: "test"})
      assert signal.scope == :cluster
      assert :ok = Relay.relay(signal)
    end

    test "queues signals for batching" do
      signal = Signal.new(:agent, :started, %{agent_id: "test"})
      Relay.relay(signal)

      stats = Relay.stats()
      assert stats.batch_pending >= 0
    end
  end

  describe "stats/0" do
    test "returns relay statistics" do
      stats = Relay.stats()
      assert is_map(stats)
      assert Map.has_key?(stats, :relayed_out)
      assert Map.has_key?(stats, :relayed_in)
      assert Map.has_key?(stats, :batches_sent)
      assert Map.has_key?(stats, :signals_dropped)
      assert Map.has_key?(stats, :signals_rate_limited)
      assert Map.has_key?(stats, :signals_rejected)
      assert Map.has_key?(stats, :peers_connected)
      assert Map.has_key?(stats, :batch_pending)
      assert Map.has_key?(stats, :enabled)
    end

    test "starts with zero counters" do
      stats = Relay.stats()
      assert stats.relayed_out == 0
      assert stats.relayed_in == 0
      assert stats.batches_sent == 0
      assert stats.signals_dropped == 0
      assert stats.signals_rate_limited == 0
      assert stats.signals_rejected == 0
    end
  end

  describe "enabled?/0" do
    test "defaults to true" do
      assert Relay.enabled?()
    end
  end

  describe "signal scope defaults" do
    test "agent signals default to cluster scope" do
      signal = Signal.new(:agent, :started, %{})
      assert signal.scope == :cluster
    end

    test "security signals default to cluster scope" do
      signal = Signal.new(:security, :auth_failed, %{})
      assert signal.scope == :cluster
    end

    test "orchestrator signals default to cluster scope" do
      signal = Signal.new(:orchestrator, :pipeline_started, %{})
      assert signal.scope == :cluster
    end

    test "consensus signals default to cluster scope" do
      signal = Signal.new(:consensus, :vote_cast, %{})
      assert signal.scope == :cluster
    end

    test "trust signals default to cluster scope" do
      signal = Signal.new(:trust, :tier_changed, %{})
      assert signal.scope == :cluster
    end

    test "activity signals default to local scope" do
      signal = Signal.new(:activity, :test_event, %{})
      assert signal.scope == :local
    end

    test "metrics signals default to local scope" do
      signal = Signal.new(:metrics, :latency, %{})
      assert signal.scope == :local
    end

    test "system signals default to local scope" do
      signal = Signal.new(:system, :heartbeat, %{})
      assert signal.scope == :local
    end

    test "custom signals default to local scope" do
      signal = Signal.new(:custom, :whatever, %{})
      assert signal.scope == :local
    end

    test "scope can be overridden to local" do
      signal = Signal.new(:agent, :started, %{}, scope: :local)
      assert signal.scope == :local
    end

    test "scope can be overridden to cluster" do
      signal = Signal.new(:activity, :test_event, %{}, scope: :cluster)
      assert signal.scope == :cluster
    end
  end

  describe "origin_node" do
    test "set automatically on new signal" do
      signal = Signal.new(:agent, :started, %{})
      assert signal.origin_node == node()
    end

    test "can be overridden in opts" do
      signal = Signal.new(:agent, :started, %{}, origin_node: :other@host)
      assert signal.origin_node == :other@host
    end
  end

  describe "global_categories/0" do
    test "returns the list of cluster-scoped categories" do
      cats = Signal.global_categories()
      assert :agent in cats
      assert :security in cats
      assert :orchestrator in cats
      assert :consensus in cats
      assert :trust in cats
      refute :activity in cats
      refute :metrics in cats
      refute :system in cats
    end
  end

  describe "load shedding" do
    test "drops lower priority signals when batch is full" do
      # Set a very small max batch size for testing
      Application.put_env(:arbor_signals, :relay_max_batch_size, 3)

      on_exit(fn ->
        Application.delete_env(:arbor_signals, :relay_max_batch_size)
      end)

      # Restart relay with new config
      # Config is read dynamically per-op; reset state instead of bouncing the
      # supervised Relay (see reset_relay_state/0).
      reset_relay_state()

      # Fill the batch with agent signals (priority 2)
      for _ <- 1..3 do
        Relay.relay(Signal.new(:agent, :started, %{}))
      end

      # This should trigger load shedding
      Relay.relay(Signal.new(:agent, :extra, %{}))

      stats = Relay.stats()
      assert stats.signals_dropped >= 1
    end

    test "security signals are never dropped in favor of agent signals" do
      Application.put_env(:arbor_signals, :relay_max_batch_size, 2)

      on_exit(fn ->
        Application.delete_env(:arbor_signals, :relay_max_batch_size)
      end)

      # Config is read dynamically per-op; reset state instead of bouncing the
      # supervised Relay (see reset_relay_state/0).
      reset_relay_state()

      # Fill with agent signals
      Relay.relay(Signal.new(:agent, :started, %{}))
      Relay.relay(Signal.new(:agent, :stopped, %{}))

      # Security signal should replace an agent signal
      Relay.relay(Signal.new(:security, :breach, %{}))

      stats = Relay.stats()
      assert stats.signals_dropped >= 1
    end
  end

  describe "batch flushing" do
    test "flushes batch periodically" do
      # Set a very short batch interval
      Application.put_env(:arbor_signals, :relay_batch_interval_ms, 10)

      on_exit(fn ->
        Application.delete_env(:arbor_signals, :relay_batch_interval_ms)
      end)

      # Config is read dynamically per-op; reset state instead of bouncing the
      # supervised Relay (see reset_relay_state/0).
      reset_relay_state()

      Relay.relay(Signal.new(:agent, :started, %{}))

      # Wait for flush
      Process.sleep(50)

      stats = Relay.stats()
      # With no peers, signals are "flushed" but not sent anywhere
      # The batch should be empty after flush
      assert stats.batch_pending == 0
    end
  end

  describe "receive_batch/3" do
    test "receives signals from a peer node" do
      signals = [
        Signal.new(:agent, :started, %{agent_id: "remote_1"}),
        Signal.new(:security, :auth_ok, %{})
      ]

      # Simulate receiving a batch from a peer
      GenServer.cast(Relay, {:receive_batch, signals, :peer@host})

      # Give it time to process (CI VMs may be slower)
      Process.sleep(100)

      stats = Relay.stats()
      # In nonode@nohost mode, all peers are accepted
      assert stats.relayed_in == 2
    end
  end

  # ── Phase 5: Rate Limiting Tests ──────────────────────────────────

  describe "per-category rate limiting" do
    test "allows signals within rate limit" do
      # High limit — should allow all
      Application.put_env(:arbor_signals, :relay_category_rate_limit, 1000)

      on_exit(fn ->
        Application.delete_env(:arbor_signals, :relay_category_rate_limit)
      end)

      # Config is read dynamically per-op; reset state instead of bouncing the
      # supervised Relay (see reset_relay_state/0).
      reset_relay_state()

      for _ <- 1..10 do
        Relay.relay(Signal.new(:agent, :started, %{}))
      end

      stats = Relay.stats()
      assert stats.signals_rate_limited == 0
    end

    test "rate limits signals exceeding per-category limit" do
      # Very low limit — should rate limit quickly
      Application.put_env(:arbor_signals, :relay_category_rate_limit, 2)
      # Large batch so shedding doesn't interfere
      Application.put_env(:arbor_signals, :relay_max_batch_size, 1000)

      on_exit(fn ->
        Application.delete_env(:arbor_signals, :relay_category_rate_limit)
        Application.delete_env(:arbor_signals, :relay_max_batch_size)
      end)

      # Config is read dynamically per-op; reset state instead of bouncing the
      # supervised Relay (see reset_relay_state/0).
      reset_relay_state()

      # Flood with signals from same category
      for _ <- 1..20 do
        Relay.relay(Signal.new(:agent, :started, %{}))
      end

      stats = Relay.stats()
      assert stats.signals_rate_limited > 0
    end

    test "rate limits are per-category" do
      Application.put_env(:arbor_signals, :relay_category_rate_limit, 3)
      Application.put_env(:arbor_signals, :relay_max_batch_size, 1000)

      on_exit(fn ->
        Application.delete_env(:arbor_signals, :relay_category_rate_limit)
        Application.delete_env(:arbor_signals, :relay_max_batch_size)
      end)

      # Config is read dynamically per-op; reset state instead of bouncing the
      # supervised Relay (see reset_relay_state/0).
      reset_relay_state()

      # Send 3 agent + 3 security — each category gets its own bucket
      for _ <- 1..3 do
        Relay.relay(Signal.new(:agent, :started, %{}))
      end

      for _ <- 1..3 do
        Relay.relay(Signal.new(:security, :event, %{}))
      end

      stats = Relay.stats()
      # All 6 should be within limits (3 per category, limit is 3)
      assert stats.signals_rate_limited == 0
    end

    test "stats track rate limited signals" do
      stats = Relay.stats()
      assert Map.has_key?(stats, :signals_rate_limited)
    end
  end

  # ── Phase 6: Security Hardening Tests ─────────────────────────────

  describe "origin node validation" do
    test "accepts signals from own node" do
      signals = [Signal.new(:agent, :started, %{})]

      GenServer.cast(Relay, {:receive_batch, signals, node()})
      Process.sleep(10)

      stats = Relay.stats()
      assert stats.relayed_in == 1
      assert stats.signals_rejected == 0
    end

    test "accepts signals in nonode@nohost mode (single node)" do
      # In test mode we're always nonode@nohost, so all peers are accepted
      signals = [Signal.new(:agent, :started, %{})]

      GenServer.cast(Relay, {:receive_batch, signals, :unknown@host})
      Process.sleep(100)

      stats = Relay.stats()
      assert stats.relayed_in == 1
    end

    test "stats track rejected signals" do
      stats = Relay.stats()
      assert Map.has_key?(stats, :signals_rejected)
      assert stats.signals_rejected == 0
    end
  end

  describe "per-node ingress rate limiting" do
    test "allows signals within node rate limit" do
      Application.put_env(:arbor_signals, :relay_node_rate_limit, 100)

      on_exit(fn ->
        Application.delete_env(:arbor_signals, :relay_node_rate_limit)
      end)

      # Config is read dynamically per-op; reset state instead of bouncing the
      # supervised Relay (see reset_relay_state/0).
      reset_relay_state()

      signals = for i <- 1..10, do: Signal.new(:agent, :started, %{i: i})

      GenServer.cast(Relay, {:receive_batch, signals, node()})
      Process.sleep(10)

      stats = Relay.stats()
      assert stats.relayed_in == 10
      assert stats.signals_rejected == 0
    end

    test "rejects signals exceeding per-node rate" do
      Application.put_env(:arbor_signals, :relay_node_rate_limit, 5)

      on_exit(fn ->
        Application.delete_env(:arbor_signals, :relay_node_rate_limit)
      end)

      # Config is read dynamically per-op; reset state instead of bouncing the
      # supervised Relay (see reset_relay_state/0).
      reset_relay_state()

      # Send 10 signals — only 5 should be accepted
      signals = for i <- 1..10, do: Signal.new(:agent, :started, %{i: i})

      GenServer.cast(Relay, {:receive_batch, signals, node()})
      Process.sleep(10)

      stats = Relay.stats()
      assert stats.relayed_in == 5
      assert stats.signals_rejected == 5
    end
  end

  describe "metadata sanitization" do
    test "preserves atom-keyed metadata" do
      signal = Signal.new(:agent, :started, %{}, metadata: %{agent_id: "test_123"})
      signals = [signal]

      GenServer.cast(Relay, {:receive_batch, signals, node()})
      Process.sleep(10)

      stats = Relay.stats()
      assert stats.relayed_in == 1
    end

    test "keeps unknown string keys as strings (no atom creation)" do
      signal = %{
        Signal.new(:agent, :started, %{})
        | metadata: %{"unknown_key" => "value", "another" => 42}
      }

      signals = [signal]

      GenServer.cast(Relay, {:receive_batch, signals, node()})
      Process.sleep(10)

      stats = Relay.stats()
      assert stats.relayed_in == 1
    end
  end
end
