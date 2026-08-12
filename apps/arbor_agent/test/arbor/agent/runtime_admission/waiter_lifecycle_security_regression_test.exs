defmodule Arbor.Agent.RuntimeAdmission.WaiterLifecycleSecurityRegressionTest do
  @moduledoc """
  Phase 4C C3C1a0 F-575 waiter lifecycle security regressions.

  Uses only parent-existing public APIs and OTP test support so the file
  compiles on immediate parent 4b25a0135 and fails there *behaviorally*
  (unbounded waiters, retained dead waiters, or untyped transport timeout),
  not via compile/harness failure.

  Does not alias WaiterCore or any candidate-only modules.
  """

  use ExUnit.Case, async: false

  @moduletag :security_regression
  @moduletag :fast

  alias Arbor.Agent.Orchestration.{TaskControlRecoveryMemory, TaskStore}
  alias Arbor.Agent.RuntimeAdmission.Opts
  alias Arbor.Agent.RuntimeAdmission.OrdinaryStart
  alias Arbor.Agent.RuntimeAdmission.Supervisor, as: RASupervisor

  @registry Arbor.Agent.RuntimeAdmissionRegistry
  @default_cap 64

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

  test "security regression: 65th exact-fingerprint waiter rejected at default cap", %{
    store: store
  } do
    agent_id = "agent_cap#{System.unique_integer([:positive])}"
    assert {:ok, %{fingerprint: fp, keyword: kw}} = Opts.project([])

    parent = self()

    # First waiter admits and holds the operation open.
    first =
      spawn(fn ->
        send(
          parent,
          {:first,
           TaskStore.admit_ordinary_runtime_start(agent_id, fp, kw, name: store, timeout: 60_000)}
        )
      end)

    await_until(fn -> waiter_count(store, agent_id) >= 1 end, 5_000)
    intent_before = store_intent(store, agent_id)
    assert is_map(intent_before)
    intent_id = intent_before.intent_id
    worker = await_bound_worker(store, agent_id)

    # Fill remaining slots to the default production cap (64).
    joiners =
      for i <- 2..@default_cap do
        spawn(fn ->
          send(
            parent,
            {{:joiner, i},
             TaskStore.admit_ordinary_runtime_start(agent_id, fp, kw,
               name: store,
               timeout: 60_000
             )}
          )
        end)
      end

    await_until(fn -> waiter_count(store, agent_id) >= @default_cap end, 10_000)
    assert waiter_count(store, agent_id) == @default_cap

    # 65th exact-fp join must be rejected without allocating another waiter or
    # disturbing the live operation. On parent this parks (unbounded) or lacks
    # the typed full error — behavioral fail.
    overflow =
      TaskStore.admit_ordinary_runtime_start(agent_id, fp, kw, name: store, timeout: 2_000)

    assert overflow == {:error, :runtime_admission_waiters_full}
    assert waiter_count(store, agent_id) == @default_cap

    intent_after = store_intent(store, agent_id)
    assert is_map(intent_after)
    assert intent_after.intent_id == intent_id
    assert intent_after.worker_pid == worker

    # Cleanup: release hold so waiters can settle (or kill waiters).
    release_any_worker(store, agent_id)
    _ = Process.exit(first, :kill)
    Enum.each(joiners, &Process.exit(&1, :kill))
    Process.sleep(50)
  end

  test "security regression: dead blocked caller releases one slot for replacement join", %{
    store: store
  } do
    # Lower cap via trusted store init is candidate-only; use default cap but
    # fill only a small cohort and prove death frees capacity by counting.
    agent_id = "agent_dead#{System.unique_integer([:positive])}"
    assert {:ok, %{fingerprint: fp, keyword: kw}} = Opts.project([])
    parent = self()

    victims =
      for i <- 1..3 do
        spawn(fn ->
          send(
            parent,
            {{:v, i},
             TaskStore.admit_ordinary_runtime_start(agent_id, fp, kw,
               name: store,
               timeout: 60_000
             )}
          )
        end)
      end

    await_until(fn -> waiter_count(store, agent_id) >= 3 end, 5_000)
    assert waiter_count(store, agent_id) == 3
    intent_id = store_intent(store, agent_id).intent_id

    victim = hd(victims)
    ref = Process.monitor(victim)
    Process.exit(victim, :kill)
    assert_receive {:DOWN, ^ref, :process, ^victim, _}, 2_000

    await_until(fn -> waiter_count(store, agent_id) == 2 end, 3_000)
    assert waiter_count(store, agent_id) == 2

    # Intent must remain live and unchanged (no cancel on last-but-not-final death).
    intent = store_intent(store, agent_id)
    assert is_map(intent)
    assert intent.intent_id == intent_id

    # Replacement exact-fp join reuses the freed slot.
    spawn(fn ->
      send(
        parent,
        {:replacement,
         TaskStore.admit_ordinary_runtime_start(agent_id, fp, kw, name: store, timeout: 60_000)}
      )
    end)

    await_until(fn -> waiter_count(store, agent_id) == 3 end, 3_000)
    assert waiter_count(store, agent_id) == 3
    assert store_intent(store, agent_id).intent_id == intent_id

    Enum.each(tl(victims), &Process.exit(&1, :kill))
    release_any_worker(store, agent_id)
  end

  test "security regression: short waiter deadline returns typed timeout not call exit", %{
    store: store
  } do
    agent_id = "agent_ddl#{System.unique_integer([:positive])}"
    assert {:ok, %{fingerprint: fp, keyword: kw}} = Opts.project([])
    parent = self()

    # Hold first admit open so a second waiter can time out while op lives.
    spawn(fn ->
      send(
        parent,
        {:holder,
         TaskStore.admit_ordinary_runtime_start(agent_id, fp, kw, name: store, timeout: 60_000)}
      )
    end)

    await_until(fn -> waiter_count(store, agent_id) >= 1 end, 5_000)

    # Short store-owned deadline; outer call has grace so typed reply wins.
    result =
      TaskStore.admit_ordinary_runtime_start(agent_id, fp, kw, name: store, timeout: 80)

    assert result == {:error, :runtime_admission_wait_timeout}

    # Live operation undisturbed; holder still parked.
    assert is_map(store_intent(store, agent_id))
    count_after_timeout = waiter_count(store, agent_id)
    assert count_after_timeout >= 1

    # Replacement exact-fp waiter can join after timed-out waiter released its slot.
    spawn(fn ->
      send(
        parent,
        {:replacement_after_timeout,
         TaskStore.admit_ordinary_runtime_start(agent_id, fp, kw, name: store, timeout: 60_000)}
      )
    end)

    await_until(fn -> waiter_count(store, agent_id) > count_after_timeout end, 3_000)

    # Forged/stale deadline tokens are inert and cannot affect the replacement.
    store_pid = Process.whereis(store) || store
    send(store_pid, {:runtime_admission_waiter_timeout, make_ref()})
    send(store_pid, {:runtime_admission_waiter_timeout, make_ref()})
    Process.sleep(30)
    assert is_map(store_intent(store, agent_id))
    assert waiter_count(store, agent_id) > count_after_timeout
    refute_receive {:replacement_after_timeout, _}, 50

    release_any_worker(store, agent_id)
  end

  test "security regression: settlement-before-DOWN first-wins (late DOWN inert)", %{
    store: store
  } do
    agent_id = "agent_sbd#{System.unique_integer([:positive])}"
    assert {:ok, %{fingerprint: fp, keyword: kw}} = Opts.project([])
    parent = self()

    waiter =
      spawn(fn ->
        send(
          parent,
          {:sbd_waiter,
           TaskStore.admit_ordinary_runtime_start(agent_id, fp, kw, name: store, timeout: 60_000)}
        )
      end)

    await_until(fn -> waiter_count(store, agent_id) >= 1 end, 5_000)
    worker = await_bound_worker(store, agent_id)

    # Settlement first: release hold → worker completes → waiter replied once.
    release_worker_hold(worker)
    assert_receive {:sbd_waiter, terminal}, 15_000
    assert match?({:ok, _}, terminal) or match?({:error, _}, terminal)
    await_until(fn -> store_intent(store, agent_id) == nil end, 5_000)
    assert waiter_count(store, agent_id) == 0
    refute_receive {:sbd_waiter, _}, 50

    # Late authentic-looking DOWN of the already-settled waiter is inert.
    if Process.alive?(waiter), do: Process.exit(waiter, :kill)
    Process.sleep(30)
    assert store_intent(store, agent_id) == nil
    assert waiter_count(store, agent_id) == 0
  end

  test "security regression: DOWN-before-settlement first-wins (remaining waiter settles once)",
       %{store: store} do
    agent_id = "agent_dbs#{System.unique_integer([:positive])}"
    assert {:ok, %{fingerprint: fp, keyword: kw}} = Opts.project([])
    parent = self()

    dead =
      spawn(fn ->
        send(
          parent,
          {:dbs_dead,
           TaskStore.admit_ordinary_runtime_start(agent_id, fp, kw, name: store, timeout: 60_000)}
        )
      end)

    survivor =
      spawn(fn ->
        send(
          parent,
          {:dbs_live,
           TaskStore.admit_ordinary_runtime_start(agent_id, fp, kw, name: store, timeout: 60_000)}
        )
      end)

    await_until(fn -> waiter_count(store, agent_id) >= 2 end, 5_000)
    intent_id = store_intent(store, agent_id).intent_id
    worker = await_bound_worker(store, agent_id)

    # DOWN first: kill one waiter; intent stays live; capacity drops by one.
    ref = Process.monitor(dead)
    Process.exit(dead, :kill)
    assert_receive {:DOWN, ^ref, :process, ^dead, _}, 2_000
    await_until(fn -> waiter_count(store, agent_id) == 1 end, 3_000)
    assert store_intent(store, agent_id).intent_id == intent_id
    # Dead caller must not receive a settlement reply.
    refute_receive {:dbs_dead, _}, 50

    # Settlement second: only the still-live waiter is replied exactly once with
    # a terminal outcome; intent then fully retires.
    release_worker_hold(worker)
    assert_receive {:dbs_live, terminal}, 15_000
    assert match?({:ok, _}, terminal) or match?({:error, _}, terminal)
    refute_receive {:dbs_live, _}, 50
    refute_receive {:dbs_dead, _}, 50
    await_until(fn -> store_intent(store, agent_id) == nil end, 5_000)
    assert waiter_count(store, agent_id) == 0

    # Survivor process may already have exited after reply; ensure no crash path.
    if Process.alive?(survivor), do: Process.exit(survivor, :kill)
    Process.sleep(20)
  end

  test "security regression: deadline-before-settlement leaves op live; settlement-before-deadline inert late token",
       %{store: store} do
    agent_id = "agent_ddl2#{System.unique_integer([:positive])}"
    assert {:ok, %{fingerprint: fp, keyword: kw}} = Opts.project([])
    parent = self()

    spawn(fn ->
      send(
        parent,
        {:hold2,
         TaskStore.admit_ordinary_runtime_start(agent_id, fp, kw, name: store, timeout: 60_000)}
      )
    end)

    await_until(fn -> waiter_count(store, agent_id) >= 1 end, 5_000)

    # Deadline before settlement: timed-out join leaves holder + op live.
    assert {:error, :runtime_admission_wait_timeout} =
             TaskStore.admit_ordinary_runtime_start(agent_id, fp, kw, name: store, timeout: 50)

    assert is_map(store_intent(store, agent_id))
    assert waiter_count(store, agent_id) >= 1

    worker = await_bound_worker(store, agent_id)
    release_worker_hold(worker)
    assert_receive {:hold2, _}, 15_000
    await_until(fn -> store_intent(store, agent_id) == nil end, 5_000)

    # Settlement-before-deadline: late forged tokens after settle are inert.
    store_pid = Process.whereis(store) || store
    send(store_pid, {:runtime_admission_waiter_timeout, make_ref()})
    send(store_pid, {:runtime_admission_waiter_timeout, make_ref()})
    Process.sleep(30)
    assert store_intent(store, agent_id) == nil
  end

  test "security regression: forged and duplicate deadline messages are inert", %{store: store} do
    agent_id = "agent_forge#{System.unique_integer([:positive])}"
    assert {:ok, %{fingerprint: fp, keyword: kw}} = Opts.project([])
    parent = self()

    spawn(fn ->
      send(
        parent,
        {:f,
         TaskStore.admit_ordinary_runtime_start(agent_id, fp, kw, name: store, timeout: 60_000)}
      )
    end)

    await_until(fn -> waiter_count(store, agent_id) >= 1 end, 5_000)
    count = waiter_count(store, agent_id)
    intent_id = store_intent(store, agent_id).intent_id

    store_pid = Process.whereis(store) || store
    send(store_pid, {:runtime_admission_waiter_timeout, make_ref()})
    send(store_pid, {:runtime_admission_waiter_timeout, make_ref()})
    # Random DOWN-shaped mon that is not store-owned.
    send(store_pid, {:DOWN, make_ref(), :process, self(), :kill})
    Process.sleep(50)

    assert waiter_count(store, agent_id) == count
    assert store_intent(store, agent_id).intent_id == intent_id

    release_any_worker(store, agent_id)
  end

  test "security regression: hot-state waiter migration persists before DOWN classification", %{
    store: store
  } do
    tag = make_ref()
    test_pid = self()

    :sys.replace_state(store, fn state ->
      state
      |> Map.put(:runtime_admission_waiter_schema_v, 0)
      |> Map.put(:runtime_admission_waiters, %{"rai_legacy" => [{test_pid, tag}]})
      |> Map.put(:runtime_admission_waiter_by_mon, %{})
      |> Map.put(:runtime_admission_waiter_by_deadline, %{})
    end)

    store_pid = Process.whereis(store)
    send(store_pid, {:DOWN, make_ref(), :process, self(), :normal})

    assert_receive {^tag, {:error, :runtime_admission_wait_timeout}}, 1_000

    state = :sys.get_state(store)
    assert Map.get(state, :runtime_admission_waiter_schema_v) == 1
    assert Map.get(state, :runtime_admission_waiters) == %{}

    send(store_pid, {:DOWN, make_ref(), :process, self(), :normal})
    refute_receive {^tag, _}, 100
  end

  test "security regression: uncleanable hot-state waiter corruption restarts the store", %{
    store: store
  } do
    old_pid = Process.whereis(store)
    old_mon = Process.monitor(old_pid)

    :sys.replace_state(store, fn state ->
      state
      |> Map.put(:runtime_admission_waiter_schema_v, 0)
      |> Map.put(:runtime_admission_waiters, %{"rai_corrupt" => %{make_ref() => :opaque}})
      |> Map.put(:runtime_admission_waiter_by_mon, %{})
      |> Map.put(:runtime_admission_waiter_by_deadline, %{})
    end)

    assert catch_exit(GenServer.call(store, :runtime_admission_ready?))
    assert_receive {:DOWN, ^old_mon, :process, ^old_pid, _reason}, 2_000

    await_until(
      fn ->
        new_pid = Process.whereis(store)
        is_pid(new_pid) and new_pid != old_pid
      end,
      5_000
    )

    state = :sys.get_state(store)
    assert Map.get(state, :runtime_admission_waiter_schema_v) == 1
    assert Map.get(state, :runtime_admission_waiters) == %{}
  end

  test "security regression: unknown hot-state waiter schema restarts the store", %{
    store: store
  } do
    old_pid = Process.whereis(store)
    old_mon = Process.monitor(old_pid)

    :sys.replace_state(store, fn state ->
      Map.put(state, :runtime_admission_waiter_schema_v, 2)
    end)

    assert catch_exit(GenServer.call(store, :runtime_admission_ready?))
    assert_receive {:DOWN, ^old_mon, :process, ^old_pid, _reason}, 2_000

    await_until(
      fn ->
        new_pid = Process.whereis(store)
        is_pid(new_pid) and new_pid != old_pid
      end,
      5_000
    )

    assert Map.get(:sys.get_state(store), :runtime_admission_waiter_schema_v) == 1
  end

  test "positive: same-fingerprint coalescing still joins one intent", %{store: store} do
    agent_id = "agent_coal#{System.unique_integer([:positive])}"
    assert {:ok, %{fingerprint: fp, keyword: kw}} = Opts.project([])
    parent = self()

    spawn(fn ->
      send(
        parent,
        {:a,
         TaskStore.admit_ordinary_runtime_start(agent_id, fp, kw, name: store, timeout: 60_000)}
      )
    end)

    await_until(fn -> waiter_count(store, agent_id) >= 1 end, 5_000)
    id1 = store_intent(store, agent_id).intent_id

    spawn(fn ->
      send(
        parent,
        {:b,
         TaskStore.admit_ordinary_runtime_start(agent_id, fp, kw, name: store, timeout: 60_000)}
      )
    end)

    await_until(fn -> waiter_count(store, agent_id) >= 2 end, 5_000)
    assert store_intent(store, agent_id).intent_id == id1

    release_any_worker(store, agent_id)
    assert_receive {:a, _}, 15_000
    assert_receive {:b, _}, 15_000
  end

  test "positive: zero-waiter operation continues after final caller death", %{store: store} do
    agent_id = "agent_zero#{System.unique_integer([:positive])}"
    assert {:ok, %{fingerprint: fp, keyword: kw}} = Opts.project([])
    parent = self()

    waiter =
      spawn(fn ->
        send(
          parent,
          {:z,
           TaskStore.admit_ordinary_runtime_start(agent_id, fp, kw, name: store, timeout: 60_000)}
        )
      end)

    await_until(fn -> waiter_count(store, agent_id) >= 1 end, 5_000)
    intent_id = store_intent(store, agent_id).intent_id
    worker = await_bound_worker(store, agent_id)

    ref = Process.monitor(waiter)
    Process.exit(waiter, :kill)
    assert_receive {:DOWN, ^ref, :process, ^waiter, _}, 2_000

    await_until(fn -> waiter_count(store, agent_id) == 0 end, 3_000)

    # Intent still live — losing final waiter must not cancel/settle.
    intent = store_intent(store, agent_id)
    assert is_map(intent)
    assert intent.intent_id == intent_id

    release_worker_hold(worker)
    await_until(fn -> store_intent(store, agent_id) == nil end, 10_000)
  end

  test "positive: OrdinaryStart typed wait-timeout then same-fingerprint success" do
    # Parent-compatible fake store GenServer (no WaiterCore / candidate modules):
    # first admit shape → typed wait_timeout; rejoin admit → success. Proves
    # OrdinaryStart performs two same-fingerprint admits and returns success.
    # On parent (no rejoin), the client surfaces wait_timeout after one admit.
    agent_id = "agent_os#{System.unique_integer([:positive])}"
    store = unique_name(:os_fake_store)
    success_pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> if Process.alive?(success_pid), do: Process.exit(success_pid, :kill) end)

    start_supervised!(
      {__MODULE__.OrdinaryStartRejoinStore, name: store, success_pid: success_pid},
      id: store
    )

    assert {:ok, ^success_pid} =
             OrdinaryStart.request(agent_id,
               task_store: store,
               timeout_ms: 30_000
             )

    st = :sys.get_state(store)
    assert st.admit_count == 2
    assert st.fingerprints_seen == 1
  end

  test "positive: supervised TaskStore restart loses waiters; OrdinaryStart rejoins", %{
    ra_sup: ra_sup,
    task_sup: task_sup
  } do
    # Use a permanent child with real reconcile enabled. Killing TaskStore must
    # be recovered by its supervisor; the blocked OrdinaryStart owns rejoin.
    agent_id = "agent_rst#{System.unique_integer([:positive])}"
    parent = self()
    store = unique_name(:restart_store)

    {:ok, sup} =
      Supervisor.start_link(
        [
          {TaskStore,
           name: store,
           task_supervisor: task_sup,
           runtime_admission_supervisor: ra_sup,
           runtime_admission_force_ready: false,
           fence_force_ready: true,
           recovery_force_ready: true}
        ],
        strategy: :one_for_one,
        name: unique_name(:restart_sup)
      )

    on_exit(fn ->
      if Process.alive?(sup), do: Supervisor.stop(sup, :normal, 2_000)
    end)

    await_until(fn -> TaskStore.runtime_admission_ready?(name: store) end, 5_000)

    Application.put_env(:arbor_agent, :runtime_admission_test_hold, %{timeout_ms: 30_000})

    spawn(fn ->
      send(
        parent,
        {:restart_result,
         OrdinaryStart.request(agent_id,
           task_store: store,
           timeout_ms: 30_000
         )}
      )
    end)

    await_until(fn -> waiter_count(store, agent_id) >= 1 end, 5_000)
    intent_before = store_intent(store, agent_id)
    intent_id = intent_before.intent_id
    owner_pid = intent_before.owner_pid
    worker_pid = await_bound_worker(store, agent_id)
    old_pid = Process.whereis(store)
    assert is_pid(old_pid)

    ref = Process.monitor(old_pid)
    Process.exit(old_pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^old_pid, _}, 2_000

    # Supervised replacement under the same registered name.
    await_until(
      fn ->
        pid = Process.whereis(store)
        is_pid(pid) and pid != old_pid and TaskStore.runtime_admission_ready?(name: store)
      end,
      5_000
    )

    new_pid = Process.whereis(store)
    assert is_pid(new_pid)
    assert new_pid != old_pid

    # The surviving owner/worker is rebound, and the original caller rejoins
    # the same fingerprint without creating a second operation.
    await_until(fn -> waiter_count(store, agent_id) >= 1 end, 5_000)
    intent_after = store_intent(store, agent_id)
    assert intent_after.intent_id == intent_id
    assert intent_after.owner_pid == owner_pid
    assert intent_after.worker_pid == worker_pid
    assert [{^owner_pid, _}] = Registry.lookup(@registry, {:runtime_admission_owner, agent_id})

    release_worker_hold(worker_pid)
    assert_receive {:restart_result, {:error, :not_found}}, 15_000
  end

  # ── parent-compatible OrdinaryStart rejoin store (no candidate modules) ──

  defmodule OrdinaryStartRejoinStore do
    @moduledoc false
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    @impl true
    def init(opts) do
      {:ok,
       %{
         admit_count: 0,
         fingerprints: MapSet.new(),
         fingerprints_seen: 0,
         success_pid: Keyword.fetch!(opts, :success_pid)
       }}
    end

    @impl true
    def handle_call(:runtime_admission_ready?, _from, state), do: {:reply, true, state}

    # Parent pre-F-575 4-tuple admit shape.
    def handle_call(
          {:admit_ordinary_runtime_start, _target, fingerprint, _validated_opts},
          _from,
          state
        ) do
      admit(fingerprint, state)
    end

    # Candidate F-575 5-tuple admit shape (includes wait_ms).
    def handle_call(
          {:admit_ordinary_runtime_start, _target, fingerprint, _validated_opts, _wait_ms},
          _from,
          state
        ) do
      admit(fingerprint, state)
    end

    def handle_call(_other, _from, state), do: {:reply, {:error, :unsupported}, state}

    defp admit(fingerprint, state) when is_binary(fingerprint) do
      n = state.admit_count + 1
      fps = MapSet.put(state.fingerprints, fingerprint)

      state = %{
        state
        | admit_count: n,
          fingerprints: fps,
          fingerprints_seen: MapSet.size(fps)
      }

      cond do
        n == 1 ->
          {:reply, {:error, :runtime_admission_wait_timeout}, state}

        n >= 2 and state.fingerprints_seen == 1 ->
          {:reply, {:ok, state.success_pid}, state}

        true ->
          {:reply, {:error, :conflict}, state}
      end
    end
  end

  # ── helpers (parent-existing public/OTP only) ───────────────────────

  defp ensure_runtime_admission_registry! do
    case Process.whereis(@registry) do
      nil ->
        start_supervised!({Registry, keys: :unique, name: @registry})

      _pid ->
        :ok
    end
  end

  # This module is synchronous, so fixed module-scoped names are unique without
  # allocating permanent atoms on every test run.
  defp unique_name(:ra_sup), do: __MODULE__.RuntimeAdmissionSupervisor
  defp unique_name(:task_sup), do: __MODULE__.TaskSupervisor
  defp unique_name(:store), do: __MODULE__.TaskStore
  defp unique_name(:os_fake_store), do: __MODULE__.OrdinaryStartRejoinTaskStore
  defp unique_name(:restart_store), do: __MODULE__.RestartTaskStore
  defp unique_name(:restart_sup), do: __MODULE__.RestartSupervisor

  defp store_intent(store, agent_id) do
    case :sys.get_state(store) do
      %{runtime_admission_intents: intents} -> Map.get(intents, agent_id)
      _ -> nil
    end
  end

  defp waiter_count(store, agent_id) do
    case :sys.get_state(store) do
      %{runtime_admission_intents: intents, runtime_admission_waiters: waiters} ->
        case Map.get(intents, agent_id) do
          %{intent_id: intent_id} when is_binary(intent_id) ->
            bucket = Map.get(waiters, intent_id, %{})

            cond do
              is_map(bucket) -> map_size(bucket)
              is_list(bucket) -> length(bucket)
              true -> 0
            end

          _ ->
            0
        end

      _ ->
        0
    end
  end

  defp await_bound_worker(store, agent_id) do
    await_until(
      fn ->
        case store_intent(store, agent_id) do
          %{worker_pid: pid} when is_pid(pid) -> pid
          _ -> false
        end
      end,
      10_000
    )
  end

  defp release_worker_hold(worker_pid) when is_pid(worker_pid) do
    send(worker_pid, :runtime_admission_release_hold)
  end

  defp release_any_worker(store, agent_id) do
    case store_intent(store, agent_id) do
      %{worker_pid: pid} when is_pid(pid) -> release_worker_hold(pid)
      _ -> :ok
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
          Process.sleep(10)
          do_await_until(fun, deadline)
        end

      nil ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("await_until timed out")
        else
          Process.sleep(10)
          do_await_until(fun, deadline)
        end

      other ->
        other
    end
  end
end
