defmodule Arbor.Signals.RelayAuthoritySecurityRegressionTest do
  use Arbor.Signals.TestCase
  @moduletag spec: "KSEC-010,KSEC-016"

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Signals.Bus
  alias Arbor.Signals.Relay
  alias Arbor.Signals.Signal

  @tag spec: "KSEC-010,KSEC-016"
  test "security regression: relay custody is owner-private and absent from process state" do
    relay_pid = Process.whereis(Relay)
    bus_pid = Process.whereis(Bus)
    relay_state = :sys.get_state(relay_pid)
    bus_state = :sys.get_state(bus_pid)

    refute Map.has_key?(relay_state, :bus_delivery_ref)
    refute Map.has_key?(relay_state, :ingress_tokens)
    refute Map.has_key?(relay_state, :egress_tokens)
    refute Map.has_key?(bus_state, :relay_delivery_ref)
    refute Map.has_key?(bus_state, :relay_registration_key)

    assert :ets.info(relay_state.custody, :owner) == relay_pid
    assert :ets.info(relay_state.custody, :protection) == :private
    assert :ets.info(bus_state.relay_custody, :owner) == bus_pid
    assert :ets.info(bus_state.relay_custody, :protection) == :private

    assert_raise ArgumentError, fn -> :ets.lookup(relay_state.custody, :bus_proof) end

    assert_raise ArgumentError, fn ->
      :ets.insert(relay_state.custody, {:bus_proof, <<0::256>>})
    end

    assert_raise ArgumentError, fn -> :ets.lookup(bus_state.relay_custody, :relay_proof) end

    assert_raise ArgumentError, fn ->
      :ets.insert(bus_state.relay_custody, {:relay_proof, <<0::256>>})
    end

    directory = Relay.custody_directory()
    assert :ets.info(directory, :owner) == relay_pid
    assert :ets.info(directory, :protection) == :protected
    assert [{:relay, ^relay_pid, digest}] = :ets.lookup(directory, :relay)
    assert is_binary(digest) and byte_size(digest) == 32
    assert_raise ArgumentError, fn -> :ets.insert(directory, {:relay, self(), <<0::256>>}) end

    # The retired challenge endpoint must not return a Bus-generated proof,
    # even when the raw call asserts the real Relay pid and uses an alias reply.
    assert {:error, :unsupported_request} = forged_call(Bus, relay_pid, :begin_relay_registration)

    assert {:error, :unauthorized} =
             forged_call(Bus, relay_pid, {:register_relay, :crypto.strong_rand_bytes(32)})
  end

  test "security regression: only the supervised Bus can queue relay egress" do
    signal = Signal.new(:security, :capability_revoked, %{capability_ids: ["cap_forged"]})

    assert {:error, :unauthorized} = Relay.relay(signal)

    # GenServer `from` is protocol data, not an unforgeable sender identity.
    # Claiming the real Bus pid must still fail without the custody reference
    # established by the supervised Bus/Relay registration handshake.
    before_batch = :sys.get_state(Relay).batch
    proof = :crypto.strong_rand_bytes(32)

    assert {:error, :unsupported_request} =
             forged_call(Relay, Process.whereis(Bus), {:relay, signal, proof})

    GenServer.cast(Relay, {:relay, signal, proof})
    _stats = Relay.stats()
    assert :sys.get_state(Relay).batch == before_batch
  end

  test "security regression: copied state locators cannot replace relay custody" do
    signal = Signal.new(:activity, :forged_custody, %{attack: true})
    forged_proof = :crypto.strong_rand_bytes(32)
    relay_state = :sys.get_state(Relay)
    bus_state = :sys.get_state(Bus)
    attacker_relay_table = :ets.new(:attacker_relay_custody, [:set, :public])
    attacker_bus_table = :ets.new(:attacker_bus_custody, [:set, :public])
    true = :ets.insert(attacker_relay_table, {:bus_proof, forged_proof})
    true = :ets.insert(attacker_bus_table, {:relay_proof, forged_proof})

    try do
      before_batch = relay_state.batch
      :sys.replace_state(Relay, &Map.put(&1, :custody, attacker_relay_table))
      GenServer.cast(Relay, {:relay, signal, forged_proof})
      _stats = Relay.stats()
      assert :sys.get_state(Relay).batch == before_batch

      :sys.replace_state(Bus, &Map.put(&1, :relay_custody, attacker_bus_table))

      assert {:error, :unauthorized} =
               forged_call(
                 Bus,
                 Process.whereis(Relay),
                 {:publish_remote, signal, forged_proof}
               )
    after
      :sys.replace_state(Relay, &Map.put(&1, :custody, relay_state.custody))
      :sys.replace_state(Bus, &Map.put(&1, :relay_custody, bus_state.relay_custody))
      :ets.delete(attacker_relay_table)
      :ets.delete(attacker_bus_table)
    end
  end

  test "security regression: a caller-supplied node cannot forge relay ingress" do
    test_pid = self()

    assert {:ok, sub_id} =
             Bus.subscribe(
               "activity.forged_relay_ingress",
               fn signal ->
                 send(test_pid, {:forged_relay_ingress, signal})
                 :ok
               end,
               async: false
             )

    signal = Signal.new(:activity, :forged_relay_ingress, %{attack: true})

    # This was the old public wire protocol. GenServer.cast carries no caller
    # identity, so `from_node` was attacker-controlled and the real Relay
    # laundered the signal through its trusted Bus ingress.
    GenServer.cast(Relay, {:receive_batch, [signal], node()})

    refute_receive {:forged_relay_ingress, _signal}, 100

    # The reverse deputy is protected by the same custody reference: a raw
    # call that claims the real Relay pid cannot make Bus trust remote data.
    assert {:error, :unauthorized} =
             forged_call(
               Bus,
               Process.whereis(Relay),
               {:publish_remote, signal, :crypto.strong_rand_bytes(32)}
             )

    refute_receive {:forged_relay_ingress, _signal}, 100
    assert :ok = Bus.unsubscribe(sub_id)
  end

  test "security regression: a registered-name thief cannot become the trusted relay" do
    %{relay_pid: relay_pid, relay_monitor_ref: monitor_ref} = :sys.get_state(Bus)
    assert is_pid(relay_pid)
    assert is_reference(monitor_ref)

    # Exercise the same recovery handshake used after the monitored relay goes
    # down, while keeping the supervised child alive for the provenance check.
    send(Bus, {:DOWN, monitor_ref, :process, relay_pid, :simulated_recovery})
    _stats = Bus.stats()

    assert %{relay_pid: nil, relay_monitor_ref: nil, relay_custody: custody} =
             :sys.get_state(Bus)

    assert :ets.info(custody, :size) == 0

    assert Process.unregister(Relay)

    on_exit(&restore_supervised_relay/0)

    result =
      Task.async(fn ->
        true = Process.register(self(), Relay)

        try do
          Bus.register_relay(:crypto.strong_rand_bytes(32))
        after
          if Process.whereis(Relay) == self(), do: Process.unregister(Relay)
        end
      end)
      |> Task.await()

    assert {:error, :unauthorized} = result
    restore_supervised_relay()
  end

  test "security regression: the supervised relay re-registers after Bus recovery" do
    supervisor = Process.whereis(Arbor.Signals.Supervisor)
    relay_pid = Process.whereis(Relay)
    old_bus_pid = Process.whereis(Bus)
    old_custody = :sys.get_state(old_bus_pid).relay_custody

    assert :ok = Supervisor.terminate_child(supervisor, Bus)
    assert {:ok, new_bus_pid} = Supervisor.restart_child(supervisor, Bus)
    refute new_bus_pid == old_bus_pid
    assert :ets.info(old_custody) == :undefined

    assert eventually(fn ->
             bus_state = :sys.get_state(new_bus_pid)
             relay_state = :sys.get_state(relay_pid)

             bus_state.relay_pid == relay_pid and
               :ets.info(bus_state.relay_custody, :owner) == new_bus_pid and
               :ets.info(bus_state.relay_custody, :size) == 1 and
               :ets.info(relay_state.custody, :owner) == relay_pid and
               relay_state.bus_pid == new_bus_pid and
               is_reference(relay_state.bus_monitor_ref)
           end)
  end

  test "security regression: relay restart rotates proof and clears Bus custody" do
    supervisor = Process.whereis(Arbor.Signals.Supervisor)
    bus_pid = Process.whereis(Bus)
    old_relay_pid = Process.whereis(Relay)
    old_relay_custody = :sys.get_state(old_relay_pid).custody
    [{:relay, ^old_relay_pid, old_digest}] = :ets.lookup(Relay.custody_directory(), :relay)

    assert :ok = Supervisor.terminate_child(supervisor, Relay)
    assert :ets.info(old_relay_custody) == :undefined

    assert eventually(fn ->
             state = :sys.get_state(bus_pid)
             state.relay_pid == nil and :ets.info(state.relay_custody, :size) == 0
           end)

    assert {:ok, new_relay_pid} = Supervisor.restart_child(supervisor, Relay)
    refute new_relay_pid == old_relay_pid

    assert eventually(fn ->
             bus_state = :sys.get_state(bus_pid)
             relay_state = :sys.get_state(new_relay_pid)

             bus_state.relay_pid == new_relay_pid and
               :ets.info(bus_state.relay_custody, :size) == 1 and
               :ets.info(relay_state.custody, :owner) == new_relay_pid and
               match?(
                 [{:relay, ^new_relay_pid, digest}] when digest != old_digest,
                 :ets.lookup(Relay.custody_directory(), :relay)
               )
           end)
  end

  defp restore_supervised_relay do
    supervisor = Process.whereis(Arbor.Signals.Supervisor)

    if is_pid(supervisor) do
      case Supervisor.terminate_child(supervisor, Relay) do
        :ok -> :ok
        {:error, :not_found} -> :ok
      end

      case Supervisor.restart_child(supervisor, Relay) do
        {:ok, _pid} ->
          :ok

        {:ok, _pid, _info} ->
          :ok

        {:error, :running} ->
          :ok

        {:error, :not_found} ->
          case Supervisor.start_child(supervisor, {Relay, []}) do
            {:ok, _pid} -> :ok
            {:error, {:already_started, _pid}} -> :ok
          end
      end

      eventually(fn ->
        relay_pid = Process.whereis(Relay)
        state = :sys.get_state(Bus)
        is_pid(relay_pid) and state.relay_pid == relay_pid
      end)
    end

    :ok
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp forged_call(server, asserted_pid, message) do
    reply = :erlang.alias()
    tag = [:alias | reply]
    send(server, {:"$gen_call", {asserted_pid, tag}, message})

    try do
      receive do
        {^tag, result} -> result
      after
        2_000 -> flunk("forged relay authority call did not settle")
      end
    after
      :erlang.unalias(reply)
    end
  end
end
