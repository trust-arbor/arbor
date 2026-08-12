defmodule Arbor.Agent.RuntimeAdmission.LauncherRetryAuthenticationSecurityRegressionTest do
  @moduledoc """
  Security regression F-574: authenticate runtime-admission owner launcher,
  launch bind, adopt, and IntentOwner try_adopt retry protocol.

  Passes on the F-574 candidate. On immediate parent 7ddb20943 the same
  assertions fail behaviorally on old authorization (plain launch-fail
  terminalizes; foreign exact-triple adopt succeeds; plain try_adopt drives
  TaskStore adopt) rather than compile/harness failure.
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
      name: store,
      task_supervisor: task_sup,
      runtime_admission_supervisor: ra_sup,
      runtime_admission_force_ready: true,
      fence_force_ready: true,
      recovery_force_ready: true
    })

    Application.put_env(:arbor_agent, :runtime_admission_test_hold, %{timeout_ms: 30_000})
    on_exit(fn -> Application.delete_env(:arbor_agent, :runtime_admission_test_hold) end)

    %{store: store, ra_sup: ra_sup, task_sup: task_sup}
  end

  test "security regression S1: foreign exact-triple cannot adopt before genuine launcher binding",
       %{store: store} do
    agent_id = "agent_f574a#{System.unique_integer([:positive])}"
    assert {:ok, %{fingerprint: fp, keyword: kw}} = Opts.project([])

    spawn_admit(store, agent_id, fp, kw, :admit)

    {intent_id, _phase} =
      await_until(
        fn ->
          case store_intent(store, agent_id) do
            %{intent_id: id, fingerprint: ^fp, phase: p}
            when p in [:owner_launching, :owner_live, :worker_running] ->
              {id, p}

            _ ->
              false
          end
        end,
        5_000
      )

    assert is_binary(intent_id)

    foreign_result =
      TaskStore.adopt_runtime_admission_owner(agent_id, intent_id, fp, name: store)

    assert foreign_result in [
             {:error, :not_owner},
             {:error, :owner_not_bound},
             {:error, :conflict}
           ]

    intent_after = store_intent(store, agent_id)
    assert is_map(intent_after)
    assert intent_after.intent_id == intent_id

    if is_pid(intent_after.owner_pid) do
      assert intent_after.owner_pid != self()
    end

    {owner_pid, ^intent_id, ^fp} = await_exact_live_owner(agent_id, fp)
    assert Process.alive?(owner_pid)

    worker = await_bound_worker(store, agent_id)
    release_worker_hold(worker)
    assert_receive {:admit, _}, 15_000
  end

  test "security regression S2: plain/stale launch-failure cannot terminalize live intent",
       %{store: store} do
    agent_id = "agent_f574b#{System.unique_integer([:positive])}"
    assert {:ok, %{fingerprint: fp, keyword: kw}} = Opts.project([])
    spawn_admit(store, agent_id, fp, kw, :admit)

    {owner_pid, intent_id, ^fp} = await_exact_live_owner(agent_id, fp)
    _worker = await_bound_worker(store, agent_id)
    store_pid = Process.whereis(store)
    assert is_pid(store_pid)

    send(store_pid, {:runtime_admission_owner_launch_failed, intent_id, :forged})
    send(store_pid, {:runtime_admission_owner_launch_failed, make_ref(), intent_id, :stale})
    send(store_pid, {:runtime_admission_owner_launch_failed, make_ref(), intent_id, :random})

    Process.sleep(50)

    intent = store_intent(store, agent_id)
    assert is_map(intent)
    assert intent.intent_id == intent_id
    assert intent.phase in [:owner_launching, :owner_live, :worker_running]
    refute_receive {:admit, _}, 150

    worker = await_bound_worker(store, agent_id)
    release_worker_hold(worker)
    assert_receive {:admit, _}, 15_000
    assert is_pid(owner_pid)
  end

  test "security regression S3: bare/stale try_adopt cannot call TaskStore adopt",
       %{store: store} do
    agent_id = "agent_f574c#{System.unique_integer([:positive])}"
    assert {:ok, %{fingerprint: fp, keyword: kw}} = Opts.project([])
    spawn_admit(store, agent_id, fp, kw, :admit)

    {owner_pid, intent_id, ^fp} = await_exact_live_owner(agent_id, fp)
    _worker = await_bound_worker(store, agent_id)
    store_pid = Process.whereis(store)
    assert is_pid(store_pid)

    # Suspend store so any forged adopt call is observable in the mailbox.
    :sys.suspend(store_pid)

    try do
      Enum.each(1..40, fn _ ->
        send(owner_pid, :try_adopt)
        send(owner_pid, {:try_adopt, make_ref()})
      end)

      Process.sleep(80)

      assert Process.alive?(owner_pid)

      adopt_calls =
        store_pid
        |> mailbox_messages()
        |> Enum.filter(fn
          {:"$gen_call", _, {:adopt_runtime_admission_owner, ^agent_id, ^intent_id, ^fp}} ->
            true

          _ ->
            false
        end)

      # Candidate: bare/stale try_adopt is inert. Parent 7ddb20943 queues a call.
      assert adopt_calls == []
    after
      if Process.alive?(store_pid), do: :sys.resume(store_pid)
    end

    assert is_map(store_intent(store, agent_id))
    refute_receive {:admit, _}, 100

    worker = await_bound_worker(store, agent_id)
    release_worker_hold(worker)
    assert_receive {:admit, _}, 15_000
  end

  test "positive: genuine monitored launcher success binds owner; same-target reuse",
       %{store: store} do
    agent_id = "agent_f574p#{System.unique_integer([:positive])}"
    assert {:ok, %{fingerprint: fp, keyword: kw}} = Opts.project([])
    spawn_admit(store, agent_id, fp, kw, :admit_first)

    {owner_pid, intent_id, ^fp} = await_exact_live_owner(agent_id, fp)
    intent = store_intent(store, agent_id)
    assert intent.owner_pid == owner_pid
    assert Map.get(intent, :launch_ref) in [nil]

    worker = await_bound_worker(store, agent_id)
    release_worker_hold(worker)
    first = assert_receive_admit(:admit_first, 15_000)
    assert first == {:error, :not_found}

    await_until(fn -> is_nil(store_intent(store, agent_id)) end, 5_000)

    spawn_admit(store, agent_id, fp, kw, :admit_second)
    {_owner2, intent_id2, ^fp} = await_exact_live_owner(agent_id, fp)
    refute intent_id2 == intent_id
    worker2 = await_bound_worker(store, agent_id)
    release_worker_hold(worker2)
    second = assert_receive_admit(:admit_second, 15_000)
    assert second == {:error, :not_found}
  end

  test "positive: bind-before fail is stale; fail-before-bind consumes the attempt",
       %{store: store} do
    agent_id = "agent_f574q#{System.unique_integer([:positive])}"
    assert {:ok, %{fingerprint: fp, keyword: kw}} = Opts.project([])
    spawn_admit(store, agent_id, fp, kw, :admit)

    # Bind-before: live owner already bound; forged/stale fail inert.
    {_owner, intent_id, ^fp} = await_exact_live_owner(agent_id, fp)
    store_pid = Process.whereis(store)

    send(store_pid, {:runtime_admission_owner_launch_failed, make_ref(), intent_id, :late})
    Process.sleep(30)
    assert is_map(store_intent(store, agent_id))
    refute_receive {:admit, _}, 80

    worker = await_bound_worker(store, agent_id)
    release_worker_hold(worker)
    assert_receive {:admit, _}, 15_000

    # Fail-before-bind: planted attempt and joined waiter settle once.
    agent2 = "agent_f574r#{System.unique_integer([:positive])}"
    assert {:ok, %{fingerprint: fp2, keyword: kw2}} = Opts.project([])
    intent2 = "rai_fail#{System.unique_integer([:positive])}"
    launch_ref = make_ref()
    store_pid = Process.whereis(store)

    :sys.replace_state(store_pid, fn st ->
      plant_launching_intent(st, agent2, intent2, fp2, launch_ref, 1, kw2)
    end)

    # Park a waiter so terminal is observable.
    test = self()

    spawn(fn ->
      send(
        test,
        {:waiter2,
         TaskStore.admit_ordinary_runtime_start(agent2, fp2, kw2, name: store, timeout: 5_000)}
      )
    end)

    await_until(
      fn ->
        case :sys.get_state(store_pid) do
          %{runtime_admission_waiters: waiters} -> Map.get(waiters, intent2, []) != []
          _ -> false
        end
      end,
      2_000
    )

    # The joined waiter observes the authenticated failure exactly once.
    send(
      store_pid,
      {:runtime_admission_owner_launch_failed, launch_ref, intent2, :permanent_fail}
    )

    await_until(
      fn ->
        case store_intent(store, agent2) do
          nil -> true
          %{launch_ref: nil, owner_pid: nil} -> true
          %{phase: :terminal} -> true
          _ -> false
        end
      end,
      3_000
    )

    assert {:error, _} = flush_tag(:waiter2)
  end

  test "positive: authenticated fail then DOWN orderings and stale prior ref",
       %{store: store} do
    agent_id = "agent_f574s#{System.unique_integer([:positive])}"
    assert {:ok, %{fingerprint: fp, keyword: kw}} = Opts.project([])
    intent_id = "rai_ord#{System.unique_integer([:positive])}"
    launch_ref = make_ref()
    store_pid = Process.whereis(store)

    # Plant unbound launching attempt with a fake launcher mon entry.
    fake_launcher = spawn(fn -> Process.sleep(60_000) end)
    mon = Process.monitor(fake_launcher)

    :sys.replace_state(store_pid, fn st ->
      st = plant_launching_intent(st, agent_id, intent_id, fp, launch_ref, 1, kw)

      put_in(
        st,
        [:runtime_admission_launcher_monitors, mon],
        {intent_id, agent_id, launch_ref, fake_launcher}
      )
    end)

    # Fail first (nonretryable) — consumes attempt.
    send(
      store_pid,
      {:runtime_admission_owner_launch_failed, launch_ref, intent_id, :permanent_shape}
    )

    await_until(
      fn -> is_nil(store_intent(store, agent_id)) or terminal_or_cleared?(store, agent_id) end,
      3_000
    )

    # Stale prior ref and an exact late DOWN are inert.
    send(
      store_pid,
      {:runtime_admission_owner_launch_failed, launch_ref, intent_id, :stale_prior}
    )

    send(store_pid, {:DOWN, mon, :process, fake_launcher, :killed})
    Process.sleep(50)
    refute Process.whereis(store) == nil

    # DOWN-first consumes the attempt and launches one retry. A later failure
    # carrying the old ref cannot drive another transition.
    agent2 = "agent_f574u#{System.unique_integer([:positive])}"
    intent2 = "rai_down#{System.unique_integer([:positive])}"
    ref2 = make_ref()
    mon2 = make_ref()
    dead_launcher = spawn(fn -> :ok end)

    :sys.replace_state(store_pid, fn st ->
      st = plant_launching_intent(st, agent2, intent2, fp, ref2, 1, kw)

      put_in(
        st,
        [:runtime_admission_launcher_monitors, mon2],
        {intent2, agent2, ref2, dead_launcher}
      )
    end)

    send(store_pid, {:DOWN, mon2, :process, dead_launcher, :killed})

    retried =
      await_until(
        fn ->
          case store_intent(store, agent2) do
            %{launcher_attempt_index: 2} = intent -> intent
            _ -> false
          end
        end,
        3_000
      )

    send(store_pid, {:runtime_admission_owner_launch_failed, ref2, intent2, :stale_prior})
    Process.sleep(40)
    assert store_intent(store, agent2).launcher_attempt_index == retried.launcher_attempt_index
  end

  test "positive: exactly-one pre-owner launcher retry then exhaustion",
       %{store: store} do
    agent_id = "agent_f574t#{System.unique_integer([:positive])}"
    assert {:ok, %{fingerprint: fp, keyword: kw}} = Opts.project([])
    intent_id = "rai_retry#{System.unique_integer([:positive])}"
    launch_ref = make_ref()
    store_pid = Process.whereis(store)

    :sys.replace_state(store_pid, fn st ->
      plant_launching_intent(st, agent_id, intent_id, fp, launch_ref, 1, kw)
    end)

    # Retryable failure schedules exactly one next attempt.
    send(
      store_pid,
      {:runtime_admission_owner_launch_failed, launch_ref, intent_id, :max_children}
    )

    intent2 =
      await_until(
        fn ->
          case store_intent(store, agent_id) do
            %{launcher_attempt_index: 2} = i -> i
            _ -> false
          end
        end,
        3_000
      )

    assert intent2.launcher_attempt_index == 2
    # Either still launching (new ref) or already bind-consumed by genuine helper.
    assert Map.get(intent2, :launch_ref) != launch_ref

    # Stale prior ref cannot drive another transition / extra attempt.
    before_index = intent2.launcher_attempt_index

    send(
      store_pid,
      {:runtime_admission_owner_launch_failed, launch_ref, intent_id, :max_children}
    )

    Process.sleep(40)
    intent3 = store_intent(store, agent_id)
    assert is_map(intent3)
    assert intent3.launcher_attempt_index == before_index

    # Exhaustion uses a separate, consistent unbound intent. A retryable
    # failure at the max attempt must release its joined waiter.
    exhaust_agent = "agent_f574v#{System.unique_integer([:positive])}"
    exhaust_intent = "rai_exhaust#{System.unique_integer([:positive])}"
    max_ref = make_ref()

    :sys.replace_state(store_pid, fn st ->
      plant_launching_intent(st, exhaust_agent, exhaust_intent, fp, max_ref, 8, kw)
    end)

    test = self()

    spawn(fn ->
      send(
        test,
        {:exhaust_waiter,
         TaskStore.admit_ordinary_runtime_start(
           exhaust_agent,
           fp,
           kw,
           name: store,
           timeout: 5_000
         )}
      )
    end)

    await_until(
      fn ->
        case :sys.get_state(store_pid) do
          %{runtime_admission_waiters: waiters} ->
            Map.get(waiters, exhaust_intent, []) != []

          _ ->
            false
        end
      end,
      2_000
    )

    send(
      store_pid,
      {:runtime_admission_owner_launch_failed, max_ref, exhaust_intent, :max_children}
    )

    assert_receive {:exhaust_waiter, {:error, :launch_retry_exhausted}}, 3_000
    await_until(fn -> is_nil(store_intent(store, exhaust_agent)) end, 3_000)
  end

  test "security regression: rebind requires child_pid; mismatch fails closed" do
    other = spawn(fn -> :ok end)
    fp = "fp_" <> String.duplicate("a", 16)

    assert {:error, :invalid_snapshot} =
             IntentCore.rebind_owners(%{}, [
               %{
                 intent_id: "rai_1",
                 target_agent_id: "agent_t1",
                 fingerprint: fp,
                 owner_pid: self()
               }
             ])

    assert {:error, :invalid_snapshot} =
             IntentCore.rebind_owners(%{}, [
               %{
                 intent_id: "rai_1",
                 target_agent_id: "agent_t1",
                 fingerprint: fp,
                 child_pid: self(),
                 owner_pid: other
               }
             ])

    assert {:ok, intents} =
             IntentCore.rebind_owners(%{}, [
               %{
                 intent_id: "rai_1",
                 target_agent_id: "agent_t1",
                 fingerprint: fp,
                 child_pid: self(),
                 owner_pid: self()
               }
             ])

    assert intents["agent_t1"].owner_pid == self()
  end

  # ── helpers ───────────────────────────────────────────────────────

  defp plant_launching_intent(st, agent_id, intent_id, fp, launch_ref, attempt, kw) do
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
      launcher_attempt_index: attempt
    }

    st
    |> Map.put_new(:runtime_admission_pending_opts, %{})
    |> Map.put_new(:runtime_admission_launcher_monitors, %{})
    |> put_in([:runtime_admission_intents, agent_id], intent)
    |> put_in([:runtime_admission_by_id, intent_id], agent_id)
    |> put_in([:runtime_admission_pending_opts, intent_id], kw)
  end

  defp terminal_or_cleared?(store, agent_id) do
    case store_intent(store, agent_id) do
      nil -> true
      %{phase: :terminal} -> true
      %{owner_pid: nil, launch_ref: nil} -> true
      _ -> false
    end
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

    :ok
  end

  defp assert_receive_admit(tag, timeout) do
    receive do
      {^tag, result} -> result
    after
      timeout -> flunk("timed out waiting for admit tag #{inspect(tag)}")
    end
  end

  defp flush_tag(tag) do
    receive do
      {^tag, result} -> result
    after
      200 -> :timeout
    end
  end

  defp await_exact_live_owner(agent_id, expected_fp) do
    await_until(
      fn ->
        case Registry.lookup(@registry, {:runtime_admission_owner, agent_id}) do
          [{pid, _}] when is_pid(pid) ->
            case IntentOwner.snapshot(pid) do
              {:ok,
               %{
                 target_agent_id: ^agent_id,
                 fingerprint: ^expected_fp,
                 intent_id: intent_id
               }}
              when is_binary(intent_id) ->
                {pid, intent_id, expected_fp}

              _ ->
                false
            end

          _ ->
            false
        end
      end,
      5_000
    )
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

  defp mailbox_messages(pid) when is_pid(pid) do
    case Process.info(pid, :messages) do
      {:messages, msgs} -> msgs
      _ -> []
    end
  end

  defp release_worker_hold(worker_pid) when is_pid(worker_pid) do
    send(worker_pid, @release_hold)
    :ok
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
