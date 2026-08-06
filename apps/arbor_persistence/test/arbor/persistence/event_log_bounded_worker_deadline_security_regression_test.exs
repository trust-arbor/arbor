defmodule Arbor.Persistence.EventLogBoundedWorkerDeadlineSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Persistence
  alias Arbor.Persistence.EventLog
  alias Arbor.Persistence.EventLog.BoundedWorker

  defmodule DispatchSpyBackend do
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
      send(controller, {:deadline_handoff_backend_started, token, self()})
      :ok
    end
  end

  test "security regression: an expired worker handoff never enters the purge callback" do
    token = DispatchSpyBackend.install(self())
    on_exit(&DispatchSpyBackend.clear/0)

    evidence = expire_between_admission_and_worker_start(token)

    assert evidence.result ==
             {:error, {:purge_indeterminate, "purge-deadline-handoff"}}

    assert evidence.caller_messages == []
    assert evidence.worker_reason == :normal
    assert evidence.coordinator_reason == :normal
    assert evidence.caller_reason == :normal
    refute evidence.callback_started?
    refute evidence.backend_started?
    refute Process.alive?(evidence.worker)
    refute Process.alive?(evidence.coordinator)
    refute Process.alive?(evidence.caller)
  end

  defp expire_between_admission_and_worker_start(token) do
    cleanup_key = {__MODULE__, make_ref()}
    Process.put(cleanup_key, [])

    previous_priority = Process.flag(:priority, :high)
    scheduling_state = :erlang.system_info(:multi_scheduling)
    blocked_here? = scheduling_state == :enabled

    if blocked_here?, do: :erlang.system_flag(:multi_scheduling, :block)

    trace_targets = [
      {BoundedWorker, :run, 2},
      {EventLog, :with_inherited_deadline, 2}
    ]

    Code.ensure_loaded!(BoundedWorker)
    Code.ensure_loaded!(EventLog)
    Enum.each(trace_targets, &:erlang.trace_pattern(&1, true, []))

    try do
      exercise_expired_handoff(cleanup_key, token)
    after
      tracked = Process.get(cleanup_key, [])

      Enum.each(tracked, &safe_resume/1)
      Enum.each(tracked, &safe_untrace/1)

      Enum.each(tracked, fn pid ->
        if Process.alive?(pid), do: Process.exit(pid, :kill)
      end)

      Enum.each(trace_targets, &:erlang.trace_pattern(&1, false, []))
      if blocked_here?, do: :erlang.system_flag(:multi_scheduling, :unblock)
      Process.flag(:priority, previous_priority)
      Process.delete(cleanup_key)
      drain_trace_messages()
    end
  end

  defp exercise_expired_handoff(cleanup_key, token) do
    controller = self()

    caller =
      track_process(
        cleanup_key,
        :erlang.spawn_opt(
          fn ->
            receive do
              {:run_purge, ^token} ->
                result =
                  Persistence.purge_stream(
                    :deadline_handoff_store,
                    DispatchSpyBackend,
                    "purge-deadline-handoff",
                    purge_timeout_ms: 250
                  )

                {:messages, messages} = Process.info(self(), :messages)

                send(
                  controller,
                  {:deadline_handoff_returned, token, self(), result, messages}
                )
            end
          end,
          [{:priority, :low}]
        )
      )

    caller_ref = Process.monitor(caller)

    1 =
      :erlang.trace(caller, true, [
        :call,
        :procs,
        :send,
        :set_on_spawn,
        {:tracer, self()}
      ])

    send(caller, {:run_purge, token})
    deadline_mono = await_run_deadline(caller)

    coordinator = track_process(cleanup_key, await_spawn(caller))
    :erlang.suspend_process(coordinator)
    :erlang.resume_process(coordinator)

    worker = track_process(cleanup_key, await_spawn(coordinator))
    :erlang.suspend_process(coordinator)
    :erlang.suspend_process(worker)

    worker_ref = Process.monitor(worker)
    coordinator_ref = Process.monitor(coordinator)

    :erlang.resume_process(coordinator)
    await_worker_start_send(coordinator, worker)

    :erlang.suspend_process(coordinator)
    :erlang.suspend_process(caller)
    wait_until_expired(deadline_mono)

    :erlang.resume_process(worker)

    worker_reason = await_down(worker_ref, worker)
    callback_started? = callback_started?(worker)
    backend_started? = backend_started?(token, worker)

    :erlang.resume_process(coordinator)
    :erlang.resume_process(caller)

    {result, caller_messages} = await_public_result(token, caller)
    coordinator_reason = await_down(coordinator_ref, coordinator)
    caller_reason = await_down(caller_ref, caller)

    %{
      backend_started?: backend_started?,
      callback_started?: callback_started?,
      caller: caller,
      caller_messages: caller_messages,
      caller_reason: caller_reason,
      coordinator: coordinator,
      coordinator_reason: coordinator_reason,
      result: result,
      worker: worker,
      worker_reason: worker_reason
    }
  end

  defp await_run_deadline(caller) do
    receive do
      {:trace, ^caller, :call, {BoundedWorker, :run, [_fun, deadline_mono]}}
      when is_integer(deadline_mono) ->
        deadline_mono
    after
      1_000 -> flunk("bounded worker deadline trace was not observed")
    end
  end

  defp await_spawn(parent) do
    receive do
      {:trace, ^parent, :spawn, child, _mfa} when is_pid(child) -> child
    after
      1_000 -> flunk("expected child process was not spawned")
    end
  end

  defp await_worker_start_send(coordinator, worker) do
    receive do
      {:trace, ^coordinator, :send, {_private_ref, :start}, ^worker} -> :ok
    after
      1_000 -> flunk("worker start handoff was not observed")
    end
  end

  defp wait_until_expired(deadline_mono) do
    remaining_ms = deadline_mono - System.monotonic_time(:millisecond)

    if remaining_ms >= 0 do
      Process.sleep(remaining_ms + 1)
      wait_until_expired(deadline_mono)
    end
  end

  defp callback_started?(worker) do
    receive do
      {:trace, ^worker, :call, {EventLog, :with_inherited_deadline, _arguments}} -> true
    after
      0 -> false
    end
  end

  defp backend_started?(token, worker) do
    receive do
      {:deadline_handoff_backend_started, ^token, ^worker} -> true
    after
      0 -> false
    end
  end

  defp await_public_result(token, caller) do
    receive do
      {:deadline_handoff_returned, ^token, ^caller, result, messages} -> {result, messages}
    after
      1_000 -> flunk("public purge did not settle after the expired handoff")
    end
  end

  defp await_down(monitor_ref, process) do
    receive do
      {:DOWN, ^monitor_ref, :process, ^process, reason} -> reason
    after
      1_000 -> flunk("owned process did not terminate")
    end
  end

  defp track_process(cleanup_key, pid) do
    Process.put(cleanup_key, [pid | Process.get(cleanup_key, [])])
    pid
  end

  defp safe_resume(pid) do
    if Process.alive?(pid) do
      try do
        :erlang.resume_process(pid)
      catch
        :error, :badarg -> :ok
      end
    end
  end

  defp safe_untrace(pid) do
    try do
      :erlang.trace(pid, false, [:all])
    catch
      :error, :badarg -> :ok
    end
  end

  defp drain_trace_messages do
    receive do
      message
      when is_tuple(message) and tuple_size(message) >= 3 and elem(message, 0) == :trace ->
        drain_trace_messages()
    after
      0 -> :ok
    end
  end
end
