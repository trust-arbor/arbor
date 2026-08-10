defmodule Arbor.Agent.Orchestration.TemplateAuthorityDispatchFenceSecurityRegressionTest do
  # Security regression for Phase 4C C2A: target-bound TaskStore reservations,
  # the operation-owned per-target dispatch fence + synchronous barrier, and
  # fail-closed startup fence seeding from the durable operation store.
  #
  # Exercises the PUBLIC TaskStore/Orchestration API only — never private
  # helpers. Private TaskStore state is inspected solely to prove non-mutation
  # of pre-existing work or to flip a readiness flag for a gate test (it
  # legitimately retains task ids).
  use ExUnit.Case, async: false

  @moduletag :fast

  # Defaults mirrored from TaskStore so seed_store opts stay bounded.
  @default_retry_base_ms 200
  @default_retry_max_ms 5_000

  alias Arbor.Agent.Orchestration
  alias Arbor.Agent.Orchestration.{TaskControlRecoveryMemory, TaskStore}

  # Keeps tasks running so barrier counts observe live work.
  defmodule HangRunner do
    @moduledoc false
    def run(_agent_id, _task, _opts) do
      Process.sleep(60_000)
      {:ok, %{}}
    end
  end

  # A runner that announces its agent_id to the test pid so tests can prove a
  # runner actually started (or, via refute_receive, that admission started none).
  # Runs in full_opts mode so the runner context carries :test_pid.
  defmodule AnnounceRunner do
    @moduledoc false
    def run(agent_id, _task, opts) do
      test_pid = Keyword.get(opts, :test_pid) || self()
      send(test_pid, {:announced_runner_started, agent_id})
      Process.sleep(60_000)
      {:ok, %{}}
    end
  end

  defmodule NoopSecurity do
    @moduledoc false
    def grant(opts) do
      kind = get_in(opts, [:metadata, :kind]) || "k"
      id = "cap_#{kind}_#{System.unique_integer([:positive])}"
      {:ok, %{id: id, resource_uri: opts[:resource], task_id: opts[:task_id]}}
    end

    def revoke(_id), do: :ok
    def revoke_by_task(_task_id), do: {:ok, 0}
  end

  # Records the exact target_agent_id passed to reserve/2 — proves Orchestration
  # threads the dispatch agent_id as the reservation target.
  defmodule RecordingTaskStore do
    @moduledoc false
    def reserve(target_agent_id, _opts) do
      send(self(), {:recorded_reserve_target, target_agent_id})
      {:ok, %{task_id: "task_rec_1", reservation_token: "tok_rec"}}
    end

    def commit_recovery_marker(_task_id, _token, _opts), do: :ok
    def activate(_agent_id, _task, task_id, _token, _opts), do: {:ok, task_id}
    def release(_id, _token, _opts), do: :ok
    def request_reconcile(_id, _opts), do: :ok
  end

  # Configurable facade standing in for the production reconciliation store.
  # list_outstanding/0 runs ONLY inside the supervised worker (never in the
  # TaskStore callback). Modes are selected via :ets at setup.
  defmodule TestFenceFacade do
    @moduledoc false
    @table __MODULE__

    def reset! do
      if :ets.whereis(@table) != :undefined, do: :ets.delete(@table)
      :ets.new(@table, [:named_table, :public, :set])
      :ets.insert(@table, {:mode, :immediate})
      :ets.insert(@table, {:result, {:ok, []}})
      :ets.insert(@table, {:worker_pid, nil})
      :ok
    end

    def set_immediate(result) do
      :ets.insert(@table, {:mode, :immediate})
      :ets.insert(@table, {:result, result})
      :ok
    end

    def set_blocking(result) do
      :ets.insert(@table, {:mode, :blocking})
      :ets.insert(@table, {:result, result})
      :ok
    end

    def worker_pid do
      case :ets.lookup(@table, :worker_pid) do
        [{:worker_pid, pid}] when is_pid(pid) -> pid
        _ -> nil
      end
    end

    def release do
      if pid = worker_pid(), do: send(pid, :release)
      :ok
    end

    def list_outstanding do
      :ets.insert(@table, {:worker_pid, self()})

      case :ets.lookup(@table, :mode) do
        [{:mode, :blocking}] ->
          receive do
            :release -> fetch_result()
          after
            30_000 -> {:error, :seed_timeout}
          end

        _ ->
          fetch_result()
      end
    end

    defp fetch_result do
      case :ets.lookup(@table, :result) do
        [{:result, result}] -> result
        _ -> {:ok, []}
      end
    end
  end

  setup do
    TaskControlRecoveryMemory.ensure!()
    TaskControlRecoveryMemory.reset!()
    TestFenceFacade.reset!()
    supervisor = start_supervised!({Task.Supervisor, name: unique(:sup)})
    %{supervisor: supervisor}
  end

  test "security regression: reservation admitted before install is reported by the barrier and cannot activate after install",
       %{supervisor: supervisor} do
    store = ready_store(supervisor)

    assert {:ok, %{task_id: task_id, reservation_token: token}} =
             TaskStore.reserve("agent_a", name: store)

    # Marker so activation is eligible when the fence is absent.
    assert :ok = TaskStore.commit_recovery_marker(task_id, token, name: store)

    # No fence yet: the barrier reports the reserved work as bounded integer counts.
    assert {:ok, %{active_count: active0, reserved_count: reserved0}} =
             TaskStore.install_target_fence("agent_a", "op_1", name: store)

    assert active0 == 0
    assert reserved0 >= 1

    # Activation for the fenced target is now closed; the reservation survives
    # (not consumed/retargeted) and can still activate after the fence is removed.
    assert {:error, :target_fenced} =
             TaskStore.activate("agent_a", "work", task_id, token, name: store)

    assert :ok = TaskStore.remove_target_fence("agent_a", "op_1", name: store)

    assert {:ok, ^task_id} =
             TaskStore.activate("agent_a", "work", task_id, token, name: store)
  end

  test "security regression: reserve and direct dispatch after install are rejected for the fenced target while another target admits",
       %{supervisor: supervisor} do
    store = ready_store(supervisor)

    assert {:ok, %{active_count: 0, reserved_count: 0}} =
             TaskStore.install_target_fence("agent_a", "op_1", name: store)

    # Reserve closed for the fenced target; open for an unrelated target.
    assert {:error, :target_fenced} = TaskStore.reserve("agent_a", name: store)
    assert {:ok, %{task_id: _b, reservation_token: _}} = TaskStore.reserve("agent_b", name: store)

    # Direct dispatch closed for the fenced target (AnnounceRunner proves no
    # runner started); open for an unrelated target.
    assert {:error, :target_fenced} =
             TaskStore.dispatch("agent_a", "work",
               name: store,
               runner: AnnounceRunner,
               test_pid: self()
             )

    refute_receive {:announced_runner_started, _}, 50

    assert {:ok, _other} =
             TaskStore.dispatch("agent_b", "work",
               name: store,
               runner: AnnounceRunner,
               test_pid: self()
             )

    assert_receive {:announced_runner_started, "agent_b"}
  end

  test "security regression: direct dispatch validates the target before any fence lookup and a malformed target fails closed with no runner",
       %{supervisor: supervisor} do
    store = ready_store(supervisor)

    # A malformed target is rejected upfront with the bounded error and starts
    # no runner, regardless of readiness.
    assert {:error, :invalid_target_agent_id} =
             TaskStore.dispatch("not-a-valid-agent-id", "work",
               name: store,
               runner: AnnounceRunner,
               test_pid: self()
             )

    refute_receive {:announced_runner_started, _}, 50

    # A valid unfenced target still dispatches normally.
    assert {:ok, _} =
             TaskStore.dispatch("agent_b", "work",
               name: store,
               runner: AnnounceRunner,
               test_pid: self()
             )

    assert_receive {:announced_runner_started, "agent_b"}
  end

  test "security regression: activation with a different target than the reservation fails closed even when no fence exists",
       %{supervisor: supervisor} do
    store = ready_store(supervisor)

    assert {:ok, %{task_id: task_id, reservation_token: token}} =
             TaskStore.reserve("agent_a", name: store)

    assert :ok = TaskStore.commit_recovery_marker(task_id, token, name: store)

    # Mismatched target is rejected; the reservation is NOT consumed.
    assert {:error, :reservation_target_mismatch} =
             TaskStore.activate("agent_b", "work", task_id, token, name: store)

    # The original target can still activate, proving the reservation survived.
    assert {:ok, ^task_id} =
             TaskStore.activate("agent_a", "work", task_id, token, name: store)
  end

  test "security regression: a legacy reservation with a missing target_agent_id fails closed on activate without being consumed",
       %{supervisor: supervisor} do
    store = ready_store(supervisor)

    assert {:ok, %{task_id: task_id, reservation_token: token}} =
             TaskStore.reserve("agent_a", name: store)

    assert :ok = TaskStore.commit_recovery_marker(task_id, token, name: store)

    # Strip the target_agent_id field to simulate a legacy reservation that
    # predates target binding (its token and owner remain valid).
    :sys.replace_state(store, fn state ->
      update_in(state, [:reservations, task_id], &Map.delete(&1, :target_agent_id))
    end)

    # Activation fails closed (missing target != agent_id) and does not consume
    # the reservation — it remains in state.
    assert {:error, :reservation_target_mismatch} =
             TaskStore.activate("agent_a", "work", task_id, token, name: store)

    assert Map.has_key?(:sys.get_state(store).reservations, task_id)
  end

  test "security regression: a legacy reservation with an invalid target fails closed even when activation repeats it",
       %{supervisor: supervisor} do
    store = ready_store(supervisor)

    assert {:ok, %{task_id: task_id, reservation_token: token}} =
             TaskStore.reserve("agent_a", name: store)

    assert :ok = TaskStore.commit_recovery_marker(task_id, token, name: store)

    invalid_target = "not-a-valid-agent-id"

    :sys.replace_state(store, fn state ->
      put_in(state, [:reservations, task_id, :target_agent_id], invalid_target)
    end)

    assert {:error, :reservation_target_mismatch} =
             TaskStore.activate(invalid_target, "work", task_id, token, name: store)

    assert Map.has_key?(:sys.get_state(store).reservations, task_id)
  end

  test "security regression: same-operation install/remove is idempotent and a different operation cannot replace or clear the fence",
       %{supervisor: supervisor} do
    store = ready_store(supervisor)

    assert {:ok, first} = TaskStore.install_target_fence("agent_a", "op_1", name: store)
    assert {:ok, second} = TaskStore.install_target_fence("agent_a", "op_1", name: store)
    assert first == second

    assert true == TaskStore.target_fenced?("agent_a", name: store)
    assert :ok = TaskStore.verify_target_fence("agent_a", "op_1", name: store)

    # A different operation cannot replace, verify, or remove the owner.
    assert {:error, :target_fenced} =
             TaskStore.install_target_fence("agent_a", "op_2", name: store)

    assert {:error, :not_owner} = TaskStore.verify_target_fence("agent_a", "op_2", name: store)

    assert {:error, :target_fenced} =
             TaskStore.remove_target_fence("agent_a", "op_2", name: store)

    # Owner is unchanged.
    assert :ok = TaskStore.verify_target_fence("agent_a", "op_1", name: store)

    # Exact owner removes; a second remove reports the fence is gone.
    assert :ok = TaskStore.remove_target_fence("agent_a", "op_1", name: store)
    assert {:error, :not_found} = TaskStore.remove_target_fence("agent_a", "op_1", name: store)
    assert false == TaskStore.target_fenced?("agent_a", name: store)

    # An unrelated target was never affected.
    assert {:ok, %{active_count: 0, reserved_count: 0}} =
             TaskStore.install_target_fence("agent_b", "op_1", name: store)
  end

  test "security regression: fence probes never report an unfenced target before seed readiness",
       %{supervisor: supervisor} do
    TestFenceFacade.set_blocking({:ok, []})
    store = seed_store(supervisor)

    assert wait_until(fn -> TestFenceFacade.worker_pid() != nil end)

    assert {:error, :fence_not_ready} =
             TaskStore.target_fenced?("agent_probe", name: store)

    assert {:error, :fence_not_ready} =
             TaskStore.verify_target_fence("agent_probe", "op_probe", name: store)

    TestFenceFacade.release()
    assert wait_until(fn -> TaskStore.recovery_ready?(name: store) end)

    assert {:ok, false} = TaskStore.target_fenced?("agent_probe", name: store)

    assert {:error, :invalid_target_agent_id} =
             TaskStore.target_fenced?("not-a-valid-agent-id", name: store)

    assert {:error, :invalid_operation_id} =
             TaskStore.verify_target_fence("agent_probe", "invalid operation", name: store)
  end

  test "security regression: outstanding durable operations seed fences before readiness and block dispatch",
       %{supervisor: supervisor} do
    op = seed_operation("agent_seeded", "op_seed")
    TestFenceFacade.set_blocking({:ok, [op]})

    store = seed_store(supervisor)

    # While the seed worker is blocked, dispatch is closed and not ready.
    assert wait_until(fn -> TestFenceFacade.worker_pid() != nil end)

    refute TaskStore.recovery_ready?(name: store)

    # Recovery replay completes independently of the blocked fence worker; wait
    # for it so the fence gate is the active blocker for the assertions below.
    assert wait_until(fn -> :sys.get_state(store).recovery_ready? == true end, 50)

    assert {:error, :fence_not_ready} = TaskStore.reserve("agent_seeded", name: store)

    assert {:error, :fence_not_ready} =
             TaskStore.dispatch("agent_seeded", "work",
               name: store,
               runner: AnnounceRunner,
               test_pid: self()
             )

    refute_receive {:announced_runner_started, _}, 50

    # Release the seed; readiness completes and fences are installed.
    TestFenceFacade.release()

    assert wait_until(fn -> TaskStore.recovery_ready?(name: store) end)

    # Seeded target is fenced; an unseeded target admits normally.
    assert {:error, :target_fenced} = TaskStore.reserve("agent_seeded", name: store)

    assert {:error, :target_fenced} =
             TaskStore.dispatch("agent_seeded", "work",
               name: store,
               runner: AnnounceRunner,
               test_pid: self()
             )

    assert {:ok, _} =
             TaskStore.dispatch("agent_other", "work",
               name: store,
               runner: AnnounceRunner,
               test_pid: self()
             )

    assert_receive {:announced_runner_started, "agent_other"}
  end

  test "security regression: unavailable or malformed inventory keeps dispatch not ready and starts no runner",
       %{supervisor: supervisor} do
    malformed_cases = [
      {:error, :backend_unavailable},
      {:ok, :not_a_list},
      {:ok, [%{"target_agent_id" => "agent_x"}]},
      {:ok, [%{"target_agent_id" => "not-an-agent", "operation_id" => "op_x"}]},
      {:ok,
       [
         %{"target_agent_id" => "agent_dup", "operation_id" => "op_1"},
         %{"target_agent_id" => "agent_dup", "operation_id" => "op_2"}
       ]}
    ]

    Enum.each(malformed_cases, fn result ->
      # Stop any store from a prior iteration so only one live store reads the
      # shared facade state at a time.
      _ = stop_supervised(:malformed_store)

      TestFenceFacade.reset!()
      TestFenceFacade.set_immediate(result)

      store = seed_store(supervisor, id: :malformed_store)

      # Wait for recovery replay to complete (internal flag) so the fence gate
      # is the only remaining blocker; then the fence map stays empty.
      assert wait_until(fn -> :sys.get_state(store).recovery_ready? == true end, 50)

      refute wait_until(fn -> TaskStore.recovery_ready?(name: store) end, 30)

      assert {:error, :fence_not_ready} = TaskStore.reserve("agent_x", name: store)

      assert {:error, :fence_not_ready} =
               TaskStore.dispatch("agent_x", "work",
                 name: store,
                 runner: AnnounceRunner,
                 test_pid: self()
               )

      refute_receive {:announced_runner_started, _}, 50

      assert :sys.get_state(store).target_fences == %{}
    end)
  end

  test "security regression: the inventory facade runs outside the TaskStore process",
       %{supervisor: supervisor} do
    TestFenceFacade.set_blocking({:ok, []})
    store = seed_store(supervisor)

    assert wait_until(fn -> TestFenceFacade.worker_pid() != nil end)

    facade_pid = TestFenceFacade.worker_pid()
    store_pid = store

    assert is_pid(facade_pid)
    assert Process.alive?(facade_pid)
    assert facade_pid != store_pid

    TestFenceFacade.release()
    assert wait_until(fn -> TaskStore.recovery_ready?(name: store) end)
  end

  test "security regression: no barrier path mutates pre-existing tasks and no barrier reply exposes ids or tokens",
       %{supervisor: supervisor} do
    store = ready_store(supervisor)

    # Two running tasks plus one injected :waiting_approval record for the target.
    {:ok, running1} =
      TaskStore.dispatch("agent_active", "work",
        name: store,
        runner: HangRunner,
        test_pid: self()
      )

    {:ok, running2} =
      TaskStore.dispatch("agent_active", "work",
        name: store,
        runner: HangRunner,
        test_pid: self()
      )

    :sys.replace_state(store, fn state ->
      update_in(state, [:tasks, running2], fn rec -> %{rec | state: :waiting_approval} end)
    end)

    # One target-bound reservation.
    assert {:ok, %{task_id: _reserved, reservation_token: reserved_token}} =
             TaskStore.reserve("agent_active", name: store)

    # The barrier reply carries ONLY bounded integer counts.
    assert {:ok, reply} = TaskStore.install_target_fence("agent_active", "op_a", name: store)
    assert reply == %{active_count: 2, reserved_count: 1}

    rendered = inspect(reply)
    refute rendered =~ "task_"
    refute rendered =~ "tok_"
    refute rendered =~ "cap_"

    # Projections never expose the owning operation_id to a non-owner.
    assert {:error, :not_owner} =
             TaskStore.verify_target_fence("agent_active", "op_other", name: store)

    assert true == TaskStore.target_fenced?("agent_active", name: store)

    # The reservation token never appears in any public reply.
    refute inspect(reply) =~ reserved_token

    # Pre-existing work is untouched: the running task still runs, the injected
    # waiting_approval record is unchanged, and neither was cancelled/killed.
    assert {:ok, %{state: :running}} = TaskStore.status(running1, name: store)

    assert :sys.get_state(store).tasks[running2].state == :waiting_approval
  end

  test "security regression: stale fence-seed completion/failure/timeout messages are harmless",
       %{supervisor: supervisor} do
    TestFenceFacade.set_blocking({:ok, []})
    store = seed_store(supervisor, worker_timeout_ms: 80, retry_base_ms: 5_000)

    assert wait_until(fn -> TestFenceFacade.worker_pid() != nil end)

    seed_ref = :sys.get_state(store).fence_seed.seed_ref

    # Let the real worker timeout clean the attempt to the minimal pending map,
    # then deliver late messages for that exact attempt. These used to raise on
    # a missing :seed_ref field and crash TaskStore.
    assert wait_until(fn -> Map.get(:sys.get_state(store).fence_seed, :status) == :pending end)

    send(store, {:fence_seed_complete, seed_ref, {:ok, []}})
    send(store, {:fence_seed_failed, seed_ref, :stale})
    send(store, {:fence_seed_admit_timeout, seed_ref})
    send(store, {:fence_seed_worker_timeout, seed_ref})
    send(store, {:fence_seed_admitted, seed_ref, spawn(fn -> :ok end)})

    Process.sleep(50)
    assert Process.alive?(store)

    # The stale completion cannot manufacture readiness.
    refute TaskStore.recovery_ready?(name: store)
  end

  test "security regression: worker timeout keeps dispatch not ready and starts no runner",
       %{supervisor: supervisor} do
    TestFenceFacade.set_blocking({:ok, []})
    store = seed_store(supervisor, worker_timeout_ms: 80)

    assert wait_until(fn -> TestFenceFacade.worker_pid() != nil end)

    # The blocked worker is killed by the worker-timeout and retried; readiness
    # never completes because the facade never returns.
    Process.sleep(400)
    refute TaskStore.recovery_ready?(name: store)

    assert {:error, :fence_not_ready} =
             TaskStore.dispatch("agent_x", "work",
               name: store,
               runner: AnnounceRunner,
               test_pid: self()
             )

    refute_receive {:announced_runner_started, _}, 50

    assert :sys.get_state(store).target_fences == %{}
  end

  test "security regression: worker exit is handled without crashing the store and keeps dispatch closed",
       %{supervisor: supervisor} do
    TestFenceFacade.set_blocking({:ok, []})
    store = seed_store(supervisor, retry_base_ms: 5_000)

    assert wait_until(fn -> TestFenceFacade.worker_pid() != nil end)
    # Recovery replay completes independently (it does not touch the fence
    # facade); wait for it so the fence gate is the active blocker.
    assert wait_until(fn -> :sys.get_state(store).recovery_ready? == true end, 50)

    worker = TestFenceFacade.worker_pid()
    Process.exit(worker, :kill)

    # The store survives the worker :DOWN and schedules a retry; within this
    # short window no new seed has completed, so dispatch stays closed.
    Process.sleep(60)
    assert Process.alive?(store)
    refute TaskStore.recovery_ready?(name: store)

    assert {:error, :fence_not_ready} =
             TaskStore.dispatch("agent_x", "work",
               name: store,
               runner: AnnounceRunner,
               test_pid: self()
             )

    refute_receive {:announced_runner_started, _}, 50
  end

  test "security regression: direct dispatch requires recovery readiness; no runner starts while recovery is closed",
       %{supervisor: supervisor} do
    store = ready_store(supervisor)

    # Flip recovery readiness closed (fence stays ready by test default).
    :sys.replace_state(store, fn s -> %{s | recovery_ready?: false} end)

    assert {:error, :recovery_not_ready} =
             TaskStore.dispatch("agent_a", "work",
               name: store,
               runner: AnnounceRunner,
               test_pid: self()
             )

    refute_receive {:announced_runner_started, _}, 50

    # Restore readiness; an unfenced target dispatches normally.
    :sys.replace_state(store, fn s -> %{s | recovery_ready?: true} end)

    assert {:ok, _} =
             TaskStore.dispatch("agent_a", "work",
               name: store,
               runner: AnnounceRunner,
               test_pid: self()
             )

    assert_receive {:announced_runner_started, "agent_a"}
  end

  test "security regression: Orchestration threads the exact dispatch agent_id as the reservation target",
       %{supervisor: supervisor} do
    # The recording fake runs synchronously in the calling (test) process, so
    # send(self(), ...) reaches this test.
    _ =
      Orchestration.dispatch("agent_exact", "work",
        caller_id: "caller_1",
        authorize?: false,
        task_store: RecordingTaskStore,
        security_module: NoopSecurity
      )

    assert_received {:recorded_reserve_target, "agent_exact"}

    # supervisor is started for setup parity but unused by this case.
    _ = supervisor
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp ready_store(supervisor) do
    start_supervised!(
      {TaskStore,
       name: unique(:store),
       task_supervisor: supervisor,
       cleanup_supervisor: supervisor,
       recovery_force_ready: true,
       task_control_recovery_facade: TaskControlRecoveryMemory,
       task_control_security_module: NoopSecurity,
       runner: HangRunner},
      id: unique(:store_id)
    )
  end

  # fence_force_ready: false forces the supervised seed worker to run; the
  # TestFenceFacade stands in for the production reconciliation store.
  defp seed_store(supervisor, opts \\ []) do
    child_id = Keyword.get(opts, :id, unique(:seed_store_id))
    worker_timeout_ms = Keyword.get(opts, :worker_timeout_ms, 30_000)
    retry_base_ms = Keyword.get(opts, :retry_base_ms, @default_retry_base_ms)
    retry_max_ms = Keyword.get(opts, :retry_max_ms, @default_retry_max_ms)

    start_supervised!(
      {TaskStore,
       name: unique(:seed_store),
       task_supervisor: supervisor,
       cleanup_supervisor: supervisor,
       recovery_force_ready: false,
       fence_force_ready: false,
       task_control_recovery_facade: TaskControlRecoveryMemory,
       template_authority_fence_facade: TestFenceFacade,
       fence_seed_admit_timeout_ms: 1_000,
       fence_seed_worker_timeout_ms: worker_timeout_ms,
       recovery_retry_base_ms: retry_base_ms,
       recovery_retry_max_ms: retry_max_ms,
       task_control_security_module: NoopSecurity,
       runner: HangRunner},
      id: child_id
    )
  end

  defp seed_operation(target, operation_id) do
    %{
      "target_agent_id" => target,
      "operation_id" => operation_id
    }
  end

  defp unique(prefix), do: :"#{prefix}_#{System.unique_integer([:positive])}"

  defp wait_until(fun, attempts \\ 50) do
    cond do
      fun.() ->
        true

      attempts <= 0 ->
        false

      true ->
        Process.sleep(20)
        wait_until(fun, attempts - 1)
    end
  end
end
