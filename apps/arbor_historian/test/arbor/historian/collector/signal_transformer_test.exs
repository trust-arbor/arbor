defmodule Arbor.Historian.Collector.SignalTransformerTest do
  use ExUnit.Case, async: true

  alias Arbor.Historian.Collector.SignalTransformer
  alias Arbor.Historian.TestHelpers

  describe "signal_to_event/2" do
    test "transforms a signal into an event" do
      signal = TestHelpers.build_signal(
        id: "sig_123",
        category: :activity,
        type: :agent_started,
        data: %{agent_id: "a1"},
        source: "arbor://test/agent"
      )

      assert {:ok, event} = SignalTransformer.signal_to_event(signal, "global")

      assert event.type == :"activity:agent_started"
      assert event.data == %{agent_id: "a1"}
      assert event.aggregate_id == "global"
      assert event.aggregate_type == :historian
      assert event.metadata[:signal_id] == "sig_123"
      assert event.metadata[:source] == "arbor://test/agent"
    end

    test "preserves causation and correlation IDs" do
      signal = TestHelpers.build_signal(
        cause_id: "sig_parent",
        correlation_id: "corr_abc"
      )

      {:ok, event} = SignalTransformer.signal_to_event(signal, "global")

      assert event.causation_id == "sig_parent"
      assert event.correlation_id == "corr_abc"
    end

    test "handles signal with nil data" do
      signal = TestHelpers.build_signal(data: nil)
      # Signal struct won't actually allow nil data from our helper,
      # but the transformer should handle missing fields gracefully
      {:ok, event} = SignalTransformer.signal_to_event(signal, "test")
      assert is_map(event.data)
    end
  end

  describe "event_to_history_entry/1" do
    test "converts an event back to a history entry" do
      signal = TestHelpers.build_signal(
        id: "sig_test",
        category: :security,
        type: :authorization
      )

      {:ok, event} = SignalTransformer.signal_to_event(signal, "category:security")
      entry = SignalTransformer.event_to_history_entry(event)

      assert entry.category == :security
      assert entry.type == :authorization
      assert entry.signal_id == "sig_test"
    end
  end

  describe "encode_type/2" do
    test "encodes category and type into a single atom" do
      assert SignalTransformer.encode_type(:activity, :agent_started) == :"activity:agent_started"
      assert SignalTransformer.encode_type(:security, :auth) == :"security:auth"
    end
  end

  describe "decode_type/1" do
    test "decodes an encoded type back into category and signal type" do
      assert SignalTransformer.decode_type(:"activity:agent_started") == {:activity, :agent_started}
      assert SignalTransformer.decode_type(:"logs:error") == {:logs, :error}
    end

    test "handles single-segment type" do
      assert SignalTransformer.decode_type(:orphan) == {:unknown, :orphan}
    end
  end
end
