defmodule Arbor.Persistence.EventStreamAbsenceConformanceTest do
  use ExUnit.Case, async: false

  alias Arbor.Persistence
  alias Arbor.Persistence.Event
  alias Arbor.Persistence.EventLog.Agent, as: AgentEventLog
  alias Arbor.Persistence.EventLog.ETS

  defmodule UnsupportedBackend do
    @moduledoc false
  end

  defmodule MalformedBackend do
    @moduledoc false
    def stream_absent(_stream_id, _opts), do: {:ok, :deleted}
  end

  defmodule BareBooleanBackend do
    @moduledoc false
    def stream_absent(_stream_id, _opts), do: true
  end

  defmodule NilBackend do
    @moduledoc false
    def stream_absent(_stream_id, _opts), do: nil
  end

  defmodule RaisingBackend do
    @moduledoc false
    def stream_absent(_stream_id, _opts), do: raise("simulated absence backend failure")
  end

  defmodule BlockingBackend do
    @moduledoc false
    def stream_absent(_stream_id, _opts), do: Process.sleep(:infinity)
  end

  setup do
    agent_name = :"event_stream_absence_agent_#{System.unique_integer([:positive])}"
    ets_name = :"event_stream_absence_ets_#{System.unique_integer([:positive])}"

    start_supervised!({AgentEventLog, name: agent_name})
    start_supervised!({ETS, name: ets_name, max_age_ms: :infinity, trim_interval_ms: :disabled})

    {:ok, agent_name: agent_name, ets_name: ets_name}
  end

  for {label, backend, context_key} <- [
        {:agent, AgentEventLog, :agent_name},
        {:ets, ETS, :ets_name}
      ] do
    test "conformance: #{label} proves complete absence false then true without mutation",
         context do
      backend = unquote(backend)
      name = Map.fetch!(context, unquote(context_key))
      target = "absence-target-#{unquote(label)}"
      survivor = "absence-survivor-#{unquote(label)}"

      target_events = [
        Event.new(target, "target.created", %{"ordinal" => 1}),
        Event.new(target, "target.updated", %{"ordinal" => 2})
      ]

      survivor_event = Event.new(survivor, "survivor.created", %{"ordinal" => 1})

      assert {:ok, [_first, _second]} = Persistence.append(name, backend, target, target_events)
      assert {:ok, [surviving]} = Persistence.append(name, backend, survivor, survivor_event)

      assert {:ok, false} = Persistence.event_stream_absent?(name, backend, target)
      assert {:ok, false} =
               Persistence.check_complete_event_stream_absent_using_backend(
                 name,
                 backend,
                 target,
                 []
               )

      assert :ok = Persistence.purge_stream(name, backend, target)

      assert {:ok, true} = Persistence.event_stream_absent?(name, backend, target)
      assert {:ok, true} =
               Persistence.check_complete_event_stream_absent_using_backend(
                 name,
                 backend,
                 target,
                 []
               )

      # Repeated absence checks are read-only.
      assert {:ok, true} = Persistence.event_stream_absent?(name, backend, target)
      assert {:ok, true} = Persistence.event_stream_absent?(name, backend, target)

      assert {:ok, [remaining]} = Persistence.read_all(name, backend)
      assert remaining.id == surviving.id
      assert remaining.global_position == surviving.global_position
      assert {:ok, false} = Persistence.event_stream_absent?(name, backend, survivor)

      next = Event.new(survivor, "survivor.updated", %{"ordinal" => 2})

      assert {:ok, [persisted_next]} =
               Persistence.append(name, backend, survivor, next, expected_version: 1)

      assert persisted_next.event_number == 2
      assert persisted_next.global_position > surviving.global_position
    end

    test "conformance: #{label} owner serializes absence-before-append so true cannot interleave",
         context do
      backend = unquote(backend)
      name = Map.fetch!(context, unquote(context_key))
      stream_id = "absence-before-append-#{unquote(label)}"

      assert {:ok, true} = Persistence.event_stream_absent?(name, backend, stream_id)

      # Freeze the owner so mailbox order is deterministic at the real authority
      # (ETS GenServer / Agent process), then enqueue absence before append.
      :sys.suspend(name)

      absence_task =
        Task.async(fn ->
          Persistence.event_stream_absent?(name, backend, stream_id, absence_timeout_ms: 5_000)
        end)

      wait_until_message_queue_len(name, 1)

      append_task =
        Task.async(fn ->
          event = Event.new(stream_id, "race.after_absence", %{"token" => 1})
          Persistence.append(name, backend, stream_id, event, append_timeout_ms: 5_000)
        end)

      wait_until_message_queue_len(name, 2)
      :sys.resume(name)

      assert {:ok, true} = Task.await(absence_task, 10_000),
             "absence queued first on an empty stream must linearize before append"

      assert {:ok, [_persisted]} = Task.await(append_task, 10_000)
      assert {:ok, false} = Persistence.event_stream_absent?(name, backend, stream_id)
      assert {:ok, [_event]} = Persistence.read_stream(name, backend, stream_id)
    end

    test "conformance: #{label} owner serializes append-before-absence so retained state is false",
         context do
      backend = unquote(backend)
      name = Map.fetch!(context, unquote(context_key))
      stream_id = "append-before-absence-#{unquote(label)}"

      :sys.suspend(name)

      append_task =
        Task.async(fn ->
          event = Event.new(stream_id, "race.before_absence", %{"token" => 1})
          Persistence.append(name, backend, stream_id, event, append_timeout_ms: 5_000)
        end)

      wait_until_message_queue_len(name, 1)

      absence_task =
        Task.async(fn ->
          Persistence.event_stream_absent?(name, backend, stream_id, absence_timeout_ms: 5_000)
        end)

      wait_until_message_queue_len(name, 2)
      :sys.resume(name)

      assert {:ok, [_persisted]} = Task.await(append_task, 10_000)

      assert {:ok, false} = Task.await(absence_task, 10_000),
             "absence queued after append must observe retained target surfaces"
    end
  end

  test "conformance: ETS absence covers subscribers, versions, and identity metadata", %{
    ets_name: name
  } do
    stream_id = "absence-ets-surfaces"
    event = Event.new(stream_id, "surface.created", %{})
    assert {:ok, [_]} = Persistence.append(name, ETS, stream_id, event)
    assert {:ok, ref} = ETS.subscribe(stream_id, self(), name: name)

    assert {:ok, false} = Persistence.event_stream_absent?(name, ETS, stream_id)

    before = :sys.get_state(name)
    assert {:ok, false} = Persistence.event_stream_absent?(name, ETS, stream_id)
    after_check = :sys.get_state(name)

    assert after_check.purged_event_count == before.purged_event_count
    assert Map.has_key?(after_check.subscribers, stream_id)
    assert Map.has_key?(after_check.stream_versions, stream_id)
    assert Map.has_key?(after_check.monitors, ref)

    assert :ok = Persistence.purge_stream(name, ETS, stream_id)
    assert {:ok, true} = Persistence.event_stream_absent?(name, ETS, stream_id)

    state = :sys.get_state(name)
    refute Map.has_key?(state.stream_versions, stream_id)
    refute Map.has_key?(state.head_inserted_mono, stream_id)
    refute Map.has_key?(state.subscribers, stream_id)
    refute Map.has_key?(state.monitors, ref)
  end

  test "conformance: incomplete ETS identity history never returns true", %{ets_name: name} do
    stream_id = "absence-incomplete-identity"

    :sys.replace_state(name, fn state ->
      %{state | identity_history: {:unavailable, :test_incomplete}}
    end)

    assert {:error, :absence_verification_failed} =
             Persistence.event_stream_absent?(name, ETS, stream_id)
  end

  test "conformance: Agent malformed state returns closed uncertainty without crashing owner", %{
    agent_name: name
  } do
    stream_id = "absence-agent-malformed"
    event = Event.new(stream_id, "before.corrupt", %{})
    assert {:ok, [_]} = Persistence.append(name, AgentEventLog, stream_id, event)
    assert :ok = Persistence.purge_stream(name, AgentEventLog, stream_id)

    owner = Process.whereis(name)
    assert is_pid(owner)
    owner_ref = Process.monitor(owner)

    # Empty target maps so verification reaches global enumeration, then corrupt
    # global so the in-Agent callback raises. Caller-side rescue is too late.
    :sys.replace_state(name, fn state ->
      %{
        state
        | streams: %{},
          stream_index: %{},
          versions: %{},
          head_inserted_mono: %{},
          global: :not_enumerable_global,
          event_index: %{}
      }
    end)

    before = :sys.get_state(name)

    assert {:error, {:absence_indeterminate, ^stream_id}} =
             Persistence.event_stream_absent?(name, AgentEventLog, stream_id)

    assert Process.alive?(owner)
    refute_receive {:DOWN, ^owner_ref, :process, ^owner, _reason}, 100

    after_state = :sys.get_state(name)
    assert after_state.global == :not_enumerable_global
    assert after_state.streams == before.streams
    assert after_state.versions == before.versions
    assert after_state.event_index == before.event_index
    assert after_state.global_position == before.global_position

    # Owner remains responsive after the fail-closed reply.
    assert {:ok, 0} = Persistence.stream_version(name, AgentEventLog, stream_id)
  end

  test "conformance: closed pre-dispatch failures and post-dispatch uncertainty", %{
    agent_name: name
  } do
    stream_id = "absence-closed-envelope"

    assert {:error, :absence_not_supported} =
             Persistence.event_stream_absent?(name, UnsupportedBackend, stream_id)

    assert {:error, :invalid_stream_id} =
             Persistence.event_stream_absent?(name, AgentEventLog, "")

    assert {:error, :invalid_precondition} =
             Persistence.event_stream_absent?(name, AgentEventLog, stream_id, unknown: true)

    assert {:error, :invalid_precondition} =
             Persistence.event_stream_absent?(name, AgentEventLog, stream_id,
               absence_timeout_ms: 0
             )

    assert {:error, :invalid_precondition} =
             Persistence.event_stream_absent?("not-an-atom", AgentEventLog, stream_id)

    assert {:error, :backend_unavailable} =
             Persistence.event_stream_absent?(
               :missing_event_log_owner_for_absence,
               AgentEventLog,
               stream_id
             )

    for backend <- [MalformedBackend, BareBooleanBackend, NilBackend, RaisingBackend] do
      assert {:error, {:absence_indeterminate, ^stream_id}} =
               Persistence.event_stream_absent?(name, backend, stream_id)
    end

    assert {:error, {:absence_indeterminate, ^stream_id}} =
             Persistence.event_stream_absent?(name, BlockingBackend, stream_id,
               absence_timeout_ms: 100
             )
  end

  # Require exact mailbox depth so the second wait cannot accept the first queued call.
  defp wait_until_message_queue_len(name, expected_len, attempts \\ 100)

  defp wait_until_message_queue_len(_name, expected_len, 0),
    do: flunk("timed out waiting for owner mailbox length #{expected_len}")

  defp wait_until_message_queue_len(name, expected_len, attempts)
       when is_integer(expected_len) and expected_len > 0 do
    case Process.whereis(name) do
      pid when is_pid(pid) ->
        case Process.info(pid, :message_queue_len) do
          {:message_queue_len, ^expected_len} ->
            :ok

          {:message_queue_len, _other} ->
            Process.sleep(5)
            wait_until_message_queue_len(name, expected_len, attempts - 1)

          _missing_info ->
            Process.sleep(5)
            wait_until_message_queue_len(name, expected_len, attempts - 1)
        end

      _missing ->
        flunk("owner process missing while waiting for mailbox length #{expected_len}")
    end
  end
end
