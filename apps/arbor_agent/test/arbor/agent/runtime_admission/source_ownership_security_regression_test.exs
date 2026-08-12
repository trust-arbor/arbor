defmodule Arbor.Agent.RuntimeAdmission.SourceOwnershipSecurityRegressionTest do
  @moduledoc """
  Security regression: owner-authenticated worker bind, Lifecycle effect auth,
  and settlement are source-owned. Foreign processes cannot bind/register/settle
  or call Lifecycle.ordinary_start_effects even with a real live intent_id.
  """

  use ExUnit.Case, async: false

  @moduletag :security_regression
  @moduletag :fast

  alias Arbor.Agent.Lifecycle
  alias Arbor.Agent.Orchestration.{TaskControlRecoveryMemory, TaskStore}
  alias Arbor.Agent.RuntimeAdmission.Opts
  alias Arbor.Agent.RuntimeAdmission.Supervisor, as: RASupervisor

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
       fence_force_ready: true,
       recovery_force_ready: true}
    )

    Application.put_env(:arbor_agent, :runtime_admission_test_hold, %{timeout_ms: 5_000})
    on_exit(fn -> Application.delete_env(:arbor_agent, :runtime_admission_test_hold) end)

    %{store: store, task_sup: task_sup}
  end

  test "security regression: ordinary_start_effects/2 is not exported" do
    assert {:module, Lifecycle} = Code.ensure_loaded(Lifecycle)
    refute function_exported?(Lifecycle, :ordinary_start_effects, 2)
    assert function_exported?(Lifecycle, :ordinary_start_effects, 3)
  end

  test "security regression: foreign process cannot bind worker even with live intent", %{
    store: store
  } do
    agent_id = "agent_own#{System.unique_integer([:positive])}"
    assert {:ok, %{fingerprint: fp, keyword: kw}} = Opts.project([])

    parent = self()

    spawn(fn ->
      send(
        parent,
        {:admit, TaskStore.admit_ordinary_runtime_start(agent_id, fp, kw, name: store)}
      )
    end)

    # Exact live owner evidence (not forged rai_* as primary).
    owner_pid =
      await_until(
        fn ->
          case Registry.lookup(
                 Arbor.Agent.RuntimeAdmissionRegistry,
                 {:runtime_admission_owner, agent_id}
               ) do
            [{pid, _}] when is_pid(pid) -> pid
            _ -> false
          end
        end,
        5_000
      )

    assert {:ok, snap} = Arbor.Agent.RuntimeAdmission.IntentOwner.snapshot(owner_pid)
    assert snap.target_agent_id == agent_id
    assert snap.fingerprint == fp
    intent_id = snap.intent_id

    # Await live adopted owner before foreign bind (exact :not_owner taxonomy).
    _bound =
      await_until(
        fn ->
          case :sys.get_state(Process.whereis(store)) do
            %{runtime_admission_intents: intents} ->
              case Map.get(intents, agent_id) do
                %{phase: phase, owner_pid: op}
                when phase in [:owner_live, :worker_running] and is_pid(op) ->
                  true

                _ ->
                  false
              end

            _ ->
              false
          end
        end,
        5_000
      )

    # Foreign bind of an arbitrary PID must fail: caller is not the live owner.
    foreign_worker = spawn(fn -> Process.sleep(10_000) end)

    assert {:error, :not_owner} =
             TaskStore.bind_runtime_admission_worker(
               agent_id,
               intent_id,
               fp,
               foreign_worker,
               name: store
             )

    # Foreign settle must not complete the parked admit.
    assert {:error, :not_owner} =
             TaskStore.settle_runtime_admission(
               agent_id,
               intent_id,
               {:applied, self()},
               name: store
             )

    refute_receive {:admit, _}, 150
  end

  test "security regression: foreign process cannot authenticate as worker or run Lifecycle effects",
       %{store: store} do
    agent_id = "agent_fx#{System.unique_integer([:positive])}"
    assert {:ok, %{fingerprint: fp, keyword: kw}} = Opts.project([])

    parent = self()

    spawn(fn ->
      send(
        parent,
        {:admit, TaskStore.admit_ordinary_runtime_start(agent_id, fp, kw, name: store)}
      )
    end)

    owner_pid =
      await_until(
        fn ->
          case Registry.lookup(
                 Arbor.Agent.RuntimeAdmissionRegistry,
                 {:runtime_admission_owner, agent_id}
               ) do
            [{pid, _}] when is_pid(pid) -> pid
            _ -> false
          end
        end,
        5_000
      )

    assert {:ok, snap} = Arbor.Agent.RuntimeAdmission.IntentOwner.snapshot(owner_pid)
    intent_id = snap.intent_id
    assert snap.fingerprint == fp

    # Self-registration API must not exist.
    refute function_exported?(TaskStore, :register_runtime_admission_worker, 2)
    refute function_exported?(TaskStore, :register_runtime_admission_worker, 3)

    assert {:error, auth_reason} =
             TaskStore.authenticate_runtime_admission_worker(
               agent_id,
               intent_id,
               fp,
               name: store
             )

    assert auth_reason in [:not_found, :not_owner, :conflict]

    # Closed witness contract rejects store_ref (not silently ignored).
    assert {:error, :invalid_ordinary_admission_witness} =
             Lifecycle.ordinary_start_effects(agent_id, [], %{
               v: 1,
               kind: :ordinary_start,
               intent_id: intent_id,
               fingerprint: fp,
               store_ref: store
             })

    # Foreign caller with closed scalars authenticates against fixed production
    # TaskStore only — not the owned store that holds the live intent.
    foreign_result =
      try do
        Lifecycle.ordinary_start_effects(agent_id, [], %{
          v: 1,
          kind: :ordinary_start,
          intent_id: intent_id,
          fingerprint: fp
        })
      catch
        :exit, _ -> {:error, :auth_store_unavailable}
      end

    assert match?({:error, _}, foreign_result)

    refute_receive {:admit, _}, 100
  end

  test "security regression: rejected settlement leaves intent/waiter live", %{store: store} do
    agent_id = "agent_live#{System.unique_integer([:positive])}"
    assert {:ok, %{fingerprint: fp, keyword: kw}} = Opts.project([])

    parent = self()

    spawn(fn ->
      send(
        parent,
        {:admit, TaskStore.admit_ordinary_runtime_start(agent_id, fp, kw, name: store)}
      )
    end)

    Process.sleep(100)

    assert {:ok, %{active_count: active}} =
             TaskStore.install_target_fence(agent_id, "op_own_1", name: store)

    assert active >= 1

    assert {:error, _} =
             TaskStore.settle_runtime_admission(
               agent_id,
               "rai_unknown",
               {:error, :forged},
               name: store
             )

    assert {:ok, %{active_count: active2}} =
             TaskStore.install_target_fence(agent_id, "op_own_1", name: store)

    assert active2 >= 1
    refute_receive {:admit, _}, 100
  end

  test "security regression: spoofed self-register and worker-down cast APIs are gone" do
    refute function_exported?(TaskStore, :runtime_admission_worker_down, 3)
    refute function_exported?(TaskStore, :runtime_admission_worker_down, 4)
    refute function_exported?(TaskStore, :mark_runtime_admission_worker, 2)
    refute function_exported?(TaskStore, :mark_runtime_admission_worker, 3)
    refute function_exported?(TaskStore, :register_runtime_admission_worker, 2)
    refute function_exported?(TaskStore, :register_runtime_admission_worker, 3)
  end

  test "security regression: store_restart_exit? does not swallow bare noproc" do
    alias Arbor.Agent.RuntimeAdmission.OrdinaryStart

    refute OrdinaryStart.store_restart_exit?({:noproc, :something_else}, :my_store)

    assert OrdinaryStart.store_restart_exit?(
             {:noproc, {GenServer, :call, [:my_store, :msg]}},
             :my_store
           )

    refute OrdinaryStart.store_restart_exit?(
             {:noproc, {GenServer, :call, [:other_store, :msg]}},
             :my_store
           )
  end

  defp ensure_runtime_admission_registry! do
    case Process.whereis(Arbor.Agent.RuntimeAdmissionRegistry) do
      nil ->
        start_supervised!({Registry, keys: :unique, name: Arbor.Agent.RuntimeAdmissionRegistry})

      _ ->
        :ok
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

  defp unique_name(prefix), do: :"#{prefix}_#{System.unique_integer([:positive])}"
end
