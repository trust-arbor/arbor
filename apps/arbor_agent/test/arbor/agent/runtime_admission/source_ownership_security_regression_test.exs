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
      send(parent, {:admit, TaskStore.admit_ordinary_runtime_start(agent_id, fp, kw, name: store)})
    end)

    # Let owner adopt and bind progress under test hold.
    Process.sleep(120)

    # Foreign bind of an arbitrary PID must fail (caller is not the owner).
    foreign_worker = spawn(fn -> Process.sleep(10_000) end)

    assert {:error, reason} =
             TaskStore.bind_runtime_admission_worker(
               agent_id,
               "rai_forged",
               fp,
               foreign_worker,
               name: store
             )

    assert reason in [:not_owner, :not_found, :conflict]

    # Foreign settle must not complete the parked admit.
    assert {:error, settle_reason} =
             TaskStore.settle_runtime_admission(
               agent_id,
               "rai_forged",
               {:applied, self()},
               name: store
             )

    assert settle_reason in [:not_found, :not_owner, :conflict]
    refute_receive {:admit, _}, 150
  end

  test "security regression: foreign process cannot authenticate as worker or run Lifecycle effects",
       %{store: store} do
    agent_id = "agent_fx#{System.unique_integer([:positive])}"
    assert {:ok, %{fingerprint: fp, keyword: kw}} = Opts.project([])

    parent = self()

    spawn(fn ->
      send(parent, {:admit, TaskStore.admit_ordinary_runtime_start(agent_id, fp, kw, name: store)})
    end)

    Process.sleep(120)

    # Self-registration API must not exist.
    refute function_exported?(TaskStore, :register_runtime_admission_worker, 2)
    refute function_exported?(TaskStore, :register_runtime_admission_worker, 3)

    assert {:error, auth_reason} =
             TaskStore.authenticate_runtime_admission_worker(
               agent_id,
               "rai_forged",
               fp,
               name: store
             )

    assert auth_reason in [:not_found, :not_owner, :conflict]

    # Lifecycle effects with a forgeable witness map must fail auth before restore.
    assert {:error, _} =
             Lifecycle.ordinary_start_effects(agent_id, [], %{
               v: 1,
               kind: :ordinary_start,
               intent_id: "rai_forged",
               fingerprint: fp,
               store_ref: store
             })

    refute_receive {:admit, _}, 100
  end

  test "security regression: rejected settlement leaves intent/waiter live", %{store: store} do
    agent_id = "agent_live#{System.unique_integer([:positive])}"
    assert {:ok, %{fingerprint: fp, keyword: kw}} = Opts.project([])

    parent = self()

    spawn(fn ->
      send(parent, {:admit, TaskStore.admit_ordinary_runtime_start(agent_id, fp, kw, name: store)})
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

  defp unique_name(prefix), do: :"#{prefix}_#{System.unique_integer([:positive])}"
end
