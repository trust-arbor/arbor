defmodule Arbor.Consensus.ConsultationFinalizerPersistenceTest do
  use Arbor.Persistence.DatabaseCase, async: false

  alias Arbor.Consensus.ConsultationFinalizer
  alias Arbor.Consensus.ConsultationLog
  alias Arbor.Consensus.Evaluators.Consult
  alias Arbor.Consensus.TestHelpers.{HungAdvisoryEvaluator, TestAdvisoryEvaluator}
  alias Arbor.Persistence

  @moduletag :database

  defmodule DelayedCompleteLog do
    def new_run_id, do: ConsultationLog.new_run_id()

    def create_bound_run(question, perspectives, opts) do
      result = ConsultationLog.create_bound_run(question, perspectives, opts)
      dest = :persistent_term.get({__MODULE__, :test_pid}, self())

      case result do
        {:ok, id} -> send(dest, {:created, id})
        nil -> send(dest, {:created, nil})
      end

      result
    end

    def complete_run(run_id, results), do: ConsultationLog.complete_run(run_id, results)

    def finalize_run(run_id, {:ok, _} = outcome) do
      Process.sleep(10_000)
      ConsultationLog.finalize_run(run_id, outcome)
    end

    def finalize_run(run_id, outcome) do
      ConsultationLog.finalize_run(run_id, outcome)
    end
  end

  defmodule ExposeThenNotifyLog do
    def new_run_id, do: ConsultationLog.new_run_id()

    def create_bound_run(question, perspectives, opts) do
      result = ConsultationLog.create_bound_run(question, perspectives, opts)
      dest = :persistent_term.get({__MODULE__, :test_pid}, self())

      case result do
        {:ok, id} -> send(dest, {:exposed, id})
        nil -> send(dest, {:exposed, nil})
      end

      result
    end

    def finalize_run(run_id, outcome), do: ConsultationLog.finalize_run(run_id, outcome)
  end

  defmodule PersistErrorThenRealLog do
    def new_run_id, do: ConsultationLog.new_run_id()

    def create_bound_run(question, perspectives, opts) do
      ConsultationLog.create_bound_run(question, perspectives, opts)
    end

    def finalize_run(run_id, outcome) do
      n = next_attempt()

      result =
        if n == 1 do
          Persistence.compare_and_set_eval_run_status(run_id, :running, %{status: "failed"})
        else
          ConsultationLog.finalize_run(run_id, outcome)
        end

      dest = :persistent_term.get({__MODULE__, :test_pid}, self())
      send(dest, {:finalize_attempt, n, result})
      result
    end

    defp next_attempt do
      key = {__MODULE__, :attempts}
      n = :persistent_term.get(key, 0) + 1
      :persistent_term.put(key, n)
      n
    end
  end

  test "security regression: hung completion persist still terminalizes the stored row exactly once" do
    :persistent_term.put({DelayedCompleteLog, :test_pid}, self())
    on_exit(fn -> :persistent_term.erase({DelayedCompleteLog, :test_pid}) end)

    started = System.system_time(:millisecond)
    deadline = started + 400

    assert {:error, {:consultation_completion, :timeout}} =
             Consult.ask_logged(
               TestAdvisoryEvaluator,
               "Completion hang must still terminalize",
               deadline_unix_ms: deadline,
               finalizer_grace_ms: 800,
               persist_timeout_ms: 200,
               consultation_log: DelayedCompleteLog
             )

    assert_received {:created, run_id}
    assert is_binary(run_id)

    wait_until(
      fn ->
        case Persistence.get_eval_run(run_id) do
          {:ok, run} -> run.status in ["completed", "failed"]
          {:error, _} -> false
        end
      end,
      2_000
    )

    assert {:ok, stored} = Persistence.get_eval_run(run_id)
    assert stored.status in ["completed", "failed"]
    assert stored.status != "running"

    assert {:ok, {:already_terminal, _}} =
             Persistence.compare_and_set_eval_run_status(run_id, "running", %{status: "failed"})

    assert {:ok, again} = Persistence.get_eval_run(run_id)
    assert again.status == stored.status
    assert System.system_time(:millisecond) - started < 3_000
  end

  test "security regression: caller killed after the running row is exposed still terminalizes exactly once via the finalizer" do
    :persistent_term.put({ExposeThenNotifyLog, :test_pid}, self())
    on_exit(fn -> :persistent_term.erase({ExposeThenNotifyLog, :test_pid}) end)

    started = System.system_time(:millisecond)
    deadline = started + 400

    caller =
      spawn(fn ->
        Consult.ask_logged(
          HungAdvisoryEvaluator,
          "Caller kill after expose must still terminalize",
          deadline_unix_ms: deadline,
          finalizer_grace_ms: 1_200,
          persist_timeout_ms: 200,
          consultation_log: ExposeThenNotifyLog
        )
      end)

    assert_receive {:exposed, run_id}, 1_000
    assert is_binary(run_id)
    assert {:ok, %{status: "running"}} = Persistence.get_eval_run(run_id)

    Process.exit(caller, :kill)

    wait_until(
      fn ->
        case Persistence.get_eval_run(run_id) do
          {:ok, run} -> run.status in ["completed", "failed"]
          {:error, _} -> false
        end
      end,
      3_000
    )

    assert {:ok, stored} = Persistence.get_eval_run(run_id)
    assert stored.status in ["completed", "failed"]
    assert stored.status != "running"

    assert {:ok, {:already_terminal, _}} =
             Persistence.compare_and_set_eval_run_status(run_id, "running", %{status: "failed"})

    assert {:ok, again} = Persistence.get_eval_run(run_id)
    assert again.status == stored.status
  end

  defmodule NotFoundThenCreateLog do
    def finalize_run(run_id, outcome) do
      result = ConsultationLog.finalize_run(run_id, outcome)
      dest = :persistent_term.get({__MODULE__, :test_pid}, self())
      send(dest, {:finalizer_cas, result})
      result
    end
  end

  test "security regression: finalizer started before the row exists retries not_found until the row appears" do
    :persistent_term.put({NotFoundThenCreateLog, :test_pid}, self())
    on_exit(fn -> :persistent_term.erase({NotFoundThenCreateLog, :test_pid}) end)

    run_id = ConsultationLog.new_run_id()
    started = System.system_time(:millisecond)
    deadline = started + 150

    name = :"finalizer_sup_#{System.unique_integer([:positive])}"
    supervisor = start_supervised!({ConsultationFinalizer.Supervisor, name: name})

    {:ok, pid} =
      ConsultationFinalizer.Supervisor.start_finalizer(supervisor,
        run_id: run_id,
        deadline_unix_ms: deadline,
        consultation_log: NotFoundThenCreateLog,
        grace_ms: 1_500,
        persist_timeout_ms: 150
      )

    ref = Process.monitor(pid)

    assert_receive {:finalizer_cas, {:error, :not_found}}, 2_000
    assert Process.alive?(pid)
    assert {:error, _} = Persistence.get_eval_run(run_id)

    assert {:ok, ^run_id} =
             ConsultationLog.create_bound_run("delayed create after finalizer", [:security],
               run_id: run_id
             )

    wait_until(
      fn ->
        case Persistence.get_eval_run(run_id) do
          {:ok, run} -> run.status in ["completed", "failed"]
          {:error, _} -> false
        end
      end,
      3_000
    )

    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000
    assert {:ok, stored} = Persistence.get_eval_run(run_id)
    assert stored.status in ["completed", "failed"]
    assert stored.status != "running"
  end

  test "security regression: CAS persistence error surfaces as persistence and the finalizer retries" do
    run_id = ConsultationLog.new_run_id()

    assert {:ok, ^run_id} =
             ConsultationLog.create_bound_run("persist error retry", [:security], run_id: run_id)

    assert {:error, {:persistence, :invalid_eval_run_cas}} =
             Persistence.compare_and_set_eval_run_status(run_id, :running, %{status: "failed"})

    assert {:ok, %{status: "running"}} = Persistence.get_eval_run(run_id)

    :persistent_term.put({PersistErrorThenRealLog, :test_pid}, self())
    :persistent_term.put({PersistErrorThenRealLog, :attempts}, 0)

    on_exit(fn ->
      :persistent_term.erase({PersistErrorThenRealLog, :test_pid})
      :persistent_term.erase({PersistErrorThenRealLog, :attempts})
    end)

    name = :"finalizer_sup_#{System.unique_integer([:positive])}"
    supervisor = start_supervised!({ConsultationFinalizer.Supervisor, name: name})
    deadline = System.system_time(:millisecond)

    {:ok, pid} =
      ConsultationFinalizer.Supervisor.start_finalizer(supervisor,
        run_id: run_id,
        deadline_unix_ms: deadline,
        consultation_log: PersistErrorThenRealLog,
        grace_ms: 1_500,
        persist_timeout_ms: 200
      )

    ref = Process.monitor(pid)

    assert_receive {:finalize_attempt, 1, {:error, {:persistence, _}}}, 1_000
    assert Process.alive?(pid)
    assert {:ok, %{status: "running"}} = Persistence.get_eval_run(run_id)

    assert_receive {:finalize_attempt, 2, {:ok, :transitioned}}, 2_000
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000

    assert {:ok, stored} = Persistence.get_eval_run(run_id)
    assert stored.status == "failed"
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
        Process.sleep(20)
        do_wait_until(fun, deadline)
      end
    end
  end
end
