defmodule Arbor.SignalsTest do
  use ExUnit.Case, async: true

  alias Arbor.Signals
  alias Arbor.Signals.Signal

  describe "emit/3,4" do
    test "emits a signal and stores it" do
      assert :ok = Signals.emit(:activity, :test_event, %{value: 42})

      {:ok, [signal | _]} = Signals.recent(limit: 1, category: :activity, type: :test_event)
      assert signal.category == :activity
      assert signal.type == :test_event
      assert signal.data.value == 42
    end

    test "accepts options" do
      assert :ok =
               Signals.emit(:activity, :test_event, %{}, source: "test", correlation_id: "corr_1")

      {:ok, [signal | _]} = Signals.recent(limit: 1, type: :test_event)
      assert signal.source == "test"
      assert signal.correlation_id == "corr_1"
    end
  end

  describe "subscribe/3 and unsubscribe/1" do
    test "subscribes to signals and receives them" do
      test_pid = self()

      {:ok, sub_id} =
        Signals.subscribe("activity.sub_test", fn signal ->
          send(test_pid, {:signal, signal})
          :ok
        end, async: false)

      Signals.emit(:activity, :sub_test, %{value: 123})

      assert_receive {:signal, %Signal{type: :sub_test, data: %{value: 123}}}, 1000

      assert :ok = Signals.unsubscribe(sub_id)
    end

    test "unsubscribe stops delivery" do
      test_pid = self()

      {:ok, sub_id} =
        Signals.subscribe("activity.unsub_test", fn signal ->
          send(test_pid, {:signal, signal})
          :ok
        end, async: false)

      Signals.unsubscribe(sub_id)
      Signals.emit(:activity, :unsub_test, %{})

      refute_receive {:signal, _}, 100
    end
  end

  describe "query/1" do
    test "filters by category" do
      Signals.emit(:activity, :query_test_1, %{})
      Signals.emit(:security, :query_test_2, %{})

      {:ok, signals} = Signals.query(category: :activity, type: :query_test_1)
      assert Enum.all?(signals, &(&1.category == :activity))
    end

    test "respects limit" do
      for i <- 1..10 do
        Signals.emit(:activity, :limit_test, %{i: i})
      end

      {:ok, signals} = Signals.query(type: :limit_test, limit: 3)
      assert length(signals) == 3
    end
  end

  describe "get_signal/1" do
    test "retrieves signal by ID" do
      Signals.emit(:activity, :get_test, %{unique: "value"})
      {:ok, [signal | _]} = Signals.recent(type: :get_test, limit: 1)

      {:ok, retrieved} = Signals.get_signal(signal.id)
      assert retrieved.id == signal.id
      assert retrieved.data.unique == "value"
    end

    test "returns error for unknown ID" do
      assert {:error, :not_found} = Signals.get_signal("sig_nonexistent")
    end
  end

  describe "healthy?/0" do
    test "returns true when system is running" do
      assert Signals.healthy?() == true
    end
  end

  describe "stats/0" do
    test "returns combined statistics" do
      stats = Signals.stats()

      assert Map.has_key?(stats, :store)
      assert Map.has_key?(stats, :bus)
      assert Map.has_key?(stats, :healthy)
      assert stats.healthy == true
    end
  end

  describe "emit_signal/1" do
    test "emits a pre-constructed signal" do
      signal = Signal.new(:test, :prebuilt, %{value: 42})
      assert :ok = Signals.emit_signal(signal)

      Process.sleep(50)
      {:ok, fetched} = Signals.get_signal(signal.id)
      assert fetched.data.value == 42
    end
  end

  describe "emit_tainted/5" do
    test "emits a signal with taint metadata" do
      assert :ok =
               Signals.emit_tainted(
                 :activity,
                 :tainted_event,
                 %{content: "untrusted data"},
                 :untrusted,
                 taint_source: "external_api"
               )

      {:ok, [signal | _]} = Signals.recent(limit: 1, type: :tainted_event)
      assert signal.category == :activity
      assert signal.type == :tainted_event
      assert signal.metadata.taint == :untrusted
      assert signal.metadata.taint_source == "external_api"
      assert signal.metadata.taint_chain == []
    end

    test "includes taint_chain when provided" do
      assert :ok =
               Signals.emit_tainted(
                 :activity,
                 :chain_event,
                 %{},
                 :derived,
                 taint_source: "llm_output",
                 taint_chain: ["sig_123", "sig_456"]
               )

      {:ok, [signal | _]} = Signals.recent(limit: 1, type: :chain_event)
      assert signal.metadata.taint == :derived
      assert signal.metadata.taint_chain == ["sig_123", "sig_456"]
    end

    test "merges taint metadata with existing metadata" do
      assert :ok =
               Signals.emit_tainted(
                 :activity,
                 :merged_event,
                 %{data: "test"},
                 :trusted,
                 metadata: %{agent_id: "agent_001", custom: "value"},
                 taint_source: "internal"
               )

      {:ok, [signal | _]} = Signals.recent(limit: 1, type: :merged_event)
      assert signal.metadata.taint == :trusted
      assert signal.metadata.taint_source == "internal"
      assert signal.metadata.agent_id == "agent_001"
      assert signal.metadata.custom == "value"
    end

    test "supports all taint levels" do
      for level <- [:trusted, :derived, :untrusted, :hostile] do
        type = String.to_atom("taint_level_#{level}")

        assert :ok =
                 Signals.emit_tainted(
                   :activity,
                   type,
                   %{},
                   level,
                   taint_source: "test"
                 )

        {:ok, [signal | _]} = Signals.recent(limit: 1, type: type)
        assert signal.metadata.taint == level
      end
    end

    test "default options work correctly" do
      assert :ok = Signals.emit_tainted(:activity, :default_opts_event, %{}, :trusted)

      {:ok, [signal | _]} = Signals.recent(limit: 1, type: :default_opts_event)
      assert signal.metadata.taint == :trusted
      assert signal.metadata.taint_source == nil
      assert signal.metadata.taint_chain == []
    end
  end

  describe "contract callbacks" do
    test "emit_signal_for_category_and_type/4" do
      assert :ok = Signals.emit_signal_for_category_and_type(:contract, :test_cb, %{}, [])
    end

    test "subscribe_to_signals_matching_pattern/3 and unsubscribe" do
      {:ok, sub_id} =
        Signals.subscribe_to_signals_matching_pattern(
          "contract.*",
          fn _signal -> :ok end,
          []
        )

      assert is_binary(sub_id)
      assert :ok = Signals.unsubscribe_from_signals_by_subscription_id(sub_id)
    end

    test "get_signal_by_id/1" do
      signal = Signal.new(:contract, :fetch_cb, %{})
      Signals.emit_signal(signal)
      Process.sleep(50)

      assert {:ok, fetched} = Signals.get_signal_by_id(signal.id)
      assert fetched.id == signal.id
    end

    test "query_signals_with_filters/1" do
      assert {:ok, signals} = Signals.query_signals_with_filters([])
      assert is_list(signals)
    end

    test "get_recent_signals_from_buffer/1" do
      assert {:ok, signals} = Signals.get_recent_signals_from_buffer([])
      assert is_list(signals)
    end

    test "emit_preconstructed_signal/1" do
      signal = Signal.new(:contract, :precon_cb, %{x: 99})
      assert :ok = Signals.emit_preconstructed_signal(signal)

      Process.sleep(50)
      assert {:ok, fetched} = Signals.get_signal(signal.id)
      assert fetched.data.x == 99
    end
  end
end
