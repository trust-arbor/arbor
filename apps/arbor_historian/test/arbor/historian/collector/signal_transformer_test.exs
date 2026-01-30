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
      assert event.subject_id == "global"
      assert event.subject_type == :historian
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

  describe "signal_to_event/2 with edge case maps" do
    test "handles map with integer type (extract_category and extract_signal_type fallbacks)" do
      # Use a plain map to bypass Signal struct validation and hit
      # the fallback paths in extract_category and extract_signal_type
      signal = %{
        id: "sig_edge_int_type",
        type: 123,
        category: nil,
        data: %{},
        source: "test",
        cause_id: nil,
        correlation_id: nil,
        timestamp: DateTime.utc_now()
      }

      assert {:ok, event} = SignalTransformer.signal_to_event(signal, "test-stream")

      # Both extract_category and extract_signal_type should return :unknown
      assert event.type == :"unknown:unknown"
      assert event.data == %{}
      assert event.subject_id == "test-stream"
    end

    test "handles map with no type field at all (extract_signal_type fallback)" do
      # Missing :type key entirely triggers the catch-all clause
      signal = %{
        id: "sig_no_type",
        data: %{foo: "bar"},
        category: :activity,
        source: nil,
        cause_id: nil,
        correlation_id: nil,
        timestamp: DateTime.utc_now()
      }

      # extract_signal_type(_signal) -> :unknown
      # but extract_category will still try to access signal.type
      # in the cond branch, which will raise KeyError caught by the
      # true -> :unknown fallback
      assert {:ok, event} = SignalTransformer.signal_to_event(signal, "fallback-stream")
      assert event.data == %{foo: "bar"}
    end

    test "uses jido_causation_id when cause_id is nil" do
      signal = %{
        id: "sig_jido_cause",
        type: :activity,
        category: :activity,
        data: %{},
        source: "test",
        cause_id: nil,
        jido_causation_id: "jido_cause_123",
        correlation_id: nil,
        jido_correlation_id: nil,
        timestamp: DateTime.utc_now()
      }

      {:ok, event} = SignalTransformer.signal_to_event(signal, "global")
      assert event.causation_id == "jido_cause_123"
    end

    test "uses jido_correlation_id when correlation_id is nil" do
      signal = %{
        id: "sig_jido_corr",
        type: :activity,
        category: :activity,
        data: %{},
        source: "test",
        cause_id: nil,
        correlation_id: nil,
        jido_correlation_id: "jido_corr_456",
        timestamp: DateTime.utc_now()
      }

      {:ok, event} = SignalTransformer.signal_to_event(signal, "global")
      assert event.correlation_id == "jido_corr_456"
    end

    test "prefers cause_id over jido_causation_id when both present" do
      signal = %{
        id: "sig_both_cause",
        type: :activity,
        category: :activity,
        data: %{},
        source: "test",
        cause_id: "primary_cause",
        jido_causation_id: "jido_cause_secondary",
        correlation_id: "primary_corr",
        jido_correlation_id: "jido_corr_secondary",
        timestamp: DateTime.utc_now()
      }

      {:ok, event} = SignalTransformer.signal_to_event(signal, "global")
      assert event.causation_id == "primary_cause"
      assert event.correlation_id == "primary_corr"
    end

    test "handles map with nil data field" do
      signal = %{
        id: "sig_nil_data",
        type: :activity,
        category: :activity,
        data: nil,
        source: nil,
        cause_id: nil,
        correlation_id: nil,
        timestamp: DateTime.utc_now()
      }

      {:ok, event} = SignalTransformer.signal_to_event(signal, "global")
      # nil data is replaced with %{} via `signal.data || %{}`
      assert event.data == %{}
    end

    test "handles map missing optional fields via get_in_safe rescue" do
      # A struct-like map that might raise on Map.get for missing keys
      # get_in_safe rescues any error and returns nil
      signal = %{
        id: "sig_minimal",
        type: :activity,
        category: :activity,
        data: %{test: true}
      }

      {:ok, event} = SignalTransformer.signal_to_event(signal, "minimal-stream")
      assert event.data == %{test: true}
      assert event.metadata[:source] == nil
      assert event.metadata[:priority] == nil
      assert event.causation_id == nil
      assert event.correlation_id == nil
    end

    test "handles binary type with arbor. prefix for CloudEvents" do
      signal = %{
        id: "sig_cloud",
        type: "arbor.security.authorization",
        category: nil,
        data: %{},
        source: "cloud",
        cause_id: nil,
        correlation_id: nil,
        timestamp: DateTime.utc_now()
      }

      {:ok, event} = SignalTransformer.signal_to_event(signal, "cloud-stream")
      # extract_category parses "arbor.security.authorization" -> :security
      # extract_signal_type parses "arbor.security.authorization" -> :authorization
      assert event.type == :"security:authorization"
    end

    test "handles binary type without arbor. prefix" do
      signal = %{
        id: "sig_plain_binary",
        type: "custom.my_event",
        category: nil,
        data: %{},
        source: nil,
        cause_id: nil,
        correlation_id: nil,
        timestamp: DateTime.utc_now()
      }

      {:ok, event} = SignalTransformer.signal_to_event(signal, "custom-stream")
      # extract_category: splits "custom.my_event" -> "custom" -> :custom
      assert event.subject_id == "custom-stream"
    end

    test "handles signal with timestamp fallback to :time field" do
      now = ~U[2026-01-15 12:00:00Z]

      signal = %{
        id: "sig_time_field",
        type: :activity,
        category: :activity,
        data: %{},
        source: nil,
        cause_id: nil,
        correlation_id: nil,
        time: now
      }

      {:ok, event} = SignalTransformer.signal_to_event(signal, "time-stream")
      # get_in_safe(signal, :timestamp) returns nil, falls back to
      # get_in_safe(signal, :time) which returns now
      assert event.timestamp == now
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
