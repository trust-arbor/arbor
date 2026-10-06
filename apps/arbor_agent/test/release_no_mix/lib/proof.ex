defmodule Arbor.Agent.ReleaseGate.Proof do
  alias Arbor.Agent.Orchestration.TaskStore
  alias Arbor.Agent.RuntimeAdmission.GuardedRestore
  alias Arbor.Agent.RuntimeAdmission.Supervisor, as: RuntimeSupervisor

  def run do
    false = Code.ensure_loaded?(Mix)
    {:error, :bad_name} = :code.lib_dir(:mix)
    # Operator-controlled environment is never build authority.
    System.put_env("MIX_ENV", "test")
    Application.put_env(:mix, :env, :test)
    Application.put_env(:arbor_agent, :env, :test)
    Application.put_env(:arbor_agent, :test_build, true)
    Process.flag(:trap_exit, true)

    checks = [
      {"production TaskStore starts and force-ready cannot bypass missing durable authority",
       &task_store/0},
      {"production guarded restore refuses its test-only collaborator", &guarded_restore/0},
      {"production fence inventory cannot be substituted", &fence_override/0},
      {"production inventory refuses missing authority despite forged test hooks", &inventory/0},
      {"security regression: production witness observation ignores the test-only hang",
       &observer_delay/0}
    ]

    failures =
      Enum.count(checks, fn {name, check} ->
        try do
          check.()
          IO.puts("PASS: " <> name)
          false
        rescue
          error ->
            IO.puts("FAIL: " <> name <> " " <> Exception.format(:error, error, __STACKTRACE__))
            true
        catch
          kind, reason ->
            IO.puts("FAIL: " <> name <> " " <> inspect({kind, reason}))
            true
        end
      end)

    IO.puts("#{length(checks)} production release checks, #{failures} failures")
    if failures != 0, do: raise("production no-Mix regression failed")
    IO.puts("AGENT_RELEASE_NO_MIX_STRICT_GATES_OK")
  end

  defp task_store do
    {:ok, tasks} = Task.Supervisor.start_link()
    {:ok, owners} = RuntimeSupervisor.start_link(name: :release_gate_owners)

    try do
      {:ok, store} =
        TaskStore.start_link(
          name: :release_gate_store,
          task_supervisor: tasks,
          runtime_admission_supervisor: owners,
          recovery_force_ready: true,
          fence_force_ready: true,
          runtime_admission_force_ready: true
        )

      try do
        false = TaskStore.recovery_ready?(name: store)
        false = TaskStore.runtime_admission_ready?(name: store)
        {:error, _} = TaskStore.reserve("agent_release_gate", name: store)
      after
        GenServer.stop(store)
      end
    after
      Supervisor.stop(owners)
      Supervisor.stop(tasks)
    end
  end

  defp guarded_restore do
    {:error, :invalid_start_opts} =
      GuardedRestore.request("agent_release_gate", "operation_release_gate", task_store: self())
  end

  defp fence_override do
    {:error, {%ArgumentError{message: message}, _}} =
      TaskStore.start_link(
        name: :release_gate_invalid_fence,
        template_authority_fence_facade: __MODULE__
      )

    true = String.contains?(message, "cannot be overridden outside MIX_ENV=test")
  end

  defp inventory do
    {:ok, owners} = RuntimeSupervisor.start_link(name: :release_gate_inventory_owners)

    for key <- [
          :runtime_admission_empty_claim_inventory_on_authority_error,
          :runtime_admission_test_claim_inventory_force_error,
          :runtime_admission_test_claim_inventory_malformed,
          :runtime_admission_test_claim_inventory_hang
        ] do
      Application.put_env(:arbor_agent, key, true)
    end

    ref = make_ref()
    parent = self()

    worker =
      spawn(fn ->
        TaskStore.run_runtime_admission_reconcile_worker(parent, ref, owners, 2_000, 0)
      end)

    send(worker, {:runtime_admission_reconcile_begin, ref})

    try do
      receive do
        {:runtime_admission_reconcile_complete, ^ref,
         {:error, :restore_claim_inventory_unavailable}} ->
          :ok

        {:runtime_admission_reconcile_complete, ^ref, other} ->
          raise("inventory admitted forged hook: #{inspect(other)}")
      after
        1_000 -> raise("production inventory was delayed by a test hook")
      end
    after
      Process.exit(worker, :kill)
      Supervisor.stop(owners)
    end
  end

  defp observer_delay do
    {:ok, registry} = Registry.start_link(keys: :unique, name: Arbor.Agent.ExecutorRegistry)
    {:ok, supervisor} = Task.Supervisor.start_link()

    try do
      # An actual supported ordinary-start observation first proves the worker path.
      observe_within(supervisor)

      Application.put_env(:arbor_agent, :runtime_admission_observe_test_hang, %{timeout_ms: 5_000})

      observe_within(supervisor)
    after
      Application.delete_env(:arbor_agent, :runtime_admission_observe_test_hang)
      Supervisor.stop(supervisor)
      Supervisor.stop(registry)
    end
  end

  defp observe_within(supervisor) do
    ref = make_ref()

    request = %{
      kind: :ordinary_start,
      target: "agent_release_gate_absent",
      intent_id: "release_gate_intent",
      fingerprint: String.duplicate("a", 64)
    }

    began = System.monotonic_time(:millisecond)

    {:ok, worker} =
      Task.Supervisor.start_child(
        supervisor,
        TaskStore,
        :run_runtime_admission_witness_observer,
        [self(), ref, request]
      )

    try do
      receive do
        {:runtime_admission_witness_observed, ^ref,
         %{worker_pid: ^worker, fact: :not_running, branch_pid: nil}} ->
          :ok
      after
        1_000 ->
          raise(
            "test-only hook delayed production observation past 1000 ms (#{System.monotonic_time(:millisecond) - began} ms)"
          )
      end
    after
      Task.Supervisor.terminate_child(supervisor, worker)
    end
  end
end
