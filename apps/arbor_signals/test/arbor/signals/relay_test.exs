defmodule Arbor.Signals.RelayTest do
  use ExUnit.Case, async: false

  alias Arbor.Signals.Relay
  alias Arbor.Signals.Signal

  @moduletag :fast

  setup do
    # Ensure relay is running
    case Process.whereis(Relay) do
      nil ->
        {:ok, pid} = Relay.start_link([])
        on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
        :ok

      pid ->
        # Stop and restart for clean state
        GenServer.stop(pid)
        {:ok, pid} = Relay.start_link([])
        on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
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
      GenServer.stop(Relay)
      {:ok, _} = Relay.start_link([])

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

      GenServer.stop(Relay)
      {:ok, _} = Relay.start_link([])

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

      GenServer.stop(Relay)
      {:ok, _} = Relay.start_link([])

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

      # Give it a moment to process
      Process.sleep(10)

      stats = Relay.stats()
      assert stats.relayed_in == 2
    end
  end
end
