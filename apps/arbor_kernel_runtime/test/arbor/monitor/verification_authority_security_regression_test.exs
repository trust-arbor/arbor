defmodule Arbor.Monitor.VerificationAuthoritySecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag spec: "KSEC-011"

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Monitor.{AnomalyForwarder, Fingerprint, Verification}
  alias Arbor.Monitor.Config.Testing

  setup do
    Testing.isolate_namespace()
    Testing.put(:channel_bridge_module, __MODULE__.RecordingBridge)
    Testing.put(:k11_verification_test_pid, self())

    {:ok, producer_pid} =
      start_supervised({__MODULE__.TrustedProducer, name: __MODULE__.TrustedProducer})

    {:ok, verification_pid} =
      start_supervised({Verification, soak_cycles: 1, trusted_mutation_producer: producer_pid})

    owner_secret = :crypto.strong_rand_bytes(32)

    {:ok, _forwarder_pid} =
      start_supervised(
        {AnomalyForwarder,
         channel_owner_proof: :crypto.hash(:sha256, owner_secret),
         trusted_producers: %{
           healing_verified: verification_pid,
           healing_ineffective: verification_pid
         }}
      )

    assert :ok = AnomalyForwarder.set_channel("verification-regression", owner_secret)

    %{producer_pid: producer_pid}
  end

  @tag spec: "KSEC-011"
  test "security regression: forged verification mutations cannot create or forward outcomes",
       %{producer_pid: producer_pid} do
    fingerprint = Fingerprint.new(:memory, :total_bytes, :above)

    assert {:error, :unauthorized} =
             forged_call(
               Verification,
               producer_pid,
               {:start_verification, fingerprint, "forged-proposal"}
             )

    assert {:error, :unauthorized} =
             Task.async(fn ->
               Verification.start_verification(fingerprint, "forged-proposal")
             end)
             |> Task.await()

    assert Verification.get_verification(fingerprint) == nil
    refute_received {:deliver, _, _, _, _, _}

    assert {:ok, _verification_id} =
             GenServer.call(
               producer_pid,
               {:start_verification, fingerprint, "trusted-proposal"}
             )

    assert {:error, :unauthorized} = forged_call(Verification, producer_pid, :tick)
    assert Verification.get_verification(fingerprint).cycles_remaining == 1
    refute_received {:deliver, _, _, _, _, _}

    assert [%{status: :verified}] = GenServer.call(producer_pid, :tick)

    assert_received {:deliver, "verification-regression", "anomaly_forwarder", "Monitor", :system,
                     verified_content}

    assert verified_content =~ "[VERIFIED]"

    recurring = Fingerprint.new(:ets, :table_count, :above)

    assert {:ok, _verification_id} =
             GenServer.call(producer_pid, {:start_verification, recurring, "recurring"})

    anomaly = %{
      skill: :ets,
      severity: :warning,
      details: %{metric: :table_count, value: 200, ewma: 100}
    }

    assert {:error, :unauthorized} =
             forged_call(Verification, producer_pid, {:check_recurrences, [anomaly]})

    assert Verification.get_verification(recurring).outcome == :verifying
    refute_received {:deliver, _, _, _, _, _}

    assert [%{status: :ineffective}] =
             GenServer.call(producer_pid, {:check_recurrences, [anomaly]})

    assert_received {:deliver, "verification-regression", "anomaly_forwarder", "Monitor", :system,
                     ineffective_content}

    assert ineffective_content =~ "[INEFFECTIVE]"
  end

  defp forged_call(server, asserted_pid, request) do
    reply = :erlang.alias()
    tag = [:alias | reply]
    send(server, {:"$gen_call", {asserted_pid, tag}, request})

    try do
      receive do
        {^tag, result} -> result
      after
        2_000 -> flunk("forged verification call did not settle")
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
    def handle_call({:start_verification, fingerprint, proposal_id}, _from, state) do
      {:reply, Verification.start_verification(fingerprint, proposal_id), state}
    end

    def handle_call({:check_recurrences, anomalies}, _from, state) do
      {:reply, Verification.check_recurrences(anomalies), state}
    end

    def handle_call(:tick, _from, state) do
      {:reply, Verification.tick(), state}
    end
  end

  defmodule RecordingBridge do
    def deliver_channel_message(channel_id, sender_id, sender_name, sender_type, content) do
      if test_pid = Testing.get(:k11_verification_test_pid) do
        send(test_pid, {:deliver, channel_id, sender_id, sender_name, sender_type, content})
      end

      :ok
    end
  end
end
