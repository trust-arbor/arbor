defmodule Arbor.Signals.TelemetryTest do
  use Arbor.Signals.TestCase

  alias Arbor.Signals
  alias Arbor.Signals.Signal
  alias Arbor.Signals.Telemetry
  alias Arbor.Signals.TelemetryBridge

  @drop_event [:arbor, :signals, :telemetry_bridge, :dropped]

  defmodule TelemetryEmittingAuthorizer do
    @moduledoc false

    def authorize_subscription(_principal_id, _topic, _opts) do
      :telemetry.execute(
        [:arbor, :test, :bus_authorization],
        %{count: 1},
        %{
          signal_category: :activity,
          signal_type: :bus_authorization_observed,
          signal_data: %{authorized: true},
          signal_opts: [],
          signal_durable: false
        }
      )

      {:ok, :authorized}
    end
  end

  defmodule BurstTelemetryAuthorizer do
    @moduledoc false

    def authorize_subscription(_principal_id, _topic, _opts) do
      for sequence <- 1..2 do
        :telemetry.execute(
          [:arbor, :test, :bus_authorization_burst],
          %{count: 1},
          %{
            signal_category: :activity,
            signal_type: :bus_authorization_burst,
            signal_data: %{sequence: sequence},
            signal_opts: [],
            signal_durable: false
          }
        )
      end

      {:ok, :authorized}
    end
  end

  test "bridge honors explicit signal metadata from telemetry events" do
    bridge_id = "arbor-signals-telemetry-test-#{System.unique_integer([:positive])}"
    Arbor.Signals.Config.Testing.isolate_namespace()
    Arbor.Signals.Config.Testing.put(:restricted_topics, [])

    on_exit(fn ->
      Telemetry.detach(bridge_id)
    end)

    parent = self()

    {:ok, sub_id} =
      Signals.subscribe(
        "security.authorization_denied",
        fn signal ->
          send(parent, {:bridged_signal, signal})
          :ok
        end,
        async: false
      )

    on_exit(fn -> Signals.unsubscribe(sub_id) end)

    {:ok, ^bridge_id} =
      Telemetry.attach_bridge(
        [[:arbor, :security, :authorization_denied]],
        id: bridge_id,
        category: :telemetry
      )

    :telemetry.execute(
      [:arbor, :security, :authorization_denied],
      %{count: 1},
      %{
        signal_category: :security,
        signal_type: :authorization_denied,
        signal_data: %{principal_id: "agent_001", resource_uri: "arbor://fs/read"},
        signal_opts: [source: "security-kernel"],
        signal_durable: false
      }
    )

    assert_receive {:bridged_signal, %Signal{} = signal}

    assert signal.category == :security
    assert signal.type == :authorization_denied
    assert signal.source == "security-kernel"
    assert signal.data.principal_id == "agent_001"
    assert signal.data.resource_uri == "arbor://fs/read"
  end

  test "security regression: authorization telemetry cannot re-enter and wedge the bus" do
    bridge_id = "arbor-signals-reentrant-bridge-#{System.unique_integer([:positive])}"
    Arbor.Signals.Config.Testing.isolate_namespace()
    Arbor.Signals.Config.Testing.put(:restricted_topics, [:security])
    Arbor.Signals.Config.Testing.put(:authorizer, TelemetryEmittingAuthorizer)

    on_exit(fn -> Telemetry.detach(bridge_id) end)

    parent = self()

    {:ok, activity_handle} =
      Signals.subscribe("activity.bus_authorization_observed", fn signal ->
        send(parent, {:bridged_authorization, signal})
        :ok
      end)

    on_exit(fn -> Signals.unsubscribe(activity_handle) end)

    {:ok, ^bridge_id} =
      Telemetry.attach_bridge(
        [[:arbor, :test, :bus_authorization]],
        id: bridge_id,
        category: :telemetry
      )

    started_at = System.monotonic_time(:millisecond)

    assert {:ok, restricted_handle} =
             Signals.subscribe("security.*", fn _signal -> :ok end,
               principal_id: "human_reentrant_bridge"
             )

    assert System.monotonic_time(:millisecond) - started_at < 2_000

    on_exit(fn -> Signals.unsubscribe(restricted_handle) end)

    assert_receive {:bridged_authorization, %Signal{} = signal}, 1_000
    assert signal.category == :activity
    assert signal.type == :bus_authorization_observed
    assert signal.data == %{authorized: true}
  end

  test "security regression: deferred bridge queue is bounded and survives saturation" do
    bridge_id = "arbor-signals-bounded-bridge-#{System.unique_integer([:positive])}"
    handler_id = "arbor-signals-bridge-drop-#{System.unique_integer([:positive])}"
    parent = self()

    Arbor.Signals.Config.Testing.isolate_namespace()
    Arbor.Signals.Config.Testing.put(:restricted_topics, [:security])
    Arbor.Signals.Config.Testing.put(:authorizer, BurstTelemetryAuthorizer)

    :ok =
      :telemetry.attach(
        handler_id,
        @drop_event,
        fn event, measurements, metadata, target ->
          send(target, {:bridge_drop, event, measurements, metadata})
        end,
        parent
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, bridge_pid} = replace_telemetry_bridge(capacity: 1)

    on_exit(fn ->
      _ = replace_telemetry_bridge([])
    end)

    assert :undefined == :ets.whereis(Arbor.Signals.TelemetryBridge.Queue)

    {:ok, activity_handle} =
      Signals.subscribe("activity.bus_authorization_burst", fn signal ->
        send(parent, {:bounded_bridge_signal, signal})
        :ok
      end)

    on_exit(fn -> Signals.unsubscribe(activity_handle) end)

    {:ok, ^bridge_id} =
      Telemetry.attach_bridge(
        [[:arbor, :test, :bus_authorization_burst]],
        id: bridge_id,
        category: :telemetry
      )

    on_exit(fn -> Telemetry.detach(bridge_id) end)

    assert {:ok, restricted_handle} =
             Signals.subscribe("security.*", fn _signal -> :ok end,
               principal_id: "human_bounded_bridge"
             )

    on_exit(fn -> Signals.unsubscribe(restricted_handle) end)

    assert_receive {:bridge_drop, @drop_event, %{count: 1}, %{reason: :queue_full, capacity: 1}}

    assert Process.whereis(TelemetryBridge) == bridge_pid
    assert Process.alive?(bridge_pid)

    assert_receive {:bounded_bridge_signal, %Signal{data: %{sequence: 1}}}, 1_000
    refute_receive {:bounded_bridge_signal, %Signal{data: %{sequence: 2}}}, 100

    assert Process.whereis(TelemetryBridge) == bridge_pid
    assert Process.alive?(bridge_pid)
  end

  test "security regression: state inspection and replacement cannot forge bridge emission" do
    bridge_id = "arbor-signals-private-bridge-#{System.unique_integer([:positive])}"
    Arbor.Signals.Config.Testing.isolate_namespace()
    Arbor.Signals.Config.Testing.put(:restricted_topics, [])
    parent = self()

    {:ok, activity_handle} =
      Signals.subscribe("activity.*", fn signal ->
        send(parent, {:forged_bridge_signal, signal})
        :ok
      end)

    on_exit(fn -> Signals.unsubscribe(activity_handle) end)

    bridge_pid = Process.whereis(TelemetryBridge)
    assert is_pid(bridge_pid)
    assert :undefined == :ets.whereis(Arbor.Signals.TelemetryBridge.Queue)

    original_state = :sys.get_state(bridge_pid)

    assert Map.keys(original_state) |> Enum.sort() ==
             [:authenticated_calls, :bridge_custody]

    assert Enum.all?(Map.values(original_state), &(not is_pid(&1) and not is_binary(&1)))

    for custody <- Map.values(original_state) do
      assert :ets.info(custody, :owner) == bridge_pid
      assert :ets.info(custody, :protection) == :private
      assert_raise ArgumentError, fn -> :ets.tab2list(custody) end
    end

    payload = {:activity, :forged_bridge_event, %{forged: true}, [], false}
    send(bridge_pid, {:arbor_signals_telemetry_bridge_emit, make_ref(), payload})
    send(bridge_pid, {make_ref(), :emit, payload})
    GenServer.cast(bridge_pid, {:enqueue, payload})

    assert {:error, :unauthorized} = GenServer.call(bridge_pid, {:enqueue, payload})

    assert {:error, :unauthorized} =
             TelemetryBridge.enqueue(:activity, :forged_bridge_event, %{forged: true}, [], false)

    refute_receive {:forged_bridge_signal, %Signal{}}, 100
    assert Process.alive?(bridge_pid)

    Arbor.Signals.Config.Testing.put(:restricted_topics, [:security])
    Arbor.Signals.Config.Testing.put(:authorizer, TelemetryEmittingAuthorizer)

    {:ok, ^bridge_id} =
      Telemetry.attach_bridge(
        [[:arbor, :test, :bus_authorization]],
        id: bridge_id,
        category: :telemetry
      )

    on_exit(fn -> Telemetry.detach(bridge_id) end)

    forged_secret = :crypto.strong_rand_bytes(32)

    forged_emitter =
      spawn(fn ->
        receive do
          {^forged_secret, :emit, redirected_payload} ->
            send(parent, {:redirected_bridge_payload, redirected_payload})
        end
      end)

    forged_custody = :ets.new(__MODULE__, [:set, :private])
    true = :ets.insert(forged_custody, {:bridge, forged_emitter, forged_secret, 1_024, 0})
    true = :ets.give_away(forged_custody, bridge_pid, :forged_bridge_custody)
    assert_eventually(fn -> :ets.info(forged_custody, :owner) == bridge_pid end)

    on_exit(fn ->
      if Process.alive?(bridge_pid) do
        :sys.replace_state(bridge_pid, fn _state -> original_state end)
      end

      if Process.alive?(forged_emitter), do: Process.exit(forged_emitter, :kill)
      if :ets.info(forged_custody, :owner) == self(), do: :ets.delete(forged_custody)
    end)

    :sys.replace_state(bridge_pid, fn state ->
      %{state | bridge_custody: forged_custody}
    end)

    assert {:ok, rejected_redirect_handle} =
             Signals.subscribe("security.*", fn _signal -> :ok end,
               principal_id: "human_forged_bridge_custody"
             )

    on_exit(fn -> Signals.unsubscribe(rejected_redirect_handle) end)

    refute_receive {:redirected_bridge_payload, _payload}, 100
    refute_receive {:forged_bridge_signal, %Signal{}}, 100
    assert Process.alive?(bridge_pid)

    :sys.replace_state(bridge_pid, fn _state ->
      if :ets.info(forged_custody, :owner) == self(), do: :ets.delete(forged_custody)
      original_state
    end)

    assert {:ok, legitimate_handle} =
             Signals.subscribe("security.*", fn _signal -> :ok end,
               principal_id: "human_legitimate_bridge_custody"
             )

    on_exit(fn -> Signals.unsubscribe(legitimate_handle) end)

    assert_receive {:forged_bridge_signal, %Signal{data: %{authorized: true}}}, 1_000
    refute_receive {:redirected_bridge_payload, _payload}, 100
    assert Process.alive?(bridge_pid)
  end

  defp replace_telemetry_bridge(opts) do
    supervisor = Arbor.Signals.Supervisor

    case Supervisor.terminate_child(supervisor, TelemetryBridge) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end

    case Supervisor.delete_child(supervisor, TelemetryBridge) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end

    Supervisor.start_child(supervisor, {TelemetryBridge, opts})
  end

  defp assert_eventually(assertion, attempts \\ 200)
  defp assert_eventually(_assertion, 0), do: flunk("condition did not become true")

  defp assert_eventually(assertion, attempts) do
    if assertion.() do
      :ok
    else
      Process.sleep(5)
      assert_eventually(assertion, attempts - 1)
    end
  end
end
