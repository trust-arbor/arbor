defmodule Arbor.Agent.RuntimeAdmission.LivenessSettlementSecurityRegressionTest do
  @moduledoc """
  Phase 4C C3C1a0 liveness/settlement security regressions.

  Uses only checkpoint-existing public/OTP boundaries (TaskStore, IntentOwner,
  Registry, :sys, OrdinaryStartWorker hold message). Compiles on checkpoint
  8118a8fa7 and fails there behaviorally for barrier/retirement defects.
  """

  use ExUnit.Case, async: false

  @moduletag :security_regression
  @moduletag :fast

  alias Arbor.Agent.Orchestration.{TaskControlRecoveryMemory, TaskStore}
  alias Arbor.Agent.RuntimeAdmission.IntentCore
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

    start_supervised!(
      {TaskStore,
       name: store,
       task_supervisor: task_sup,
       runtime_admission_supervisor: ra_sup,
       runtime_admission_force_ready: true,
       runtime_admission_settle_timeout_ms: 80,
       fence_force_ready: true,
       recovery_force_ready: true}
    )

    Application.put_env(:arbor_agent, :runtime_admission_test_hold, %{timeout_ms: 30_000})
    on_exit(fn -> Application.delete_env(:arbor_agent, :runtime_admission_test_hold) end)

    %{store: store, ra_sup: ra_sup, task_sup: task_sup}
  end

  test "security regression R1: external :normal does not retire owner; :kill unregisters",
       %{store: store} do
    {agent_id, fp, kw, _parent} = start_held_admit(store)
    {owner_pid, _intent_id, ^fp} = await_exact_live_owner(agent_id, fp)
    worker_pid = await_bound_worker(store, agent_id)

    Process.exit(owner_pid, :normal)
    Process.sleep(30)
    assert Process.alive?(owner_pid)
    assert [{^owner_pid, _}] = Registry.lookup(@registry, {:runtime_admission_owner, agent_id})

    Process.exit(owner_pid, :kill)
    await_until(fn -> not Process.alive?(owner_pid) end, 2_000)

    await_until(
      fn -> Registry.lookup(@registry, {:runtime_admission_owner, agent_id}) == [] end,
      2_000
    )

    # Release any residual held worker so owner-DOWN paths can complete.
    if Process.alive?(worker_pid), do: Process.exit(worker_pid, :kill)
    _ = flush_admit()

    result =
      TaskStore.admit_ordinary_runtime_start(agent_id, fp, kw, name: store, timeout: 15_000)

    # Second same-target start must not sticky-fail on zombie Registry owner.
    refute match?({:error, :target_owner_taken}, result)
  end

  test "security regression R2: after full finalize second same-target start converges", %{
    store: store
  } do
    {agent_id, fp, kw, _parent} = start_held_admit(store)
    {owner_pid, _intent_id, ^fp} = await_exact_live_owner(agent_id, fp)
    worker_pid = await_bound_worker(store, agent_id)

    # Deterministic finalize: release hold so worker settles, then retire owner.
    :sys.suspend(owner_pid)
    release_worker_hold(worker_pid)
    await_settling_barrier(store, agent_id)
    :sys.resume(owner_pid)
    if Process.alive?(owner_pid), do: Process.exit(owner_pid, :shutdown)

    first = flush_admit()
    assert match?({:ok, _}, first) or match?({:error, _}, first)
    await_until(fn -> fence_active_count(store, agent_id) == 0 end, 5_000)

    await_until(
      fn -> Registry.lookup(@registry, {:runtime_admission_owner, agent_id}) == [] end,
      2_000
    )

    second =
      TaskStore.admit_ordinary_runtime_start(agent_id, fp, kw, name: store, timeout: 15_000)

    refute match?({:error, :target_owner_taken}, second)
    assert match?({:ok, _}, second) or match?({:error, _}, second)
  end

  test "security regression R3: unrelated bind failures are not collision-retried", %{
    store: store
  } do
    {agent_id, fp, _kw, _parent} = start_held_admit(store)
    {_owner_pid, intent_id, fingerprint} = await_exact_live_owner(agent_id, fp)
    _worker = await_bound_worker(store, agent_id)

    # Closed allowlist: bind auth errors never retry (unit + live deny).
    refute IntentCore.retryable_launch_failure?(:not_owner)
    refute IntentCore.retryable_launch_failure?(:conflict)
    refute IntentCore.retryable_launch_failure?({:bind_failed, :not_owner})

    foreign = spawn(fn -> Process.sleep(30_000) end)

    assert {:error, reason} =
             TaskStore.bind_runtime_admission_worker(
               agent_id,
               intent_id,
               fingerprint,
               foreign,
               name: store
             )

    assert reason in [:not_owner, :conflict, :not_found]
    # Intent remains live under hold — foreign bind did not "succeed via retry".
    assert fence_active_count(store, agent_id) >= 1
    refute_receive {:admit, _}, 100
  end

  test "security regression R4: owner death with held worker releases waiters (no permanent park)",
       %{store: store} do
    {agent_id, fp, _kw, _parent} = start_held_admit(store)
    {owner_pid, _intent_id, ^fp} = await_exact_live_owner(agent_id, fp)
    worker_pid = await_bound_worker(store, agent_id)

    Process.exit(owner_pid, :kill)
    await_until(fn -> not Process.alive?(owner_pid) end, 2_000)

    # Deterministic: wait for await_worker_down (or idle after full finalize).
    await_until(
      fn ->
        case store_intent(store, agent_id) do
          nil -> true
          %{retire_barrier: :await_worker_down} -> true
          %{phase: :settling} -> true
          _ -> false
        end
      end,
      5_000
    )

    # Complete worker barrier if still held.
    if Process.alive?(worker_pid), do: Process.exit(worker_pid, :kill)

    assert_receive {:admit, result}, 15_000
    assert match?({:error, _}, result) or match?({:ok, _}, result)
    await_until(fn -> fence_active_count(store, agent_id) == 0 end, 5_000)
  end

  test "security regression R5: worker death releases waiters with typed terminal", %{
    store: store
  } do
    {agent_id, fp, _kw, _parent} = start_held_admit(store)
    {_owner_pid, _intent_id, ^fp} = await_exact_live_owner(agent_id, fp)
    worker_pid = await_bound_worker(store, agent_id)

    Process.exit(worker_pid, :kill)

    # Without a branch witness, live worker DOWN classifies to :worker_down.
    assert_receive {:admit, {:error, :worker_down}}, 15_000
    await_until(fn -> fence_active_count(store, agent_id) == 0 end, 5_000)
  end

  test "security regression R6: exact live triple for foreign deny", %{store: store} do
    {agent_id, fp, _kw, _parent} = start_held_admit(store)
    {_owner_pid, intent_id, fingerprint} = await_exact_live_owner(agent_id, fp)
    assert fingerprint == fp
    _worker = await_bound_worker(store, agent_id)

    foreign = spawn(fn -> Process.sleep(10_000) end)

    assert {:error, reason} =
             TaskStore.bind_runtime_admission_worker(
               agent_id,
               intent_id,
               fingerprint,
               foreign,
               name: store
             )

    assert reason in [:not_owner, :conflict, :not_found]

    assert {:error, settle_reason} =
             TaskStore.settle_runtime_admission(
               agent_id,
               intent_id,
               {:applied, self()},
               name: store
             )

    assert settle_reason in [:not_owner, :conflict, :not_found]
    refute_receive {:admit, _}, 100
  end

  test "security regression R7 crash-window: settling+await_owner_down unreplied until owner DOWN",
       %{store: store} do
    {agent_id, fp, _kw, _parent} = start_held_admit(store)
    {owner_pid, intent_id, ^fp} = await_exact_live_owner(agent_id, fp)
    worker_pid = await_bound_worker(store, agent_id)

    # Suspend owner so settle cannot complete owner DOWN while we observe barrier.
    :sys.suspend(owner_pid)
    release_worker_hold(worker_pid)

    # Worker settles → request terminal → :settling + :await_owner_down.
    intent = await_settling_barrier(store, agent_id)
    assert intent.intent_id == intent_id
    assert intent.phase == :settling
    assert intent.retire_barrier == :await_owner_down
    assert Map.has_key?(intent, :terminal)
    assert fence_active_count(store, agent_id) >= 1
    refute_receive {:admit, _}, 200

    :sys.resume(owner_pid)
    if Process.alive?(owner_pid), do: Process.exit(owner_pid, :kill)

    # Waiter receives the exact terminal committed at begin_settling.
    terminal = intent.terminal
    expected = settlement_waiter_reply(terminal)
    assert_receive {:admit, ^expected}, 15_000
    await_until(fn -> fence_active_count(store, agent_id) == 0 end, 5_000)
  end

  test "security regression R8: settle timeout does not finalize without owner DOWN", %{
    store: store
  } do
    {agent_id, fp, _kw, _parent} = start_held_admit(store)
    {owner_pid, _intent_id, ^fp} = await_exact_live_owner(agent_id, fp)
    worker_pid = await_bound_worker(store, agent_id)

    :sys.suspend(owner_pid)
    release_worker_hold(worker_pid)
    intent = await_settling_barrier(store, agent_id)
    assert intent.phase == :settling
    assert intent.retire_barrier == :await_owner_down

    # Timer (80ms) may escalate :kill but must not finalize without DOWN handling.
    Process.sleep(200)
    refute_receive {:admit, _}, 100
    still = store_intent(store, agent_id)
    assert is_map(still)
    assert still.phase == :settling

    if Process.alive?(owner_pid) do
      :sys.resume(owner_pid)
      Process.exit(owner_pid, :kill)
    end

    assert_receive {:admit, _}, 15_000
  end

  test "security regression R9 settle-first: late exact worker terminal after owner DOWN",
       %{store: store} do
    {agent_id, fp, _kw, _parent} = start_held_admit(store)
    {owner_pid, intent_id, ^fp} = await_exact_live_owner(agent_id, fp)
    worker_pid = await_bound_worker(store, agent_id)
    store_pid = Process.whereis(store)
    assert is_pid(store_pid)

    # Let worker authenticate (store live), then pause store while worker is in
    # Lifecycle restore (no store call) so settle is enqueued AFTER owner DOWN.
    release_worker_hold(worker_pid)
    await_until(fn -> worker_in_gen_call?(worker_pid) end, 10_000)

    await_until(
      fn -> Process.alive?(worker_pid) and not worker_in_gen_call?(worker_pid) end,
      10_000
    )

    :sys.suspend(store_pid)
    Process.exit(owner_pid, :kill)
    # Worker finishes restore and blocks in settle GenServer.call (queued after DOWN).
    await_until(
      fn -> worker_in_gen_call?(worker_pid) or not Process.alive?(worker_pid) end,
      10_000
    )

    :sys.resume(store_pid)

    # Exact worker terminal: missing profile → Lifecycle restore :not_found.
    assert_receive {:admit, {:error, :not_found}}, 15_000
    await_until(fn -> is_nil(store_intent(store, agent_id)) end, 5_000)

    # Inverse after finalize: late settle is not_found (not a new terminal).
    assert {:error, :not_found} =
             TaskStore.settle_runtime_admission(
               agent_id,
               intent_id,
               {:error, :too_late},
               name: store
             )
  end

  test "security regression R9 DOWN-first: worker DOWN terminal; late settle not_found",
       %{store: store} do
    {agent_id, fp, _kw, _parent} = start_held_admit(store)
    {owner_pid, intent_id, ^fp} = await_exact_live_owner(agent_id, fp)
    worker_pid = await_bound_worker(store, agent_id)

    # Owner DOWN while worker still held → await_worker_down; store kills worker.
    Process.exit(owner_pid, :kill)
    await_until(fn -> not Process.alive?(owner_pid) end, 2_000)

    await_until(
      fn ->
        case store_intent(store, agent_id) do
          nil -> true
          %{retire_barrier: :await_worker_down} -> true
          _ -> false
        end
      end,
      5_000
    )

    # Ensure exact worker is down (store kill or explicit) without releasing hold
    # into Lifecycle settle — DOWN path must own the terminal.
    if Process.alive?(worker_pid), do: Process.exit(worker_pid, :kill)

    # DOWN-first classified terminal for not_running witness.
    assert_receive {:admit, {:error, :worker_down}}, 15_000

    assert {:error, reason} =
             TaskStore.settle_runtime_admission(
               agent_id,
               intent_id,
               {:error, :late_after_down},
               name: store
             )

    assert reason in [:not_found, :conflict, :not_owner]
  end

  test "security regression R9a: held barrier deterministic before worker completion",
       %{store: store} do
    {agent_id, fp, _kw, _parent} = start_held_admit(store)
    {owner_pid, _intent_id, ^fp} = await_exact_live_owner(agent_id, fp)
    worker_pid = await_bound_worker(store, agent_id)

    Process.exit(owner_pid, :kill)
    await_until(fn -> not Process.alive?(owner_pid) end, 2_000)

    # Deterministic observation: non-idle await_worker_down while worker still
    # held (or store already killed it and is finalizing). No fixed sleep race.
    await_until(
      fn ->
        case store_intent(store, agent_id) do
          %{phase: :outcome_unknown, retire_barrier: :await_worker_down, worker_pid: w}
          when is_pid(w) ->
            true

          %{phase: :outcome_unknown, retire_barrier: :await_worker_down} ->
            true

          nil ->
            # Already finalized if worker died quickly — still must have replied.
            true

          _ ->
            false
        end
      end,
      5_000
    )

    case store_intent(store, agent_id) do
      nil ->
        assert_receive {:admit, _}, 1_000

      %{retire_barrier: :await_worker_down, worker_pid: bound} = intent ->
        assert fence_active_count(store, agent_id) >= 1
        refute_receive {:admit, _}, 150
        # Exact bound worker still recorded until DOWN finalize.
        assert bound == worker_pid or not Process.alive?(worker_pid)

        if Process.alive?(worker_pid), do: Process.exit(worker_pid, :kill)
        assert_receive {:admit, {:error, :worker_down}}, 15_000

      %{retire_barrier: :await_worker_down} ->
        refute_receive {:admit, _}, 150
        if Process.alive?(worker_pid), do: Process.exit(worker_pid, :kill)
        assert_receive {:admit, {:error, :worker_down}}, 15_000

      _other ->
        assert_receive {:admit, _}, 15_000
    end

    await_until(fn -> fence_active_count(store, agent_id) == 0 end, 5_000)
  end

  test "security regression: transition-error propagation and closed launch allowlist" do
    # Transition failure surfaces as error atoms (not silent :ok).
    assert {:error, :not_found} =
             IntentCore.begin_settling(%{}, "agent_missing", "rai_x", {:error, :x})

    assert {:error, :owner_barrier_outstanding} =
             IntentCore.settle(
               %{
                 "agent_t" => %{
                   intent_id: "rai_1",
                   target_agent_id: "agent_t",
                   kind: :ordinary_start,
                   fingerprint: "fp_aaa",
                   phase: :settling,
                   owner_pid: self(),
                   worker_pid: nil,
                   terminal: {:error, :t},
                   retire_barrier: :await_owner_down
                 }
               },
               "agent_t",
               "rai_1",
               {:error, :bypass}
             )

    # Closed launch retry allowlist — not every start_child error.
    assert IntentCore.retryable_launch_failure?(:store_restart)
    assert IntentCore.retryable_launch_failure?(:max_children)
    assert IntentCore.retryable_launch_failure?(:timeout)
    refute IntentCore.retryable_launch_failure?(:already_started)
    refute IntentCore.retryable_launch_failure?(:temporary)
    refute IntentCore.retryable_launch_failure?({:task_supervisor_transient, :already_started})
    refute IntentCore.retryable_launch_failure?({:launch_failed, :max_children})

    assert IntentCore.classify_start_child_error(:max_children) == :max_children
    assert IntentCore.classify_start_child_error({:already_started, self()}) == :already_started
    assert IntentCore.redact_error_reason(String.duplicate("z", 200)) |> byte_size() <= 64
  end

  test "security regression: stale monitored owner DOWN does not retire rebound intent", %{
    store: store
  } do
    {agent_id, fp, _kw, _parent} = start_held_admit(store)
    {owner_pid, intent_id, ^fp} = await_exact_live_owner(agent_id, fp)
    worker_pid = await_bound_worker(store, agent_id)

    store_pid = Process.whereis(store)
    assert is_pid(store_pid)

    # Snapshot mon entry for the exact live owner (checkpoint :sys boundary).
    %{runtime_admission_owner_monitors: mons} = :sys.get_state(store_pid)

    found =
      Enum.find(mons, fn {_m, {id, t, p}} ->
        id == intent_id and t == agent_id and p == owner_pid
      end)

    assert is_tuple(found)

    # Simulate a rebound: intent now points at a different owner_pid while the
    # old monitor DOWN is still deliverable. Shell must ignore stale DOWN.
    fake_rebound = spawn(fn -> Process.sleep(60_000) end)

    :sys.replace_state(store_pid, fn st ->
      case get_in(st, [:runtime_admission_intents, agent_id]) do
        %{intent_id: ^intent_id} = intent ->
          put_in(st, [:runtime_admission_intents, agent_id], %{intent | owner_pid: fake_rebound})

        _ ->
          st
      end
    end)

    # Authentic DOWN for the *old* monitored owner must not retire rebound intent.
    Process.exit(owner_pid, :kill)
    await_until(fn -> not Process.alive?(owner_pid) end, 2_000)
    Process.sleep(80)

    intent_after = store_intent(store, agent_id)
    assert is_map(intent_after)
    assert intent_after.intent_id == intent_id
    assert intent_after.owner_pid == fake_rebound
    assert intent_after.phase not in [:terminal]
    assert fence_active_count(store, agent_id) >= 1
    refute_receive {:admit, _}, 100

    # Suite isolation: reply waiters and clear volatile intent (test-only).
    if Process.alive?(worker_pid), do: Process.exit(worker_pid, :kill)
    if Process.alive?(fake_rebound), do: Process.exit(fake_rebound, :kill)

    :sys.replace_state(store_pid, fn st ->
      waiters = get_in(st, [:runtime_admission_waiters, intent_id]) || []
      Enum.each(waiters, fn from -> GenServer.reply(from, {:error, :test_cleanup}) end)

      st
      |> update_in([:runtime_admission_intents], &Map.delete(&1, agent_id))
      |> update_in([:runtime_admission_by_id], &Map.delete(&1, intent_id))
      |> update_in([:runtime_admission_waiters], &Map.delete(&1, intent_id))
    end)

    _ = flush_admit()
  end

  # ── helpers (checkpoint-existing public/OTP boundaries only) ───────

  defp start_held_admit(store) do
    agent_id = "agent_live#{System.unique_integer([:positive])}"
    assert {:ok, %{fingerprint: fp, keyword: kw}} = Opts.project([])
    test = self()

    spawn(fn ->
      send(
        test,
        {:admit,
         TaskStore.admit_ordinary_runtime_start(agent_id, fp, kw, name: store, timeout: 60_000)}
      )
    end)

    {agent_id, fp, kw, test}
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

  defp store_intent(store, agent_id) do
    case :sys.get_state(Process.whereis(store)) do
      %{runtime_admission_intents: intents} -> Map.get(intents, agent_id)
      _ -> nil
    end
  end

  defp fence_active_count(store, agent_id) do
    op = "op_probe_#{System.unique_integer([:positive])}"

    case TaskStore.install_target_fence(agent_id, op, name: store) do
      {:ok, %{active_count: n}} -> n
      _ -> -1
    end
  end

  # Exact worker release — Application env change does NOT unblock an already
  # entered receive; send the checkpoint-existing hold message to the PID.
  defp release_worker_hold(worker_pid) when is_pid(worker_pid) do
    send(worker_pid, @release_hold)
    :ok
  end

  defp worker_in_gen_call?(pid) when is_pid(pid) do
    info = Process.info(pid, [:current_function, :current_stacktrace, :status]) || []
    fun = Keyword.get(info, :current_function)
    frames = Keyword.get(info, :current_stacktrace, [])

    match?({GenServer, :call, _}, fun) or match?({:gen, :do_call, _}, fun) or
      match?({:gen_server, :call, _}, fun) or
      Enum.any?(List.wrap(frames), fn
        {mod, fun_name, _arity, _}
        when mod in [GenServer, :gen_server, :gen] and fun_name in [:call, :do_call] ->
          true

        {mod, fun_name, _arity}
        when mod in [GenServer, :gen_server, :gen] and fun_name in [:call, :do_call] ->
          true

        _ ->
          false
      end)
  rescue
    _ -> false
  end

  defp settlement_waiter_reply({:applied, pid}) when is_pid(pid), do: {:ok, pid}
  defp settlement_waiter_reply({:error, reason}), do: {:error, reason}
  defp settlement_waiter_reply({:conflict, reason}), do: {:error, {:conflict, reason}}
  defp settlement_waiter_reply(other), do: {:error, other}

  defp flush_admit do
    receive do
      {:admit, result} -> result
    after
      15_000 -> :timeout
    end
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

  defp unique_name(prefix), do: :"#{prefix}_#{System.unique_integer([:positive])}"
end
