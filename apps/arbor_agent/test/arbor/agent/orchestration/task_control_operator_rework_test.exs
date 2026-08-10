defmodule Arbor.Agent.Orchestration.TaskControlOperatorReworkTest do
  # Shares TaskControlRecoveryMemory ETS with other recovery suites — must not
  # run concurrent with ReservationRecovery / crash-replay tests.
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Agent.Orchestration
  alias Arbor.Agent.Orchestration.{TaskControlLease, TaskControlRecoveryMemory, TaskStore}

  defmodule HangRunner do
    @moduledoc false
    def run(_, _, _), do: Process.sleep(60_000)
  end

  defmodule FlakyReconcileSecurity do
    @moduledoc false
    @table :task_control_operator_rework_sec

    def ensure! do
      case :ets.whereis(@table) do
        :undefined -> _ = :ets.new(@table, [:named_table, :public, :set])
        _ -> :ok
      end

      :ok
    end

    def configure(opts) do
      ensure!()
      :ets.insert(@table, {:config, opts})
      :ets.insert(@table, {:revoke_by_task_calls, 0})
      :ok
    end

    def revoke_by_task(_task_id) do
      ensure!()

      count =
        case :ets.lookup(@table, :revoke_by_task_calls) do
          [{:revoke_by_task_calls, n}] -> n
          _ -> 0
        end

      :ets.insert(@table, {:revoke_by_task_calls, count + 1})

      fail_times =
        case :ets.lookup(@table, :config) do
          [{:config, %{fail_times: n}}] -> n
          _ -> 0
        end

      if count < fail_times do
        {:error, :injected_revoke_failure}
      else
        {:ok, 0}
      end
    end

    def revoke_by_task_calls do
      ensure!()

      case :ets.lookup(@table, :revoke_by_task_calls) do
        [{:revoke_by_task_calls, n}] -> n
        _ -> 0
      end
    end

    def grant(opts) do
      kind = get_in(opts, [:metadata, :kind]) || "k"
      {:ok, %{id: "cap_#{kind}_#{System.unique_integer([:positive])}"}}
    end

    def revoke(_), do: :ok
  end

  setup do
    TaskControlRecoveryMemory.ensure!()
    TaskControlRecoveryMemory.reset!()
    FlakyReconcileSecurity.ensure!()
    FlakyReconcileSecurity.configure(%{fail_times: 0})
    supervisor = start_supervised!({Task.Supervisor, name: unique(:sup)})
    %{supervisor: supervisor}
  end

  test "replay continues until authoritative remainder is empty", %{supervisor: supervisor} do
    # Seed more markers than one batch.
    for i <- 1..3 do
      task_id = "task_replay_#{i}"
      {:ok, marker} = TaskControlLease.marker_new(task_id, DateTime.utc_now())

      assert {:ok, _} =
               TaskControlRecoveryMemory.buffered_store_acknowledged_put(
                 :arbor_agent_task_control_recovery,
                 task_id,
                 marker
               )
    end

    store =
      start_supervised!(
        {TaskStore,
         name: unique(:store),
         task_supervisor: supervisor,
         cleanup_supervisor: supervisor,
         recovery_force_ready: false,
         recovery_replay_batch: 1,
         recovery_retry_base_ms: 20,
         task_control_recovery_facade: TaskControlRecoveryMemory,
         task_control_security_module: FlakyReconcileSecurity,
         runner: HangRunner},
        id: unique(:store_id)
      )

    assert wait_until(fn -> TaskStore.recovery_ready?(name: store) end, 200)

    assert {:ok, keys} =
             TaskControlRecoveryMemory.buffered_store_authoritative_list(
               :arbor_agent_task_control_recovery
             )

    assert keys == []
  end

  test "failed reconcile stays pending and retries without dropping authority", %{
    supervisor: supervisor
  } do
    FlakyReconcileSecurity.configure(%{fail_times: 2})

    store =
      start_supervised!(
        {TaskStore,
         name: unique(:store_r),
         task_supervisor: supervisor,
         cleanup_supervisor: supervisor,
         recovery_force_ready: true,
         recovery_retry_base_ms: 20,
         recovery_max_retries: 8,
         task_control_recovery_facade: TaskControlRecoveryMemory,
         task_control_security_module: FlakyReconcileSecurity,
         runner: HangRunner},
        id: unique(:store_r_id)
      )

    assert {:ok, %{task_id: task_id, reservation_token: token}} =
             TaskStore.reserve("agent_1", name: store)

    assert :ok = TaskStore.commit_recovery_marker(task_id, token, name: store)

    # Trigger reconcile path via release (marker written). First attempt may
    # fail; pending retains authority and retries without restart/TTL.
    _ = TaskStore.release(task_id, token, name: store)

    # Force revoke failure before asserting pending authority.
    assert wait_until(fn -> FlakyReconcileSecurity.revoke_by_task_calls() >= 1 end, 200)

    assert wait_until(
             fn ->
               state = :sys.get_state(store)
               Map.has_key?(Map.get(state, :recovery_pending, %{}), task_id)
             end,
             200
           )

    assert wait_until(fn -> FlakyReconcileSecurity.revoke_by_task_calls() >= 3 end, 200)

    # Eventually succeeds; marker gone; no silent drop of pending before success.
    assert wait_until(
             fn ->
               match?(
                 {:error, :not_found},
                 TaskControlRecoveryMemory.buffered_store_authoritative_get(
                   :arbor_agent_task_control_recovery,
                   task_id
                 )
               )
             end,
             200
           )
  end

  defmodule OnceRevokeSecurity do
    @moduledoc false
    def grant(opts) do
      kind = get_in(opts, [:metadata, :kind]) || "k"
      id = "cap_once_#{kind}_#{System.unique_integer([:positive])}"
      send(self(), {:once_grant, id})
      {:ok, %{id: id}}
    end

    def revoke(id) do
      send(self(), {:once_revoke, id})
      :ok
    end
  end

  defmodule FailActivateStore do
    @moduledoc false
    def reserve(_target_agent_id, _opts) do
      token = TaskControlLease.generate_reservation_token()
      {:ok, %{task_id: "task_once_1", reservation_token: token}}
    end

    def commit_recovery_marker(_task_id, _token, _opts), do: :ok
    def activate(_a, _t, _id, _token, _opts), do: {:error, :injected_activate_failure}
    def release(_id, _token, _opts), do: :ok
    def request_reconcile(_id, _opts), do: :ok
  end

  defmodule CacheOnlyFacade do
    @moduledoc false
    def not_a_buffered_put, do: :ok
  end

  test "activation failure reverse-revokes once" do
    assert {:error, :injected_activate_failure} =
             Orchestration.dispatch("agent_1", "work",
               caller_id: "caller_1",
               authorize?: false,
               security_module: OnceRevokeSecurity,
               task_store: FailActivateStore
             )

    revokes =
      for _ <- 1..6 do
        assert_received {:once_revoke, id}
        id
      end

    assert length(revokes) == 6
    # No second wave of revokes.
    refute_received {:once_revoke, _}
  end

  test "cache-only recovery facade fails closed", %{supervisor: supervisor} do
    store =
      start_supervised!(
        {TaskStore,
         name: unique(:cache_store),
         task_supervisor: supervisor,
         cleanup_supervisor: supervisor,
         recovery_force_ready: true,
         task_control_recovery_facade: CacheOnlyFacade,
         runner: HangRunner},
        id: unique(:cache_store_id)
      )

    assert {:error, :recovery_durability_unavailable} = TaskStore.reserve("agent_1", name: store)
  end

  test "reservation monitor index is O(1) by exact ref", %{supervisor: supervisor} do
    store =
      start_supervised!(
        {TaskStore,
         name: unique(:mon_store),
         task_supervisor: supervisor,
         cleanup_supervisor: supervisor,
         recovery_force_ready: true,
         task_control_recovery_facade: TaskControlRecoveryMemory,
         runner: HangRunner},
        id: unique(:mon_store_id)
      )

    assert {:ok, %{task_id: task_id}} = TaskStore.reserve("agent_1", name: store)
    state = :sys.get_state(store)
    assert map_size(state.reservation_monitor_index) == 1
    [{mon, ^task_id}] = Map.to_list(state.reservation_monitor_index)
    assert is_reference(mon)
  end

  defmodule FlakyListFacade do
    @moduledoc false
    @table :task_control_operator_list_facade

    def ensure! do
      case :ets.whereis(@table) do
        :undefined -> _ = :ets.new(@table, [:named_table, :public, :set])
        _ -> :ok
      end

      :ok
    end

    def reset! do
      ensure!()
      TaskControlRecoveryMemory.ensure!()
      TaskControlRecoveryMemory.reset!()
      :ets.insert(@table, {:list_calls, 0})
      :ets.insert(@table, {:list_phase, :seed_batch})
      :ok
    end

    def allow_success! do
      ensure!()
      :ets.insert(@table, {:list_phase, :success})
      :ok
    end

    def buffered_store_acknowledged_put(name, key, value) do
      TaskControlRecoveryMemory.buffered_store_acknowledged_put(name, key, value)
    end

    def buffered_store_acknowledged_delete(name, key) do
      TaskControlRecoveryMemory.buffered_store_acknowledged_delete(name, key)
    end

    def buffered_store_authoritative_get(name, key) do
      TaskControlRecoveryMemory.buffered_store_authoritative_get(name, key)
    end

    def buffered_store_authoritative_list(name) do
      ensure!()

      calls =
        case :ets.lookup(@table, :list_calls) do
          [{:list_calls, n}] -> n
          _ -> 0
        end

      next = calls + 1
      :ets.insert(@table, {:list_calls, next})

      case :ets.lookup(@table, :list_phase) do
        [{:list_phase, :seed_batch}] ->
          :ets.insert(@table, {:list_phase, :fail_post_batch})
          TaskControlRecoveryMemory.buffered_store_authoritative_list(name)

        [{:list_phase, :fail_post_batch}] ->
          {:error, :injected_list_failure}

        _ ->
          TaskControlRecoveryMemory.buffered_store_authoritative_list(name)
      end
    end
  end

  test "post-batch authoritative list failure leaves recovery not-ready then retries to empty", %{
    supervisor: supervisor
  } do
    FlakyListFacade.reset!()

    task_id = "task_list_fail_1"
    {:ok, marker} = TaskControlLease.marker_new(task_id, DateTime.utc_now())

    assert {:ok, _} =
             TaskControlRecoveryMemory.buffered_store_acknowledged_put(
               :arbor_agent_task_control_recovery,
               task_id,
               marker
             )

    store =
      start_supervised!(
        {TaskStore,
         name: unique(:list_fail_store),
         task_supervisor: supervisor,
         cleanup_supervisor: supervisor,
         recovery_force_ready: false,
         recovery_replay_batch: 8,
         recovery_retry_base_ms: 30,
         task_control_recovery_facade: FlakyListFacade,
         task_control_security_module: FlakyReconcileSecurity,
         runner: HangRunner},
        id: unique(:list_fail_store_id)
      )

    # Wait until at least one post-batch list failure path has run.
    assert wait_until(
             fn ->
               case :ets.lookup(:task_control_operator_list_facade, :list_calls) do
                 [{:list_calls, n}] when n >= 2 -> true
                 _ -> false
               end
             end,
             200
           )

    refute TaskStore.recovery_ready?(name: store)

    FlakyListFacade.allow_success!()

    assert wait_until(fn -> TaskStore.recovery_ready?(name: store) end, 200)
    assert {:ok, %{task_id: _}} = TaskStore.reserve("agent_1", name: store)
  end

  test "stale marker-put completion cannot mutate replacement reservation", %{
    supervisor: supervisor
  } do
    fixed_id = "task_cas_fixed_1"

    store =
      start_supervised!(
        {TaskStore,
         name: unique(:cas_store),
         task_supervisor: supervisor,
         cleanup_supervisor: supervisor,
         recovery_force_ready: true,
         task_control_recovery_facade: TaskControlRecoveryMemory,
         task_id_generator: fn -> fixed_id end,
         runner: HangRunner},
        id: unique(:cas_store_id)
      )

    assert {:ok, %{task_id: ^fixed_id, reservation_token: token_a}} =
             TaskStore.reserve("agent_1", name: store)

    hash_a = TaskControlLease.token_hash(token_a)

    # Drop reservation A without durable marker, then reserve again with same id.
    assert :ok = TaskStore.release(fixed_id, token_a, name: store)

    assert {:ok, %{task_id: ^fixed_id, reservation_token: token_b}} =
             TaskStore.reserve("agent_1", name: store)

    refute token_a == token_b
    hash_b = TaskControlLease.token_hash(token_b)

    op_ref = make_ref()

    :sys.replace_state(store, fn state ->
      op = %{
        op_ref: op_ref,
        kind: :marker_put,
        task_id: fixed_id,
        generation: 0,
        status: :running,
        launcher_pid: nil,
        launcher_mon: nil,
        worker_pid: nil,
        worker_mon: nil,
        admit_timer: nil,
        worker_timer: nil,
        reply_to: nil,
        payload: nil,
        expected_token_hash: hash_a
      }

      state
      |> put_in([:recovery_ops, op_ref], op)
      |> put_in([:recovery_task_index, fixed_id], op_ref)
    end)

    send(store, {:recovery_op_complete, op_ref, {:ok, :marker_put}})
    Process.sleep(30)

    state = :sys.get_state(store)
    reservation = Map.fetch!(state.reservations, fixed_id)
    assert reservation.token_hash == hash_b
    assert reservation.marker_written? == false
  end

  defmodule HangRevokeSecurity do
    @moduledoc false
    def revoke_by_task(_task_id) do
      Process.sleep(60_000)
      {:ok, 0}
    end

    def grant(opts) do
      kind = get_in(opts, [:metadata, :kind]) || "k"
      {:ok, %{id: "cap_hang_#{kind}_#{System.unique_integer([:positive])}"}}
    end

    def revoke(_), do: :ok
  end

  test "one injected recovery failure schedules exactly one retry", %{supervisor: supervisor} do
    # Use worker-timeout path (the pre-fix double-schedule vector): hang revoke,
    # fire worker timeout, assert exactly one retry is scheduled — not two.
    store =
      start_supervised!(
        {TaskStore,
         name: unique(:one_retry_store),
         task_supervisor: supervisor,
         cleanup_supervisor: supervisor,
         recovery_force_ready: true,
         recovery_retry_base_ms: 5_000,
         recovery_worker_timeout_ms: 50,
         recovery_max_retries: 8,
         task_control_recovery_facade: TaskControlRecoveryMemory,
         task_control_security_module: HangRevokeSecurity,
         runner: HangRunner},
        id: unique(:one_retry_store_id)
      )

    test_pid = self()

    # Owner process must call reserve/release (token is owner-bound).
    owner =
      spawn(fn ->
        {:ok, %{task_id: task_id, reservation_token: token}} =
          TaskStore.reserve("agent_1", name: store)

        :ok = TaskStore.commit_recovery_marker(task_id, token, name: store)
        send(test_pid, {:reserved, task_id})

        receive do
          :do_release ->
            result = TaskStore.release(task_id, token, name: store)
            send(test_pid, {:release_done, result})
        end
      end)

    assert_receive {:reserved, task_id}, 2_000
    send(owner, :do_release)

    assert wait_until(
             fn ->
               state = :sys.get_state(store)
               pending = Map.get(Map.get(state, :recovery_pending, %{}), task_id)

               is_map(pending) and pending.retry_count == 1 and is_reference(pending.retry_timer)
             end,
             200
           )

    # Hold long enough that a double-schedule from maybe_retry_replay would bump again.
    Process.sleep(80)
    state = :sys.get_state(store)
    pending = Map.fetch!(state.recovery_pending, task_id)
    assert pending.retry_count == 1
    assert is_reference(pending.retry_timer)

    assert_receive {:release_done, {:error, :worker_timeout}}, 2_000
  end

  test "production-environment selector injection is rejected via compile gate" do
    # Pure compile-gate truth table only — no Application env mutation and no
    # dispatch through the global TaskStore (avoids races with other suites).
    # Production beams compile Mix.env() != :test so Application.put_env cannot
    # enable per-call executable selectors.
    assert Orchestration.orchestration_test_doubles_allowed?(false, true) == false
    assert Orchestration.orchestration_test_doubles_allowed?(false, false) == false
    assert Orchestration.orchestration_test_doubles_allowed?(true, true) == true
    assert Orchestration.orchestration_test_doubles_allowed?(true, false) == false
  end

  test "fixed task_id generation rejects ids in recovery and retirement indexes", %{
    supervisor: supervisor
  } do
    occupied_id = "task_occupied_fixed_1"

    store =
      start_supervised!(
        {TaskStore,
         name: unique(:id_excl_store),
         task_supervisor: supervisor,
         cleanup_supervisor: supervisor,
         recovery_force_ready: true,
         task_control_recovery_facade: TaskControlRecoveryMemory,
         task_id_generator: fn -> occupied_id end,
         runner: HangRunner},
        id: unique(:id_excl_store_id)
      )

    # recovery_pending occupies the id — generator must not mint it.
    :sys.replace_state(store, fn state ->
      put_in(state.recovery_pending[occupied_id], %{
        task_id: occupied_id,
        reason: :test_hold,
        marker_written?: true,
        inserted_at: DateTime.utc_now(),
        retry_count: 0,
        retry_timer: nil
      })
    end)

    assert {:error, :task_id_already_exists} = TaskStore.reserve("agent_1", name: store)

    # Clear pending; occupy via recovery_task_index instead.
    :sys.replace_state(store, fn state ->
      state
      |> put_in([:recovery_pending], %{})
      |> put_in([:recovery_task_index, occupied_id], make_ref())
    end)

    assert {:error, :task_id_already_exists} = TaskStore.reserve("agent_1", name: store)

    # Clear recovery indexes; an in-flight retirement still owns the id.
    :sys.replace_state(store, fn state ->
      state
      |> put_in([:recovery_pending], %{})
      |> put_in([:recovery_task_index], %{})
      |> put_in([:lease_retire_task_index, occupied_id], make_ref())
    end)

    assert {:error, :task_id_already_exists} = TaskStore.reserve("agent_1", name: store)

    # Clear indexes — same generator now succeeds.
    :sys.replace_state(store, fn state ->
      state
      |> put_in([:recovery_pending], %{})
      |> put_in([:recovery_task_index], %{})
      |> put_in([:lease_retire_task_index], %{})
    end)

    assert {:ok, %{task_id: ^occupied_id}} = TaskStore.reserve("agent_1", name: store)
  end

  defp unique(prefix), do: :"#{prefix}_#{System.unique_integer([:positive])}"

  defp wait_until(fun, attempts) do
    cond do
      fun.() ->
        true

      attempts <= 0 ->
        flunk("timeout waiting for condition")

      true ->
        Process.sleep(20)
        wait_until(fun, attempts - 1)
    end
  end
end
