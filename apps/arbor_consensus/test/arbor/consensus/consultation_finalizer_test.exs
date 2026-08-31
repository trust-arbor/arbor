defmodule Arbor.Consensus.ConsultationFinalizerTest do
  use ExUnit.Case, async: true

  alias Arbor.Consensus.ConsultationFinalizer

  @moduletag :fast

  defmodule ImmediateFinalizeLog do
    def finalize_run(_run_id, _outcome), do: {:ok, :transitioned}
  end

  defmodule HangFinalizeLog do
    def finalize_run(_run_id, _outcome) do
      Process.sleep(60_000)
      {:ok, :transitioned}
    end
  end

  defmodule BareOkThenValidLog do
    def finalize_run(run_id, _outcome) do
      key = {__MODULE__, run_id}
      n = :persistent_term.get(key, 0) + 1
      :persistent_term.put(key, n)
      if n == 1, do: :ok, else: {:ok, :transitioned}
    end

    def attempts(run_id), do: :persistent_term.get({__MODULE__, run_id}, 0)
  end

  defmodule CountingFinalizeLog do
    def finalize_run(run_id, _outcome) do
      key = {__MODULE__, run_id}
      :persistent_term.put(key, :persistent_term.get(key, 0) + 1)
      {:ok, :transitioned}
    end

    def attempts(run_id), do: :persistent_term.get({__MODULE__, run_id}, 0)
  end

  defmodule MalformedThenValidLog do
    def finalize_run(run_id, _outcome) do
      key = {__MODULE__, run_id}
      n = :persistent_term.get(key, 0) + 1
      :persistent_term.put(key, n)

      case n do
        1 -> {:unexpected, :shape}
        2 -> {:error, {:persistence, :flaky}}
        _ -> {:ok, {:already_terminal, "failed"}}
      end
    end

    def attempts(run_id), do: :persistent_term.get({__MODULE__, run_id}, 0)
  end

  setup do
    name = :"finalizer_sup_#{System.unique_integer([:positive])}"
    pid = start_supervised!({ConsultationFinalizer.Supervisor, name: name})
    %{supervisor: pid}
  end

  test "child_spec is temporary and unique per run" do
    spec = ConsultationFinalizer.child_spec(run_id: "run_spec", deadline_unix_ms: 1)

    assert spec.id == {ConsultationFinalizer, "run_spec"}
    assert spec.restart == :temporary
  end

  test "after normal completion the child exits and is not restarted", %{supervisor: supervisor} do
    run_id = "run_complete_#{System.unique_integer([:positive])}"
    before = DynamicSupervisor.count_children(supervisor)

    {:ok, pid} =
      ConsultationFinalizer.Supervisor.start_finalizer(supervisor,
        run_id: run_id,
        deadline_unix_ms: System.system_time(:millisecond) + 30_000,
        consultation_log: ImmediateFinalizeLog,
        grace_ms: 50,
        persist_timeout_ms: 50
      )

    assert DynamicSupervisor.count_children(supervisor).workers == before.workers + 1
    ref = Process.monitor(pid)
    :ok = ConsultationFinalizer.Supervisor.stop_finalizer(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000

    wait_until(fn -> not Process.alive?(pid) end, 500)
    Process.sleep(80)

    assert DynamicSupervisor.count_children(supervisor).workers == before.workers

    refute Enum.any?(DynamicSupervisor.which_children(supervisor), fn {id, child, _type, _mods} ->
             id == {ConsultationFinalizer, run_id} or child == pid
           end)
  end

  test "after timeout terminalization the child exits and is not restarted", %{
    supervisor: supervisor
  } do
    run_id = "run_timeout_#{System.unique_integer([:positive])}"
    before = DynamicSupervisor.count_children(supervisor)
    deadline = System.system_time(:millisecond)

    {:ok, pid} =
      ConsultationFinalizer.Supervisor.start_finalizer(supervisor,
        run_id: run_id,
        deadline_unix_ms: deadline,
        consultation_log: ImmediateFinalizeLog,
        grace_ms: 80,
        persist_timeout_ms: 40
      )

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000

    Process.sleep(80)

    assert DynamicSupervisor.count_children(supervisor).workers == before.workers

    refute Enum.any?(DynamicSupervisor.which_children(supervisor), fn {id, child, _type, _mods} ->
             id == {ConsultationFinalizer, run_id} or child == pid
           end)
  end

  test "a hung persist attempt is cancelled and the child still exits", %{supervisor: supervisor} do
    run_id = "run_hang_#{System.unique_integer([:positive])}"
    before = DynamicSupervisor.count_children(supervisor)
    started = System.system_time(:millisecond)

    {:ok, pid} =
      ConsultationFinalizer.Supervisor.start_finalizer(supervisor,
        run_id: run_id,
        deadline_unix_ms: started,
        consultation_log: HangFinalizeLog,
        grace_ms: 120,
        persist_timeout_ms: 40
      )

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
    assert System.system_time(:millisecond) - started < 800

    Process.sleep(80)
    assert DynamicSupervisor.count_children(supervisor).workers == before.workers
  end

  test "security regression: a bare :ok finalize response is retried, never accepted as terminal",
       %{supervisor: supervisor} do
    run_id = "run_bare_ok_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      ConsultationFinalizer.Supervisor.start_finalizer(supervisor,
        run_id: run_id,
        deadline_unix_ms: System.system_time(:millisecond),
        consultation_log: BareOkThenValidLog,
        grace_ms: 2_000,
        persist_timeout_ms: 200
      )

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 3_000
    assert BareOkThenValidLog.attempts(run_id) == 2
  end

  test "malformed and persistence-error responses retry until a valid terminal result", %{
    supervisor: supervisor
  } do
    run_id = "run_malformed_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      ConsultationFinalizer.Supervisor.start_finalizer(supervisor,
        run_id: run_id,
        deadline_unix_ms: System.system_time(:millisecond),
        consultation_log: MalformedThenValidLog,
        grace_ms: 3_000,
        persist_timeout_ms: 200
      )

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 4_000
    assert MalformedThenValidLog.attempts(run_id) == 3
  end

  test "an oversized persist timeout is clamped and a hung first attempt dies within the cap", %{
    supervisor: supervisor
  } do
    run_id = "run_persist_cap_#{System.unique_integer([:positive])}"
    started = System.system_time(:millisecond)
    cap = ConsultationFinalizer.max_persist_timeout_ms()

    {:ok, pid} =
      ConsultationFinalizer.Supervisor.start_finalizer(supervisor,
        run_id: run_id,
        deadline_unix_ms: started,
        consultation_log: HangFinalizeLog,
        grace_ms: 0,
        persist_timeout_ms: 60_000
      )

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, cap + 2_000
    elapsed = System.system_time(:millisecond) - started
    assert elapsed < cap + 1_500
    assert elapsed < 20_000
  end

  test "security regression: zero grace still yields exactly one terminalization attempt", %{
    supervisor: supervisor
  } do
    run_id = "run_zero_grace_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      ConsultationFinalizer.Supervisor.start_finalizer(supervisor,
        run_id: run_id,
        deadline_unix_ms: System.system_time(:millisecond) - 50,
        consultation_log: CountingFinalizeLog,
        grace_ms: 0,
        persist_timeout_ms: 200
      )

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    assert CountingFinalizeLog.attempts(run_id) == 1
  end

  defp wait_until(fun, timeout_ms) when is_function(fun, 0) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) > deadline do
        flunk("condition was not met before timeout")
      else
        Process.sleep(10)
        do_wait_until(fun, deadline)
      end
    end
  end
end
