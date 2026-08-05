defmodule Arbor.Persistence.EventLogPurgeSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Persistence
  alias Arbor.Persistence.{Event, EventLog}
  alias Arbor.Persistence.EventLog.Agent, as: AgentEventLog
  alias Arbor.Persistence.EventLog.BoundedWorker
  alias Arbor.Persistence.EventLog.ETS

  defmodule CommitThenBlockBackend do
    @moduledoc false
    @controller_key {__MODULE__, :controller}

    def install(controller), do: :persistent_term.put(@controller_key, controller)
    def clear, do: :persistent_term.erase(@controller_key)

    def purge_stream(stream_id, opts) do
      :ok = AgentEventLog.purge_stream(stream_id, opts)
      send(:persistent_term.get(@controller_key), {:purge_committed, self()})

      receive do
        :never_released -> :ok
      end
    end
  end

  defmodule BlockThenSideEffectBackend do
    @moduledoc false
    @controller_key {__MODULE__, :controller}

    def install(controller) do
      token = make_ref()
      :persistent_term.put(@controller_key, {controller, token})
      token
    end

    def clear, do: :persistent_term.erase(@controller_key)

    def purge_stream(_stream_id, _opts) do
      {controller, token} = :persistent_term.get(@controller_key)
      send(controller, {:purge_worker_blocked, token, self(), BoundedWorker.active?()})

      receive do
        {:release_purge_worker, ^token} ->
          send(controller, {:post_release_side_effect, token, self()})
          :ok
      end
    end
  end

  defmodule MalformedBackend do
    @moduledoc false
    def purge_stream(_stream_id, _opts), do: {:ok, :deleted}
  end

  defmodule CrashingBackend do
    @moduledoc false
    def purge_stream(_stream_id, _opts), do: raise("simulated purge backend failure")
  end

  defmodule UnsupportedBackend do
    @moduledoc false
  end

  setup do
    agent_name = :"event_log_purge_agent_#{System.unique_integer([:positive])}"
    ets_name = :"event_log_purge_ets_#{System.unique_integer([:positive])}"

    start_supervised!({AgentEventLog, name: agent_name})

    start_supervised!({ETS, name: ets_name, max_age_ms: :infinity, trim_interval_ms: :disabled})

    {:ok, agent_name: agent_name, ets_name: ets_name}
  end

  for {label, backend, context_key} <- [
        {:agent, AgentEventLog, :agent_name},
        {:ets, ETS, :ets_name}
      ] do
    test "security regression: #{label} whole-stream purge proves exact absence and is idempotent",
         context do
      backend = unquote(backend)
      name = Map.fetch!(context, unquote(context_key))
      target = "purge-target-#{unquote(label)}"
      survivor = "purge-survivor-#{unquote(label)}"

      target_events = [
        Event.new(target, "target.created", %{"ordinal" => 1}),
        Event.new(target, "target.updated", %{"ordinal" => 2})
      ]

      survivor_event = Event.new(survivor, "survivor.created", %{"ordinal" => 1})

      assert {:ok, target_operation} = EventLog.build_operation(target, target_events)
      assert {:ok, survivor_operation} = EventLog.build_operation(survivor, [survivor_event])
      assert {:ok, [_first, _second]} = Persistence.append(name, backend, target, target_events)
      assert {:ok, [surviving]} = Persistence.append(name, backend, survivor, survivor_event)

      assert :ok = Persistence.purge_stream(name, backend, target)
      assert {:ok, []} = Persistence.read_stream(name, backend, target)
      assert {:ok, 0} = Persistence.stream_version(name, backend, target)
      refute Persistence.stream_exists?(name, backend, target)

      Enum.each(target_events, fn event ->
        assert {:ok, nil} = Persistence.event_identity(name, backend, target, event.id)
      end)

      assert {:ok, :absent} = Persistence.reconcile_append(name, backend, target_operation)
      assert {:ok, [remaining]} = Persistence.read_all(name, backend)
      assert remaining.id == surviving.id
      assert remaining.global_position == surviving.global_position

      assert :ok = Persistence.purge_stream(name, backend, target)

      next = Event.new(survivor, "survivor.updated", %{"ordinal" => 2})

      assert {:ok, [persisted_next]} =
               Persistence.append(name, backend, survivor, next, expected_version: 1)

      assert persisted_next.event_number == 2
      assert persisted_next.global_position > surviving.global_position

      assert {:ok, {:committed, [reconciled]}} =
               Persistence.reconcile_append(name, backend, survivor_operation)

      assert reconciled.id == surviving.id
    end
  end

  test "security regression: ETS purge removes stream subscriber and identity metadata", %{
    ets_name: name
  } do
    stream_id = "purge-subscribers"
    event = Event.new(stream_id, "subscriber.created", %{})
    assert {:ok, [_]} = Persistence.append(name, ETS, stream_id, event)
    assert {:ok, ref} = ETS.subscribe(stream_id, self(), name: name)

    assert :ok = Persistence.purge_stream(name, ETS, stream_id)

    state = :sys.get_state(name)
    refute Map.has_key?(state.stream_versions, stream_id)
    refute Map.has_key?(state.head_inserted_mono, stream_id)
    refute Map.has_key?(state.subscribers, stream_id)
    refute Map.has_key?(state.monitors, ref)
    assert state.purged_event_count == 1
    assert {:ok, :identity_history_complete} = ETS.identity_history_status(name: name)
  end

  test "security regression: a corrupt target pointer cannot delete another ETS stream", %{
    ets_name: name
  } do
    target = "purge-corrupt-target"
    survivor = "purge-corrupt-survivor"
    target_event = Event.new(target, "target.created", %{})
    survivor_event = Event.new(survivor, "survivor.created", %{})

    assert {:ok, [target_row]} = Persistence.append(name, ETS, target, target_event)
    assert {:ok, [survivor_row]} = Persistence.append(name, ETS, survivor, survivor_event)

    :sys.replace_state(name, fn state ->
      :ets.insert(
        state.stream_table,
        {{target, target_row.event_number}, survivor_row.global_position}
      )

      state
    end)

    assert {:error, {:purge_indeterminate, ^target}} =
             Persistence.purge_stream(name, ETS, target)

    assert {:ok, [surviving]} = Persistence.read_stream(name, ETS, survivor)
    assert surviving.id == survivor_event.id

    assert {:ok, fingerprint} =
             Persistence.event_identity(name, ETS, survivor, survivor_event.id)

    assert is_binary(fingerprint)
  end

  test "security regression: ETS retry converges after a partial cross-table purge", %{
    ets_name: name
  } do
    target = "purge-partial-target"
    survivor = "purge-partial-survivor"
    target_event = Event.new(target, "target.created", %{})
    survivor_event = Event.new(survivor, "survivor.created", %{})

    assert {:ok, target_operation} = EventLog.build_operation(target, [target_event])
    assert {:ok, [target_row]} = Persistence.append(name, ETS, target, target_event)
    assert {:ok, [survivor_row]} = Persistence.append(name, ETS, survivor, survivor_event)

    :sys.replace_state(name, fn state ->
      true = :ets.delete(state.stream_table, {target, target_row.event_number})
      state
    end)

    assert :ok = Persistence.purge_stream(name, ETS, target)
    assert {:ok, []} = Persistence.read_stream(name, ETS, target)
    assert {:ok, nil} = Persistence.event_identity(name, ETS, target, target_event.id)
    assert {:ok, :absent} = Persistence.reconcile_append(name, ETS, target_operation)

    assert {:ok, [surviving]} = Persistence.read_stream(name, ETS, survivor)
    assert surviving.id == survivor_event.id
    assert surviving.global_position == survivor_row.global_position
  end

  test "security regression: timeout after a committed purge is explicit and retry converges", %{
    agent_name: name
  } do
    stream_id = "purge-lost-ack"
    event = Event.new(stream_id, "purge.started", %{})
    assert {:ok, [_]} = Persistence.append(name, AgentEventLog, stream_id, event)

    CommitThenBlockBackend.install(self())
    on_exit(&CommitThenBlockBackend.clear/0)

    assert {:error, {:purge_indeterminate, ^stream_id}} =
             Persistence.purge_stream(name, CommitThenBlockBackend, stream_id,
               purge_timeout_ms: 50
             )

    assert_receive {:purge_committed, worker}
    worker_ref = Process.monitor(worker)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 500
    refute Process.alive?(worker)
    refute_receive {:DOWN, _ref, :process, ^worker, _reason}
    assert {:ok, []} = Persistence.read_stream(name, AgentEventLog, stream_id)
    assert :ok = Persistence.purge_stream(name, AgentEventLog, stream_id)
  end

  test "security regression: caller death terminates the owned purge worker before release", %{
    agent_name: name
  } do
    token = BlockThenSideEffectBackend.install(self())
    on_exit(&BlockThenSideEffectBackend.clear/0)
    parent = self()

    caller =
      spawn(fn ->
        result =
          Persistence.purge_stream(name, BlockThenSideEffectBackend, "purge-owner-death",
            purge_timeout_ms: 5_000
          )

        send(parent, {:purge_caller_returned, self(), result})
      end)

    caller_ref = Process.monitor(caller)

    on_exit(fn ->
      if Process.alive?(caller), do: Process.exit(caller, :kill)
    end)

    assert_receive {:purge_worker_blocked, ^token, worker, true}, 1_000
    worker_ref = Process.monitor(worker)

    on_exit(fn ->
      if Process.alive?(worker), do: Process.exit(worker, :kill)
    end)

    assert {:links, [coordinator]} = Process.info(worker, :links)
    coordinator_ref = Process.monitor(coordinator)

    Process.exit(caller, :kill)

    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}, 500
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 500
    assert_receive {:DOWN, ^coordinator_ref, :process, ^coordinator, _reason}, 500

    send(worker, {:release_purge_worker, token})

    refute_receive {:post_release_side_effect, ^token, ^worker}, 100
    refute_receive {:purge_caller_returned, ^caller, _result}
    refute_receive {:DOWN, _ref, :process, ^caller, _reason}
    refute_receive {:DOWN, _ref, :process, ^worker, _reason}
    refute_receive {:DOWN, _ref, :process, ^coordinator, _reason}
  end

  test "security regression: coordinator death terminates its worker without killing the caller",
       %{
         agent_name: name
       } do
    token = BlockThenSideEffectBackend.install(self())
    on_exit(&BlockThenSideEffectBackend.clear/0)
    parent = self()

    caller =
      spawn(fn ->
        result =
          Persistence.purge_stream(name, BlockThenSideEffectBackend, "purge-coordinator-death",
            purge_timeout_ms: 5_000
          )

        send(parent, {:purge_caller_returned, self(), result})
      end)

    caller_ref = Process.monitor(caller)

    on_exit(fn ->
      if Process.alive?(caller), do: Process.exit(caller, :kill)
    end)

    assert_receive {:purge_worker_blocked, ^token, worker, true}, 1_000
    worker_ref = Process.monitor(worker)

    on_exit(fn ->
      if Process.alive?(worker), do: Process.exit(worker, :kill)
    end)

    assert {:links, [coordinator]} = Process.info(worker, :links)
    coordinator_ref = Process.monitor(coordinator)
    Process.exit(coordinator, :kill)

    assert_receive {:DOWN, ^coordinator_ref, :process, ^coordinator, :killed}, 500
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 500

    assert_receive {:purge_caller_returned, ^caller,
                    {:error, {:purge_indeterminate, "purge-coordinator-death"}}},
                   500

    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :normal}, 500

    send(worker, {:release_purge_worker, token})
    refute_receive {:post_release_side_effect, ^token, ^worker}, 100
  end

  test "security regression: unsupported, malformed, and crashing backends fail closed", %{
    agent_name: name
  } do
    stream_id = "purge-fail-closed"

    assert {:error, :purge_not_supported} =
             Persistence.purge_stream(name, UnsupportedBackend, stream_id)

    assert {:error, {:purge_indeterminate, ^stream_id}} =
             Persistence.purge_stream(name, MalformedBackend, stream_id)

    assert {:error, {:purge_indeterminate, ^stream_id}} =
             Persistence.purge_stream(name, CrashingBackend, stream_id)
  end

  test "security regression: stream and purge options are closed before backend dispatch", %{
    agent_name: name
  } do
    assert {:error, :invalid_stream_id} =
             Persistence.purge_stream(name, AgentEventLog, "")

    assert {:error, :invalid_precondition} =
             Persistence.purge_stream(name, AgentEventLog, "closed-options", unknown: true)

    assert {:error, :invalid_precondition} =
             Persistence.purge_stream(
               name,
               AgentEventLog,
               "duplicate-options",
               purge_timeout_ms: 10,
               purge_timeout_ms: 20
             )

    assert {:error, :invalid_precondition} =
             Persistence.purge_stream(name, AgentEventLog, "invalid-timeout", purge_timeout_ms: 0)
  end
end
