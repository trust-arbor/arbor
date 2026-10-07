defmodule Arbor.Monitor.AnomalyForwarderAuthoritySecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag spec: "KSEC-011"

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Monitor.AnomalyForwarder

  setup do
    owner_name = __MODULE__.TrustedProducer
    child_id = {:trusted_producer, System.unique_integer([:positive])}

    child_spec =
      Supervisor.child_spec(
        {__MODULE__.TrustedProducer, name: owner_name},
        id: child_id
      )

    {:ok, supervisor} = Supervisor.start_link([child_spec], strategy: :one_for_one)
    Process.unlink(supervisor)
    on_exit(fn -> stop_supervisor(supervisor) end)
    owner_pid = Process.whereis(owner_name)
    channel_owner_secret = :crypto.strong_rand_bytes(32)
    channel_owner_proof = :crypto.hash(:sha256, channel_owner_secret)

    {:ok, _forwarder} =
      start_supervised(
        {AnomalyForwarder,
         channel_owner_proof: channel_owner_proof,
         trusted_producers: %{anomaly_detected: owner_name},
         trusted_producer_provenance: %{owner_name => {supervisor, [child_id]}}}
      )

    %{
      channel_owner_secret: channel_owner_secret,
      owner_name: owner_name,
      owner_pid: owner_pid
    }
  end

  @tag spec: "KSEC-011"
  test "security regression: a registered-name thief cannot impersonate a supervised producer",
       %{owner_name: owner_name, owner_pid: owner_pid} do
    signal = %{type: :anomaly_detected, data: %{details: "trusted"}}
    assert :ok = GenServer.call(owner_pid, {:forward, signal})

    assert Process.unregister(owner_name)

    result =
      Task.async(fn ->
        true = Process.register(self(), owner_name)

        try do
          AnomalyForwarder.forward(%{
            type: :anomaly_detected,
            data: %{details: "forged system message"}
          })
        after
          if Process.whereis(owner_name) == self(), do: Process.unregister(owner_name)
        end
      end)
      |> Task.await()

    assert {:error, :unauthorized_producer} = result
    assert Process.register(owner_pid, owner_name)
  end

  test "security regression: a raw gen call cannot claim a supervised producer", %{
    owner_pid: owner_pid
  } do
    signal = %{
      type: :anomaly_detected,
      data: %{details: "forged system-forwarded payload"}
    }

    assert {:error, :unauthorized} =
             forged_call(AnomalyForwarder, owner_pid, {:forward, signal})

    assert :ok = GenServer.call(owner_pid, {:forward, signal})
  end

  test "security regression: arbitrary callers cannot bind or redirect the ops channel", %{
    channel_owner_secret: channel_owner_secret
  } do
    assert {:error, :unauthorized} = AnomalyForwarder.set_channel("attacker-room")

    assert {:error, :unauthorized} =
             AnomalyForwarder.set_channel("attacker-room", :crypto.strong_rand_bytes(32))

    leaked_proof = :sys.get_state(AnomalyForwarder).channel_owner_proof

    assert {:error, :unauthorized} =
             AnomalyForwarder.set_channel("attacker-room", leaked_proof)

    assert :ok = AnomalyForwarder.set_channel("trusted-room", channel_owner_secret)

    assert {:error, :channel_already_bound} =
             AnomalyForwarder.set_channel("redirected-room", channel_owner_secret)
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
    def handle_call({:forward, signal}, _from, state) do
      {:reply, Arbor.Monitor.AnomalyForwarder.forward(signal), state}
    end
  end

  defp forged_call(server, asserted_pid, request) do
    reply = :erlang.alias()
    tag = [:alias | reply]
    send(server, {:"$gen_call", {asserted_pid, tag}, request})

    try do
      receive do
        {^tag, result} -> result
      after
        2_000 -> flunk("forged AnomalyForwarder call did not settle")
      end
    after
      :erlang.unalias(reply)
    end
  end

  defp stop_supervisor(supervisor) do
    Supervisor.stop(supervisor)
  catch
    :exit, :noproc -> :ok
    :exit, {:noproc, _details} -> :ok
  end
end
