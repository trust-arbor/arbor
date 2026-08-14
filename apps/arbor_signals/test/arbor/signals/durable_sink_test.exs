defmodule Arbor.Signals.DurableSinkTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @moduletag :fast

  alias Arbor.Signals.DurableSink

  setup do
    original = Application.get_env(:arbor_signals, :durable_sink_module, :unset)
    Application.delete_env(:arbor_signals, :durable_sink_module)

    on_exit(fn -> restore(:durable_sink_module, original) end)

    :ok
  end

  test "absent provider skips without invoking a callback" do
    assert DurableSink.dispatch("activity_events", :probe, %{k: 1}, []) == {:skip, :absent}
  end

  test "invalid providers skip before invocation" do
    Application.put_env(:arbor_signals, :durable_sink_module, "not-a-module")
    assert DurableSink.dispatch("s", :t, %{}, []) == {:skip, :invalid_provider}

    Application.put_env(:arbor_signals, :durable_sink_module, true)
    assert DurableSink.dispatch("s", :t, %{}, []) == {:skip, :invalid_provider}

    Application.put_env(:arbor_signals, :durable_sink_module, false)
    assert DurableSink.dispatch("s", :t, %{}, []) == {:skip, :invalid_provider}
  end

  test "missing callback skips before invocation" do
    Application.put_env(:arbor_signals, :durable_sink_module, __MODULE__.Empty)
    assert DurableSink.dispatch("s", :t, %{}, []) == {:skip, :missing_callback}
  end

  test "admitted :ok and persist_failed; rejects malformed results" do
    Application.put_env(:arbor_signals, :durable_sink_module, __MODULE__.OkSink)
    assert DurableSink.dispatch("s", :t, %{}, []) == :ok

    Application.put_env(:arbor_signals, :durable_sink_module, __MODULE__.PersistFailedSink)
    assert DurableSink.dispatch("s", :t, %{}, []) == {:error, :persist_failed}

    Application.put_env(:arbor_signals, :durable_sink_module, __MODULE__.BoomErrorSink)
    assert DurableSink.dispatch("s", :t, %{}, []) == {:skip, :malformed_result}

    Application.put_env(:arbor_signals, :durable_sink_module, __MODULE__.OtherOkSink)
    assert DurableSink.dispatch("s", :t, %{}, []) == {:skip, :malformed_result}
  end

  test "normalizes raise, throw, and exit" do
    Application.put_env(:arbor_signals, :durable_sink_module, __MODULE__.RaiseSink)

    assert DurableSink.dispatch("s", :t, %{}, []) ==
             {:skip, :provider_raised, RuntimeError}

    Application.put_env(:arbor_signals, :durable_sink_module, __MODULE__.ThrowSink)
    assert DurableSink.dispatch("s", :t, %{}, []) == {:skip, :provider_threw}

    Application.put_env(:arbor_signals, :durable_sink_module, __MODULE__.ExitSink)
    assert DurableSink.dispatch("s", :t, %{}, []) == {:skip, :provider_exited}
  end

  test "forwards stream, type, original data, and bounded opts only" do
    Application.put_env(:arbor_signals, :durable_sink_test_pid, self())
    Application.put_env(:arbor_signals, :durable_sink_module, __MODULE__.RecordingSink)

    on_exit(fn -> Application.delete_env(:arbor_signals, :durable_sink_test_pid) end)

    opts = [
      stream_id: "custom_stream",
      async: false,
      source: "caller",
      correlation_id: "corr_1",
      cause_id: "cause_1",
      agent_id: "agent_1",
      metadata: %{audit_reason: "forward"},
      permanent: true
    ]

    assert DurableSink.dispatch("activity_events", :probe, %{k: 1}, opts) == :ok

    assert_receive {:sink, "activity_events", :probe, %{k: 1}, forwarded}

    assert Keyword.get(forwarded, :correlation_id) == "corr_1"
    assert Keyword.get(forwarded, :cause_id) == "cause_1"
    assert Keyword.get(forwarded, :agent_id) == "agent_1"
    assert Keyword.get(forwarded, :metadata) == %{audit_reason: "forward"}
    refute Keyword.has_key?(forwarded, :stream_id)
    refute Keyword.has_key?(forwarded, :async)
    refute Keyword.has_key?(forwarded, :source)
    refute Keyword.has_key?(forwarded, :permanent)
  end

  test "omits nil lineage and coerces non-map metadata" do
    Application.put_env(:arbor_signals, :durable_sink_test_pid, self())
    Application.put_env(:arbor_signals, :durable_sink_module, __MODULE__.RecordingSink)

    on_exit(fn -> Application.delete_env(:arbor_signals, :durable_sink_test_pid) end)

    assert DurableSink.dispatch("s", :t, %{},
             correlation_id: nil,
             cause_id: nil,
             agent_id: nil,
             metadata: :not_a_map
           ) == :ok

    assert_receive {:sink, "s", :t, %{}, forwarded}
    refute Keyword.has_key?(forwarded, :correlation_id)
    refute Keyword.has_key?(forwarded, :cause_id)
    refute Keyword.has_key?(forwarded, :agent_id)
    assert Keyword.get(forwarded, :metadata) == %{}
  end

  test "logs bounded diagnostics except for an absent sink" do
    log =
      capture_log(fn ->
        assert DurableSink.dispatch("silent_stream", :t, %{secret: "payload"}, []) ==
                 {:skip, :absent}
      end)

    refute log =~ "persistence gap"
    refute log =~ "secret"
    refute log =~ "payload"

    Application.put_env(:arbor_signals, :durable_sink_module, true)

    log =
      capture_log(fn ->
        DurableSink.dispatch("gap_stream", :t, %{secret: "payload"}, [])
      end)

    assert log =~ "gap_stream"
    assert log =~ "invalid_provider"
    refute log =~ "secret"
    refute log =~ "payload"
  end

  test "security regression: long stream_id is bounded and tail is absent from logs" do
    Application.put_env(:arbor_signals, :durable_sink_module, true)
    tail = "TAIL_MUST_NOT_APPEAR_k1e"
    stream_id = String.duplicate("s", 80) <> tail

    log =
      capture_log(fn ->
        assert DurableSink.dispatch(stream_id, :t, %{secret: "payload"}, []) ==
                 {:skip, :invalid_provider}
      end)

    assert log =~ "invalid_provider"
    assert log =~ String.duplicate("s", 64)
    assert log =~ "..."
    refute log =~ tail
    refute log =~ stream_id
    refute log =~ "secret"
  end

  test "security regression: invalid UTF-8 stream_id cannot escape logs or raise" do
    Application.put_env(:arbor_signals, :durable_sink_module, true)
    tail = "TAIL_INVALID_UTF8_k1e"
    stream_id = <<"head", 0xFF, 0xFE>> <> String.duplicate("x", 80) <> tail

    log =
      capture_log(fn ->
        assert DurableSink.dispatch(stream_id, :t, %{secret: "payload"}, []) ==
                 {:skip, :invalid_provider}
      end)

    assert log =~ "invalid_provider"
    assert log =~ "head??"
    refute log =~ tail
    refute log =~ <<0xFF, 0xFE>>
    refute log =~ stream_id
    refute log =~ "secret"
  end

  defp restore(key, :unset), do: Application.delete_env(:arbor_signals, key)
  defp restore(key, value), do: Application.put_env(:arbor_signals, key, value)

  defmodule Empty do
  end

  defmodule OkSink do
    @behaviour Arbor.Signals.Contracts.DurableSink

    @impl true
    def persist_durable_event(_stream_id, _type, _data, _opts), do: :ok
  end

  defmodule PersistFailedSink do
    @behaviour Arbor.Signals.Contracts.DurableSink

    @impl true
    def persist_durable_event(_stream_id, _type, _data, _opts), do: {:error, :persist_failed}
  end

  defmodule BoomErrorSink do
    @behaviour Arbor.Signals.Contracts.DurableSink

    @impl true
    def persist_durable_event(_stream_id, _type, _data, _opts), do: {:error, :boom}
  end

  defmodule OtherOkSink do
    @behaviour Arbor.Signals.Contracts.DurableSink

    @impl true
    def persist_durable_event(_stream_id, _type, _data, _opts), do: {:ok, :accepted}
  end

  defmodule RaiseSink do
    @behaviour Arbor.Signals.Contracts.DurableSink

    @impl true
    def persist_durable_event(_stream_id, _type, _data, _opts), do: raise("provider boom")
  end

  defmodule ThrowSink do
    @behaviour Arbor.Signals.Contracts.DurableSink

    @impl true
    def persist_durable_event(_stream_id, _type, _data, _opts), do: throw(:provider_throw)
  end

  defmodule ExitSink do
    @behaviour Arbor.Signals.Contracts.DurableSink

    @impl true
    def persist_durable_event(_stream_id, _type, _data, _opts), do: exit(:provider_exit)
  end

  defmodule RecordingSink do
    @behaviour Arbor.Signals.Contracts.DurableSink

    @impl true
    def persist_durable_event(stream_id, type, data, opts) do
      if pid = Application.get_env(:arbor_signals, :durable_sink_test_pid) do
        send(pid, {:sink, stream_id, type, data, opts})
      end

      :ok
    end
  end
end
