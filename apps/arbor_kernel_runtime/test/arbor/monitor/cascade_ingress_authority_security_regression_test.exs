defmodule Arbor.Monitor.CascadeIngressAuthoritySecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag spec: "KSEC-011"

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Monitor.{AnomalyForwarder, AnomalyQueue, CascadeDetector}
  alias Arbor.Monitor.Config.Testing

  setup do
    Testing.isolate_namespace()
    Testing.put(:channel_bridge_module, __MODULE__.RecordingBridge)
    Testing.put(:k11_test_pid, self())

    producer_name = __MODULE__.TrustedProducer
    {:ok, producer_pid} = start_supervised({__MODULE__.TrustedProducer, name: producer_name})

    {:ok, detector_pid} =
      start_supervised(
        {CascadeDetector,
         window_ms: 1_000,
         cascade_threshold: 1,
         settling_cycles: 2,
         exit_threshold_ms: 1_000,
         check_interval_ms: 100,
         trusted_polling_producer: producer_pid}
      )

    owner_secret = :crypto.strong_rand_bytes(32)

    {:ok, _forwarder_pid} =
      start_supervised(
        {AnomalyForwarder,
         channel_owner_proof: :crypto.hash(:sha256, owner_secret),
         trusted_producers: %{cascade_detected: detector_pid}}
      )

    assert :ok = AnomalyForwarder.set_channel("security-regression", owner_secret)

    {:ok, _queue_pid} =
      start_supervised({AnomalyQueue, trusted_enqueue_producer: producer_pid})

    %{producer_pid: producer_pid}
  end

  @tag spec: "KSEC-011"
  test "security regression: forged queue and cascade ingress cannot become a trusted system message",
       %{producer_pid: producer_pid} do
    anomaly = anomaly()

    GenServer.cast(CascadeDetector, {:record_anomaly, anomaly})
    GenServer.cast(CascadeDetector, :polling_cycle_completed)
    assert CascadeDetector.current_rate() == 0
    refute_received {:deliver, _, _, _, _, _}

    assert {:error, :unauthorized} =
             Task.async(fn -> CascadeDetector.record_anomaly(anomaly) end) |> Task.await()

    assert {:error, :unauthorized} =
             forged_call(AnomalyQueue, producer_pid, {:enqueue, anomaly})

    assert {:error, :unauthorized} =
             Task.async(fn -> AnomalyQueue.enqueue(anomaly) end) |> Task.await()

    assert AnomalyQueue.size() == 0
    assert CascadeDetector.current_rate() == 0
    refute_received {:deliver, _, _, _, _, _}

    assert {:ok, :enqueued} = GenServer.call(producer_pid, {:enqueue, anomaly})
    assert AnomalyQueue.size() == 1
    assert CascadeDetector.current_rate() == 1

    assert_received {:deliver, "security-regression", "anomaly_forwarder", "Monitor", :system,
                     content}

    assert content =~ "[CASCADE]"

    assert CascadeDetector.status().settling_cycles_remaining == 2
    GenServer.cast(CascadeDetector, :polling_cycle_completed)
    assert CascadeDetector.status().settling_cycles_remaining == 2

    assert :ok = GenServer.call(producer_pid, :polling_cycle_completed)
    assert CascadeDetector.status().settling_cycles_remaining == 1
  end

  defp anomaly do
    %{
      skill: :memory,
      severity: :warning,
      details: %{metric: :total_bytes, value: 1_000_000, ewma: 800_000, stddev: 10_000},
      timestamp: DateTime.utc_now()
    }
  end

  defp forged_call(server, asserted_pid, request) do
    reply = :erlang.alias()
    tag = [:alias | reply]
    send(server, {:"$gen_call", {asserted_pid, tag}, request})

    try do
      receive do
        {^tag, result} -> result
      after
        2_000 -> flunk("forged queue call did not settle")
      end
    after
      :erlang.unalias(reply)
    end
  end

  defmodule TrustedProducer do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, :ok, name: Keyword.fetch!(opts, :name))
    end

    @impl true
    def init(:ok) do
      Process.flag(:sensitive, true)
      {:ok, nil}
    end

    @impl true
    def handle_call({:enqueue, anomaly}, _from, state) do
      {:reply, Arbor.Monitor.AnomalyQueue.enqueue(anomaly), state}
    end

    def handle_call(:polling_cycle_completed, _from, state) do
      {:reply, Arbor.Monitor.CascadeDetector.polling_cycle_completed(), state}
    end
  end

  defmodule RecordingBridge do
    def deliver_channel_message(channel_id, sender_id, sender_name, sender_type, content) do
      if test_pid = Testing.get(:k11_test_pid) do
        send(test_pid, {:deliver, channel_id, sender_id, sender_name, sender_type, content})
      end

      :ok
    end
  end
end
