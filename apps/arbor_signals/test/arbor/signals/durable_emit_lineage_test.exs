defmodule Arbor.Signals.DurableEmitLineageTest do
  @moduledoc """
  durable_emit forwards Signals-shaped primitives to the configured sink
  and fails softly for absent or malformed providers.
  """
  use Arbor.Signals.TestCase

  import ExUnit.CaptureLog

  @moduletag :fast

  setup do
    original = Application.get_env(:arbor_signals, :durable_sink_module, :unset)
    Application.delete_env(:arbor_signals, :durable_sink_module)

    on_exit(fn -> restore(:durable_sink_module, original) end)

    :ok
  end

  test "nil sink still emits realtime with :permanent and stays silent" do
    suffix = System.unique_integer([:positive])
    type = :"permanent_probe_#{suffix}"
    stream_id = "silent_#{suffix}"

    log =
      capture_log(fn ->
        assert :ok =
                 Arbor.Signals.durable_emit(:activity, type, %{probe: suffix},
                   stream_id: stream_id
                 )
      end)

    {:ok, signals} = Arbor.Signals.recent(limit: 50, category: :activity, type: type)
    signal = Enum.find(signals, &(&1.type == type))
    assert signal, "expected realtime signal #{inspect(type)}"
    assert signal.data.permanent == true
    assert signal.data.probe == suffix
    refute log =~ stream_id
  end

  test "recording sink receives original data and lineage without :permanent" do
    Application.put_env(:arbor_signals, :durable_sink_test_pid, self())
    Application.put_env(:arbor_signals, :durable_sink_module, __MODULE__.RecordingSink)

    on_exit(fn -> Application.delete_env(:arbor_signals, :durable_sink_test_pid) end)

    suffix = System.unique_integer([:positive])
    stream_id = "audit_lineage_#{suffix}"
    type = :"lineage_probe_#{suffix}"

    assert :ok =
             Arbor.Signals.durable_emit(
               :activity,
               type,
               %{probe: true},
               stream_id: stream_id,
               async: false,
               source: "caller",
               correlation_id: "corr_#{suffix}",
               cause_id: "cause_#{suffix}",
               agent_id: "agent_#{suffix}",
               metadata: %{
                 "source_node" => "spoofed_string_node",
                 audit_reason: "lineage_regression",
                 source_node: :spoofed_atom_node
               }
             )

    {:ok, signals} = Arbor.Signals.recent(limit: 50, category: :activity, type: type)
    signal = Enum.find(signals, &(&1.type == type))
    assert signal, "expected realtime signal #{inspect(type)}"
    assert signal.data.permanent == true

    assert_receive {:sink, ^stream_id, ^type, data, opts}
    assert data == %{probe: true}
    refute Map.has_key?(data, :permanent)
    assert Keyword.get(opts, :correlation_id) == "corr_#{suffix}"
    assert Keyword.get(opts, :cause_id) == "cause_#{suffix}"
    assert Keyword.get(opts, :agent_id) == "agent_#{suffix}"
    assert Keyword.get(opts, :metadata)[:audit_reason] == "lineage_regression"
    assert Keyword.get(opts, :metadata)[:source_node] == :spoofed_atom_node
    refute Keyword.has_key?(opts, :stream_id)
    refute Keyword.has_key?(opts, :async)
    refute Keyword.has_key?(opts, :source)
  end

  test "invalid, missing, malformed, raising, throwing, and exiting sinks stay :ok" do
    suffix = System.unique_integer([:positive])
    type = :"soft_fail_#{suffix}"

    providers = [
      {"not-a-module", "invalid_provider"},
      {__MODULE__.Empty, "missing_callback"},
      {__MODULE__.MalformedSink, "malformed_result"},
      {__MODULE__.RaiseSink, "provider_raised"},
      {__MODULE__.ThrowSink, "provider_threw"},
      {__MODULE__.ExitSink, "provider_exited"}
    ]

    Enum.each(providers, fn {provider, reason} ->
      Application.put_env(:arbor_signals, :durable_sink_module, provider)

      log =
        capture_log(fn ->
          assert :ok =
                   Arbor.Signals.durable_emit(:activity, type, %{secret: "payload"},
                     stream_id: "soft_#{suffix}"
                   )
        end)

      assert log =~ "soft_#{suffix}"
      assert log =~ reason
      refute log =~ "secret"
      refute log =~ "payload"
    end)
  end

  defp restore(key, :unset), do: Application.delete_env(:arbor_signals, key)
  defp restore(key, value), do: Application.put_env(:arbor_signals, key, value)

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

  defmodule Empty do
  end

  defmodule MalformedSink do
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
end
