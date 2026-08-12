defmodule Arbor.Agent.RuntimeAdmission.LivenessSettlementSecurityRegressionTest do
  @moduledoc """
  Phase 4C C3C1a0 liveness/settlement security regressions.

  Uses only checkpoint-existing public/OTP boundaries (TaskStore, IntentOwner,
  Registry, :sys, Process.info mailbox, OrdinaryStartWorker hold message).

  Mode A: production IntentOwner + OrdinaryStartWorker hold.
  Mode B: controlled trap-exit owner + controlled exact worker. Uses a
  planted launch_ref + authenticated launch bind (no nil-intent adopt).
  Production admission remains admit → launch_ref bind-in-init → adopt.

  Compiles on checkpoint 8118a8fa77 and fails there behaviorally for
  barrier/retirement defects; passes on the settlement-barrier candidate.
  """

  use ExUnit.Case, async: false

  @moduletag :security_regression
  @moduletag :fast

  alias Arbor.Agent.Orchestration.{TaskControlRecoveryMemory, TaskStore}
  alias Arbor.Agent.RuntimeAdmission.IntentOwner
  alias Arbor.Agent.RuntimeAdmission.Opts
  alias Arbor.Agent.RuntimeAdmission.Supervisor, as: RASupervisor

  @registry Arbor.Agent.RuntimeAdmissionRegistry
  # Checkpoint-existing hold release message (OrdinaryStartWorker test hold).
  @release_hold :runtime_admission_release_hold

  setup do
    TaskControlRecoveryMemory.ensure!()
    TaskControlRecoveryMemory.reset!()
    ensure_runtime_admission_registry!()

    ra_sup = start_supervised!({RASupervisor, name: unique_name(:ra_sup)})
    task_sup = start_supervised!({Task.Supervisor, name: unique_name(:task_sup)})
    store = unique_name(:store)

    start_supervised!({
      TaskStore,
      # Long enough for R7 intermediate barrier observation; R8 injects the
      # exact timeout message under suspension rather than racing this timer.
      name: store,
      task_supervisor: task_sup,
      runtime_admission_supervisor: ra_sup,
      runtime_admission_force_ready: true,
      runtime_admission_settle_timeout_ms: 30_000,
      fence_force_ready: true,
      recovery_force_ready: true
    })

    Application.put_env(:arbor_agent, :runtime_admission_test_hold, %{timeout_ms: 30_000})
    on_exit(fn -> Application.delete_env(:arbor_agent, :runtime_admission_test_hold) end)

    %{store: store, ra_sup: ra_sup, task_sup: task_sup}
  end

  test "security regression R1: external :normal does not retire owner; :kill unregisters",
       %{store: store} do
    {agent_id, fp, kw, _parent} = start_held_admit(store, :admit_first)
    {owner_pid, _intent_id, ^fp} = await_exact_live_owner(agent_id, fp)
    worker_pid = await_bound_worker(store, agent_id)

    Process.exit(owner_pid, :normal)
    await_until(fn -> Process.alive?(owner_pid) end, 1_000)
    assert [{^owner_pid, _}] = Registry.lookup(@registry, {:runtime_admission_owner, agent_id})

    Process.exit(owner_pid, :kill)
    await_until(fn -> not Process.alive?(owner_pid) end, 2_000)

    await_until(
      fn -> Registry.lookup(@registry, {:runtime_admission_owner, agent_id}) == [] end,
      2_000
    )

    if Process.alive?(worker_pid), do: Process.exit(worker_pid, :kill)

    first = assert_receive_admit(:admit_first, 15_000)
    # Owner-down with held/killed worker, no branch → exact worker_down.
    assert first == {:error, :worker_down}

    # Second same-target start: async so the test process never blocks on a held worker.
    spawn_admit(store, agent_id, fp, kw, :admit_second)
    {_owner2, _id2, ^fp} = await_exact_live_owner(agent_id, fp)
    worker2 = await_bound_worker(store, agent_id)

    release_worker_hold(worker2)
    second = assert_receive_admit(:admit_second, 15_000)
    refute second == {:error, :target_owner_taken}
    # Clean held-then-released start without profile → exact not_found.
    assert second == {:error, :not_found}
  end

  test "security regression R2: after full finalize second same-target start converges", %{
    store: store
  } do
    {agent_id, fp, kw, _parent} = start_held_admit(store, :admit_first)
    {owner_pid, _intent_id, ^fp} = await_exact_live_owner(agent_id, fp)
    worker_pid = await_bound_worker(store, agent_id)

    release_worker_hold(worker_pid)
    first = assert_receive_admit(:admit_first, 15_000)
    assert first == {:error, :not_found}

    await_until(fn -> is_nil(store_intent(store, agent_id)) end, 5_000)

    await_until(
      fn -> Registry.lookup(@registry, {:runtime_admission_owner, agent_id}) == [] end,
      2_000
    )

    if Process.alive?(owner_pid), do: Process.exit(owner_pid, :kill)

    spawn_admit(store, agent_id, fp, kw, :admit_second)
    {_owner2, _id2, ^fp} = await_exact_live_owner(agent_id, fp)
    worker2 = await_bound_worker(store, agent_id)
    release_worker_hold(worker2)

    second = assert_receive_admit(:admit_second, 15_000)
    refute second == {:error, :target_owner_taken}
    assert second == {:error, :not_found}
  end

  test "security regression R3: unrelated bind failures are not collision-retried", %{
    store: store
  } do
    {agent_id, fp, _kw, _caller_pid} = start_held_admit(store, :admit)
    {_owner_pid, intent_id, fingerprint} = await_exact_live_owner(agent_id, fp)
    _worker = await_bound_worker(store, agent_id)

    foreign = spawn(fn -> Process.sleep(30_000) end)

    assert {:error, :not_owner} =
             TaskStore.bind_runtime_admission_worker(
               agent_id,
               intent_id,
               fingerprint,
               foreign,
               name: store
             )

    assert is_map(store_intent(store, agent_id))
    refute_receive {:admit, _}, 100
  end

  test "security regression R4: owner death with held worker releases waiters (no permanent park)",
       %{store: store} do
    {agent_id, fp, _kw, _parent} = start_held_admit(store, :admit)
    {owner_pid, _intent_id, ^fp} = await_exact_live_owner(agent_id, fp)
    worker_pid = await_bound_worker(store, agent_id)

    Process.exit(owner_pid, :kill)
    await_until(fn -> not Process.alive?(owner_pid) end, 2_000)

    # Held-worker owner DOWN is only await_worker_down or already finalized.
    # The store_intent snapshot itself proves intermediate-before-terminal; do
    # not insert a timing-based refute_receive after the read (terminal may
    # already be in the test mailbox).
    intermediate =
      await_until(
        fn ->
          case store_intent(store, agent_id) do
            nil -> :finalized
            %{retire_barrier: :await_worker_down} = intent -> {:barrier, intent}
            _ -> false
          end
        end,
        5_000
      )

    case intermediate do
      :finalized ->
        :ok

      {:barrier, _intent} ->
        if Process.alive?(worker_pid), do: Process.exit(worker_pid, :kill)
    end

    assert_receive {:admit, {:error, :worker_down}}, 15_000
    await_until(fn -> is_nil(store_intent(store, agent_id)) end, 5_000)
  end

  test "security regression R5: worker death releases waiters with typed terminal", %{
    store: store
  } do
    {agent_id, fp, _kw, _parent} = start_held_admit(store, :admit)
    {_owner_pid, _intent_id, ^fp} = await_exact_live_owner(agent_id, fp)
    worker_pid = await_bound_worker(store, agent_id)

    Process.exit(worker_pid, :kill)

    assert_receive {:admit, {:error, :worker_down}}, 15_000
    await_until(fn -> is_nil(store_intent(store, agent_id)) end, 5_000)
  end

  test "security regression R6: exact live triple for foreign deny", %{store: store} do
    {agent_id, fp, _kw, _parent} = start_held_admit(store, :admit)
    {_owner_pid, intent_id, fingerprint} = await_exact_live_owner(agent_id, fp)
    assert fingerprint == fp
    _worker = await_bound_worker(store, agent_id)

    foreign = spawn(fn -> Process.sleep(10_000) end)

    assert {:error, :not_owner} =
             TaskStore.bind_runtime_admission_worker(
               agent_id,
               intent_id,
               fingerprint,
               foreign,
               name: store
             )

    assert {:error, :not_owner} =
             TaskStore.settle_runtime_admission(
               agent_id,
               intent_id,
               {:applied, self()},
               name: store
             )

    refute_receive {:admit, _}, 100
  end

  test "security regression R7 crash-window: settling+await_owner_down unreplied until owner DOWN",
       %{store: store} do
    %{
      agent_id: agent_id,
      intent_id: intent_id,
      owner_pid: owner_pid,
      worker_pid: worker_pid
    } = start_mode_b(store)

    assert :ok =
             command_worker_settle(worker_pid, store, agent_id, intent_id, {:error, :r7_terminal})

    intent = await_settling_barrier(store, agent_id)
    assert intent.intent_id == intent_id
    assert intent.phase == :settling
    assert intent.retire_barrier == :await_owner_down
    assert intent.terminal == {:error, :r7_terminal}
    assert is_map(store_intent(store, agent_id))
    refute_receive {:admit, _}, 200
    assert Process.alive?(owner_pid)

    # Only R7 completes via explicit authentic owner kill.
    Process.exit(owner_pid, :kill)

    assert_receive {:admit, {:error, :r7_terminal}}, 15_000
    await_until(fn -> is_nil(store_intent(store, agent_id)) end, 5_000)
  end

  test "security regression R8: settle timeout does not finalize without owner DOWN", %{
    store: store
  } do
    %{
      agent_id: agent_id,
      intent_id: intent_id,
      owner_pid: owner_pid,
      worker_pid: worker_pid
    } = start_mode_b(store)

    assert :ok =
             command_worker_settle(
               worker_pid,
               store,
               agent_id,
               intent_id,
               {:error, :r8_terminal}
             )

    intent = await_settling_barrier(store, agent_id)
    assert intent.phase == :settling
    assert intent.retire_barrier == :await_owner_down
    assert intent.terminal == {:error, :r8_terminal}
    refute_receive {:admit, _}, 100

    store_pid = Process.whereis(store)
    assert is_pid(store_pid)

    # Suspend first so the armed timer cannot be handled before we queue observation.
    :sys.suspend(store_pid)

    # Snapshot exact timer gen while suspended (system get_state is valid).
    %{runtime_admission_settle_timers: timers} = :sys.get_state(store_pid)
    entry = Map.fetch!(timers, intent_id)
    gen = Map.fetch!(entry, :gen)
    timer_ref = Map.get(entry, :timer_ref)

    # Ensure exact timeout message is queued (cancel natural timer + inject exact gen).
    if is_reference(timer_ref), do: Process.cancel_timer(timer_ref)

    msgs0 = mailbox_messages(store_pid)

    unless Enum.any?(msgs0, &match?({:runtime_admission_settle_timeout, ^intent_id, ^gen}, &1)) do
      send(store_pid, {:runtime_admission_settle_timeout, intent_id, gen})
    end

    await_until(
      fn ->
        msgs = mailbox_messages(store_pid)
        Enum.any?(msgs, &match?({:runtime_admission_settle_timeout, ^intent_id, ^gen}, &1))
      end,
      2_000
    )

    # Enqueue public GenServer observation AFTER timeout, BEFORE induced DOWN.
    op = "op_r8_#{System.unique_integer([:positive])}"
    test = self()

    spawn(fn ->
      send(test, {:r8_obs, TaskStore.install_target_fence(agent_id, op, name: store)})
    end)

    await_until(
      fn ->
        msgs = mailbox_messages(store_pid)

        t_idx =
          Enum.find_index(
            msgs,
            &match?({:runtime_admission_settle_timeout, ^intent_id, ^gen}, &1)
          )

        o_idx =
          Enum.find_index(
            msgs,
            &match?({:"$gen_call", _, {:install_target_fence, ^agent_id, ^op}}, &1)
          )

        is_integer(t_idx) and is_integer(o_idx) and t_idx < o_idx and
          not Enum.any?(msgs, &match?({:DOWN, _, :process, ^owner_pid, _}, &1))
      end,
      2_000
    )

    :sys.resume(store_pid)

    # Causal proof that timeout did not finalize: observer ran after timeout and
    # still saw non-idle intent. Do not refute_receive admit here — waiter reply
    # and observer reply travel different processes; authentic DOWN may deliver
    # to the test mailbox before {:r8_obs, _} even when TaskStore serialized
    # timeout → observation → DOWN correctly.
    assert_receive {:r8_obs, {:ok, %{active_count: active}}}, 5_000
    assert active >= 1

    # Authentic DOWN from timeout's untrappable :kill finalizes — do not manual-kill.
    assert_receive {:admit, {:error, :r8_terminal}}, 15_000
    await_until(fn -> is_nil(store_intent(store, agent_id)) end, 5_000)

    # Reuse the exact R8 observer op to confirm idle, then remove the fence.
    assert {:ok, %{active_count: 0}} =
             TaskStore.install_target_fence(agent_id, op, name: store)

    assert :ok = TaskStore.remove_target_fence(agent_id, op, name: store)
  end

  test "security regression R9 settle-first: settle $gen_call before owner DOWN",
       %{store: store} do
    %{
      agent_id: agent_id,
      intent_id: intent_id,
      owner_pid: owner_pid,
      worker_pid: worker_pid
    } = start_mode_b(store)

    store_pid = Process.whereis(store)
    assert is_pid(store_pid)

    :sys.suspend(store_pid)

    # Worker is the process that must call settle — command it directly.
    send(worker_pid, {:settle, store, agent_id, intent_id, {:error, :r9_settle_first}, self()})

    await_until(
      fn ->
        msgs = mailbox_messages(store_pid)
        Enum.any?(msgs, &settle_call?(&1, agent_id, intent_id))
      end,
      5_000
    )

    Process.exit(owner_pid, :kill)

    await_until(
      fn ->
        msgs = mailbox_messages(store_pid)
        s = Enum.find_index(msgs, &settle_call?(&1, agent_id, intent_id))
        d = Enum.find_index(msgs, &match?({:DOWN, _, :process, ^owner_pid, _}, &1))
        is_integer(s) and is_integer(d) and s < d
      end,
      5_000
    )

    msgs = mailbox_messages(store_pid)
    s = Enum.find_index(msgs, &settle_call?(&1, agent_id, intent_id))
    d = Enum.find_index(msgs, &match?({:DOWN, _, :process, ^owner_pid, _}, &1))
    assert is_integer(s) and is_integer(d) and s < d

    :sys.resume(store_pid)

    assert_receive {:admit, {:error, :r9_settle_first}}, 15_000
    await_until(fn -> is_nil(store_intent(store, agent_id)) end, 5_000)

    assert {:error, :not_found} =
             TaskStore.settle_runtime_admission(
               agent_id,
               intent_id,
               {:error, :too_late},
               name: store
             )
  end

  test "security regression R9 DOWN-first: owner DOWN before settle; worker-down path",
       %{store: store} do
    # Part A: mailbox order DOWN before settle.
    %{
      agent_id: agent_id,
      intent_id: intent_id,
      owner_pid: owner_pid,
      worker_pid: worker_pid
    } = start_mode_b(store)

    store_pid = Process.whereis(store)
    assert is_pid(store_pid)

    :sys.suspend(store_pid)
    Process.exit(owner_pid, :kill)

    await_until(
      fn ->
        msgs = mailbox_messages(store_pid)
        Enum.any?(msgs, &match?({:DOWN, _, :process, ^owner_pid, _}, &1))
      end,
      5_000
    )

    send(worker_pid, {:settle, store, agent_id, intent_id, {:error, :r9_down_first}, self()})

    await_until(
      fn ->
        msgs = mailbox_messages(store_pid)
        d = Enum.find_index(msgs, &match?({:DOWN, _, :process, ^owner_pid, _}, &1))
        s = Enum.find_index(msgs, &settle_call?(&1, agent_id, intent_id))
        is_integer(d) and is_integer(s) and d < s
      end,
      5_000
    )

    msgs = mailbox_messages(store_pid)
    d = Enum.find_index(msgs, &match?({:DOWN, _, :process, ^owner_pid, _}, &1))
    s = Enum.find_index(msgs, &settle_call?(&1, agent_id, intent_id))
    assert is_integer(d) and is_integer(s) and d < s

    :sys.resume(store_pid)

    # DOWN-then-settle: exact worker still eligible under await_worker_down →
    # ownerless finalize with the worker's terminal (first authoritative wins).
    assert_receive {:admit, {:error, :r9_down_first}}, 15_000

    assert {:error, :not_found} =
             TaskStore.settle_runtime_admission(
               agent_id,
               intent_id,
               {:error, :late_after_down},
               name: store
             )
  end

  test "security regression R9b: worker DOWN terminal; late settle not_found",
       %{store: store} do
    {agent_id, fp, _kw, _parent} = start_held_admit(store, :admit)
    {owner_pid, intent_id, ^fp} = await_exact_live_owner(agent_id, fp)
    worker_pid = await_bound_worker(store, agent_id)

    Process.exit(owner_pid, :kill)
    await_until(fn -> not Process.alive?(owner_pid) end, 2_000)

    # Snapshot intermediate (or already finalized). No post-read refute_receive:
    # authentic worker_down may already be in the test mailbox.
    intermediate =
      await_until(
        fn ->
          case store_intent(store, agent_id) do
            nil -> :finalized
            %{retire_barrier: :await_worker_down} -> :barrier
            _ -> false
          end
        end,
        5_000
      )

    case intermediate do
      :finalized ->
        :ok

      :barrier ->
        if Process.alive?(worker_pid), do: Process.exit(worker_pid, :kill)
    end

    assert_receive {:admit, {:error, :worker_down}}, 15_000

    assert {:error, :not_found} =
             TaskStore.settle_runtime_admission(
               agent_id,
               intent_id,
               {:error, :late_after_down},
               name: store
             )
  end

  test "security regression R9a: held barrier deterministic before worker completion",
       %{store: store} do
    {agent_id, fp, _kw, _parent} = start_held_admit(store, :admit)
    {owner_pid, _intent_id, ^fp} = await_exact_live_owner(agent_id, fp)
    worker_pid = await_bound_worker(store, agent_id)

    store_pid = Process.whereis(store)
    assert is_pid(store_pid)

    # Do not accept a racing nil intent as proof. Suspend and serialize:
    # owner DOWN → public observation → (induced) worker DOWN.
    :sys.suspend(store_pid)
    Process.exit(owner_pid, :kill)

    await_until(
      fn ->
        msgs = mailbox_messages(store_pid)
        Enum.any?(msgs, &match?({:DOWN, _, :process, ^owner_pid, _}, &1))
      end,
      5_000
    )

    op = "op_r9a_#{System.unique_integer([:positive])}"
    test = self()

    spawn(fn ->
      send(test, {:r9a_obs, TaskStore.install_target_fence(agent_id, op, name: store)})
    end)

    await_until(
      fn ->
        msgs = mailbox_messages(store_pid)

        d_idx =
          Enum.find_index(msgs, &match?({:DOWN, _, :process, ^owner_pid, _}, &1))

        o_idx =
          Enum.find_index(
            msgs,
            &match?({:"$gen_call", _, {:install_target_fence, ^agent_id, ^op}}, &1)
          )

        is_integer(d_idx) and is_integer(o_idx) and d_idx < o_idx and
          not Enum.any?(msgs, &match?({:DOWN, _, :process, ^worker_pid, _}, &1))
      end,
      5_000
    )

    :sys.resume(store_pid)

    # Observation after owner DOWN handling sees non-idle await_worker_down;
    # worker DOWN has not been processed yet (queued after observation).
    assert_receive {:r9a_obs, {:ok, %{active_count: active}}}, 5_000
    assert active >= 1

    assert_receive {:admit, {:error, :worker_down}}, 15_000
    await_until(fn -> is_nil(store_intent(store, agent_id)) end, 5_000)

    assert {:ok, %{active_count: 0}} =
             TaskStore.install_target_fence(agent_id, op, name: store)

    assert :ok = TaskStore.remove_target_fence(agent_id, op, name: store)
  end

  test "security regression: stale monitored owner DOWN does not retire rebound intent", %{
    store: store
  } do
    {agent_id, fp, _kw, caller_pid} = start_held_admit(store, :admit)
    {owner_pid, intent_id, ^fp} = await_exact_live_owner(agent_id, fp)
    worker_pid = await_bound_worker(store, agent_id)

    store_pid = Process.whereis(store)
    assert is_pid(store_pid)

    %{runtime_admission_owner_monitors: mons} = :sys.get_state(store_pid)

    found =
      Enum.find(mons, fn {_m, {id, t, p}} ->
        id == intent_id and t == agent_id and p == owner_pid
      end)

    assert is_tuple(found)

    fake_rebound = spawn(fn -> Process.sleep(60_000) end)

    :sys.replace_state(store_pid, fn st ->
      case get_in(st, [:runtime_admission_intents, agent_id]) do
        %{intent_id: ^intent_id} = intent ->
          put_in(st, [:runtime_admission_intents, agent_id], %{intent | owner_pid: fake_rebound})

        _ ->
          st
      end
    end)

    Process.exit(owner_pid, :kill)
    await_until(fn -> not Process.alive?(owner_pid) end, 2_000)

    await_until(
      fn ->
        case store_intent(store, agent_id) do
          %{intent_id: ^intent_id, owner_pid: ^fake_rebound} -> true
          _ -> false
        end
      end,
      2_000
    )

    intent_after = store_intent(store, agent_id)
    assert is_map(intent_after)
    assert intent_after.intent_id == intent_id
    assert intent_after.owner_pid == fake_rebound
    refute_receive {:admit, _}, 100

    if Process.alive?(worker_pid), do: Process.exit(worker_pid, :kill)
    if Process.alive?(fake_rebound), do: Process.exit(fake_rebound, :kill)
    if Process.alive?(caller_pid), do: Process.exit(caller_pid, :kill)
  end

  # ── Mode A helpers ────────────────────────────────────────────────

  defp start_held_admit(store, tag) do
    agent_id = "agent_live#{System.unique_integer([:positive])}"
    assert {:ok, %{fingerprint: fp, keyword: kw}} = Opts.project([])
    caller_pid = spawn_admit(store, agent_id, fp, kw, tag)
    {agent_id, fp, kw, caller_pid}
  end

  defp spawn_admit(store, agent_id, fp, kw, tag) do
    test = self()

    spawn(fn ->
      send(
        test,
        {tag,
         TaskStore.admit_ordinary_runtime_start(agent_id, fp, kw, name: store, timeout: 60_000)}
      )
    end)
  end

  defp assert_receive_admit(tag, timeout) do
    receive do
      {^tag, result} -> result
    after
      timeout -> flunk("timed out waiting for admit tag #{inspect(tag)}")
    end
  end

  defp await_exact_live_owner(agent_id, expected_fp) do
    owner_pid =
      await_until(
        fn ->
          case Registry.lookup(@registry, {:runtime_admission_owner, agent_id}) do
            [{pid, _}] when is_pid(pid) -> pid
            _ -> false
          end
        end,
        5_000
      )

    assert {:ok, snap} = IntentOwner.snapshot(owner_pid)
    assert snap.target_agent_id == agent_id
    assert snap.fingerprint == expected_fp
    assert is_binary(snap.intent_id)
    {owner_pid, snap.intent_id, snap.fingerprint}
  end

  defp await_bound_worker(store, agent_id) do
    await_until(
      fn ->
        case store_intent(store, agent_id) do
          %{worker_pid: pid} when is_pid(pid) -> pid
          _ -> false
        end
      end,
      5_000
    )
  end

  # ── Mode B helpers (test-only launch-bind then adopt) ─────────────

  defp start_mode_b(store) do
    agent_id = "agent_ctrl#{System.unique_integer([:positive])}"
    intent_id = "rai_ctrl#{System.unique_integer([:positive])}"
    assert {:ok, %{fingerprint: fp, keyword: kw}} = Opts.project([])
    test = self()
    launch_ref = make_ref()
    store_pid = Process.whereis(store)
    assert is_pid(store_pid)

    # Plant a launch-attempt row so the controlled owner can bind via the
    # authenticated launch_ref path (no nil-intent adopt forge).
    :sys.replace_state(store_pid, fn st ->
      intent = %{
        intent_id: intent_id,
        target_agent_id: agent_id,
        kind: :ordinary_start,
        fingerprint: fp,
        phase: :owner_launching,
        owner_pid: nil,
        worker_pid: nil,
        terminal: nil,
        retire_barrier: :none,
        launch_ref: launch_ref,
        launcher_pid: nil,
        launcher_mon: nil,
        launcher_attempt_index: 1
      }

      st
      |> put_in([:runtime_admission_intents, agent_id], intent)
      |> put_in([:runtime_admission_by_id, intent_id], agent_id)
    end)

    owner_pid =
      spawn(fn ->
        Process.flag(:trap_exit, true)

        {:ok, _} =
          Registry.register(@registry, {:runtime_admission_owner, agent_id}, %{
            intent_id: intent_id,
            fingerprint: fp
          })

        :ok =
          TaskStore.bind_runtime_admission_launch(
            agent_id,
            intent_id,
            fp,
            launch_ref,
            name: store
          )

        :ok =
          TaskStore.adopt_runtime_admission_owner(agent_id, intent_id, fp, name: store)

        send(test, {:owner_ready, self()})
        controlled_owner_loop(store, agent_id, intent_id, fp)
      end)

    assert_receive {:owner_ready, ^owner_pid}, 5_000

    worker_pid =
      spawn(fn ->
        controlled_worker_loop()
      end)

    send(owner_pid, {:bind, worker_pid, test})
    assert_receive {:bind_done, :ok}, 5_000

    # Waiter joins open intent (production admit path).
    spawn_admit(store, agent_id, fp, kw, :admit)

    # Confirm worker bound in store.
    bound = await_bound_worker(store, agent_id)
    assert bound == worker_pid

    %{
      agent_id: agent_id,
      intent_id: intent_id,
      fingerprint: fp,
      keyword: kw,
      owner_pid: owner_pid,
      worker_pid: worker_pid
    }
  end

  defp controlled_owner_loop(store, agent_id, intent_id, fp) do
    receive do
      {:bind, worker_pid, from} ->
        result =
          TaskStore.bind_runtime_admission_worker(
            agent_id,
            intent_id,
            fp,
            worker_pid,
            name: store
          )

        send(from, {:bind_done, result})
        controlled_owner_loop(store, agent_id, intent_id, fp)

      {:EXIT, _from, _reason} ->
        # Absorb :shutdown from begin_settling; stay alive until untrappable kill.
        controlled_owner_loop(store, agent_id, intent_id, fp)

      _other ->
        controlled_owner_loop(store, agent_id, intent_id, fp)
    end
  end

  defp controlled_worker_loop do
    receive do
      {:settle, store, agent_id, intent_id, outcome, from} ->
        result =
          TaskStore.settle_runtime_admission(agent_id, intent_id, outcome, name: store)

        send(from, {:settle_done, result})
        controlled_worker_loop()

      {:park, from} ->
        send(from, :parked)

        receive do
          :continue -> controlled_worker_loop()
        end

      _other ->
        controlled_worker_loop()
    end
  end

  defp command_worker_settle(worker_pid, store, agent_id, intent_id, outcome) do
    send(worker_pid, {:settle, store, agent_id, intent_id, outcome, self()})

    receive do
      {:settle_done, :ok} -> :ok
      {:settle_done, other} -> flunk("expected settle :ok, got #{inspect(other)}")
    after
      15_000 -> flunk("worker settle timed out")
    end
  end

  # ── Shared helpers ────────────────────────────────────────────────

  defp await_settling_barrier(store, agent_id) do
    await_until(
      fn ->
        case store_intent(store, agent_id) do
          %{phase: :settling, retire_barrier: :await_owner_down} = intent -> intent
          _ -> false
        end
      end,
      15_000
    )
  end

  # Non-mutating intent inspection via :sys.get_state — never install a fence
  # just to probe active/idle (install_target_fence is reserved for R8 observer).
  defp store_intent(store, agent_id) do
    case Process.whereis(store) do
      pid when is_pid(pid) ->
        case :sys.get_state(pid) do
          %{runtime_admission_intents: intents} -> Map.get(intents, agent_id)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp release_worker_hold(worker_pid) when is_pid(worker_pid) do
    send(worker_pid, @release_hold)
    :ok
  end

  defp mailbox_messages(pid) when is_pid(pid) do
    case Process.info(pid, :messages) do
      {:messages, msgs} -> msgs
      _ -> []
    end
  end

  defp settle_call?(msg, agent_id, intent_id) do
    match?(
      {:"$gen_call", _, {:settle_runtime_admission, ^agent_id, ^intent_id, _}},
      msg
    )
  end

  defp await_until(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_until(fun, deadline)
  end

  defp do_await_until(fun, deadline) do
    case fun.() do
      false ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("await_until timed out")
        else
          Process.sleep(20)
          do_await_until(fun, deadline)
        end

      nil ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("await_until timed out")
        else
          Process.sleep(20)
          do_await_until(fun, deadline)
        end

      other ->
        other
    end
  end

  defp ensure_runtime_admission_registry! do
    case Process.whereis(@registry) do
      nil ->
        start_supervised!({Registry, keys: :unique, name: @registry})

      _ ->
        :ok
    end
  end

  defp unique_name(:ra_sup), do: __MODULE__.RuntimeAdmissionSupervisor
  defp unique_name(:task_sup), do: __MODULE__.TaskSupervisor
  defp unique_name(:store), do: __MODULE__.TaskStore
end
