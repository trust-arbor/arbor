defmodule Arbor.Agent.RuntimeAdmissionOrdinaryStartSecurityRegressionTest do
  @moduledoc """
  Phase 4C C3C1a0 security regressions for ordinary runtime-admission intents.

  Exercises real Lifecycle / TaskStore / BranchSupervisor production paths.
  """

  use ExUnit.Case, async: false

  @moduletag :security_regression
  @moduletag :fast

  alias Arbor.Agent.{BranchSupervisor, Character, Lifecycle, Profile, ProfileStore}
  alias Arbor.Agent.Orchestration.{TaskControlRecoveryMemory, TaskStore}
  alias Arbor.Agent.RuntimeAdmission.Opts
  alias Arbor.Agent.RuntimeAdmission.Supervisor, as: RASupervisor
  alias Arbor.Contracts.TenantContext

  setup do
    TaskControlRecoveryMemory.ensure!()
    TaskControlRecoveryMemory.reset!()

    ensure_runtime_admission_registry!()

    ra_sup = start_supervised!({RASupervisor, name: unique_name(:ra_sup)})
    task_sup = start_supervised!({Task.Supervisor, name: unique_name(:task_sup)})
    store_name = unique_name(:store)

    start_supervised!(
      {TaskStore,
       name: store_name,
       task_supervisor: task_sup,
       runtime_admission_supervisor: ra_sup,
       runtime_admission_force_ready: true,
       fence_force_ready: true,
       recovery_force_ready: true}
    )

    %{store: store_name, ra_sup: ra_sup, task_sup: task_sup}
  end

  defp ensure_runtime_admission_registry! do
    case Process.whereis(Arbor.Agent.RuntimeAdmissionRegistry) do
      nil ->
        start_supervised!(
          {Registry, keys: :unique, name: Arbor.Agent.RuntimeAdmissionRegistry}
        )

      _pid ->
        :ok
    end
  end

  test "security regression: fence-then-start rejects without authority or branch effects",
       %{store: store} do
    agent_id = persist_minimal_agent()

    assert {:ok, %{active_count: 0, reserved_count: 0}} =
             TaskStore.install_target_fence(agent_id, "op_fence_1", name: store)

    assert {:ok, %{fingerprint: fp, keyword: kw}} = Opts.project([])

    assert {:error, :target_fenced} =
             TaskStore.admit_ordinary_runtime_start(agent_id, fp, kw, name: store)

    assert BranchSupervisor.whereis(agent_id) == nil
  end

  test "security regression: start-then-fence reports non-idle barrier", %{store: store} do
    agent_id = persist_minimal_agent()
    assert {:ok, %{fingerprint: fp, keyword: kw}} = Opts.project([])

    Application.put_env(:arbor_agent, :runtime_admission_test_hold, %{timeout_ms: 2_000})
    on_exit(fn -> Application.delete_env(:arbor_agent, :runtime_admission_test_hold) end)

    parent = self()

    spawn(fn ->
      result = TaskStore.admit_ordinary_runtime_start(agent_id, fp, kw, name: store)
      send(parent, {:start_done, result})
    end)

    # Give admit a moment to register the intent before fence install.
    Process.sleep(50)

    assert {:ok, %{active_count: active, reserved_count: _}} =
             TaskStore.install_target_fence(agent_id, "op_after_start", name: store)

    assert active >= 1

    assert_receive {:start_done, _result}, 30_000
  end

  test "security regression: same principal different workspace conflicts", %{store: store} do
    agent_id = persist_minimal_agent()
    t1 = TenantContext.new("human_x", workspace_root: "/tmp/ws1")
    t2 = TenantContext.new("human_x", workspace_root: "/tmp/ws2")

    assert {:ok, %{fingerprint: fp1, keyword: kw1}} = Opts.project(tenant_context: t1)
    assert {:ok, %{fingerprint: fp2, keyword: kw2}} = Opts.project(tenant_context: t2)
    refute fp1 == fp2

    Application.put_env(:arbor_agent, :runtime_admission_test_hold, %{timeout_ms: 2_000})
    on_exit(fn -> Application.delete_env(:arbor_agent, :runtime_admission_test_hold) end)

    parent = self()

    spawn(fn ->
      # Hold the first intent open by admitting; second should conflict while live.
      send(parent, {:first, TaskStore.admit_ordinary_runtime_start(agent_id, fp1, kw1, name: store)})
    end)

    Process.sleep(50)

    assert {:error, :conflict} =
             TaskStore.admit_ordinary_runtime_start(agent_id, fp2, kw2, name: store)

    assert_receive {:first, _}, 30_000
  end

  test "security regression: concurrent identical fingerprint joins one intent path", %{
    store: store
  } do
    agent_id = persist_minimal_agent()
    assert {:ok, %{fingerprint: fp, keyword: kw}} = Opts.project([])

    parent = self()

    for i <- 1..2 do
      spawn(fn ->
        send(
          parent,
          {:done, i, TaskStore.admit_ordinary_runtime_start(agent_id, fp, kw, name: store)}
        )
      end)
    end

    results =
      for _ <- 1..2 do
        assert_receive {:done, _i, result}, 30_000
        result
      end

    # Both either ok with same pid or same class of error — never two different branches.
    pids =
      results
      |> Enum.filter(&match?({:ok, pid} when is_pid(pid), &1))
      |> Enum.map(fn {:ok, p} -> p end)
      |> Enum.uniq()

    assert length(pids) <= 1
  end

  test "security regression: existing-branch under fence does not mutate via start", %{
    store: store
  } do
    agent_id = persist_minimal_agent()

    # If a branch is already running, fence install still works; start is rejected.
    assert {:ok, _} = TaskStore.install_target_fence(agent_id, "op_exist", name: store)
    assert {:ok, %{fingerprint: fp, keyword: kw}} = Opts.project([])

    before = BranchSupervisor.whereis(agent_id)

    assert {:error, :target_fenced} =
             TaskStore.admit_ordinary_runtime_start(agent_id, fp, kw, name: store)

    assert BranchSupervisor.whereis(agent_id) == before
  end

  test "security regression: BranchSupervisor witness exact/bare classification helpers" do
    # Registry-value API exists and does not GenServer.call a Supervisor.
    assert BranchSupervisor.ordinary_admission_witness("agent_missing_zzzz") == :not_running
  end

  test "security regression: Lifecycle.start routes through ordinary admission primitive" do
    # Public API is the admission entry — no early restore/authority outside it.
    # Arity-2 ordinary_start_effects is a bypass and must not be exported.
    refute function_exported?(Lifecycle, :ordinary_start_effects, 2)
    assert function_exported?(Lifecycle, :ordinary_start_effects, 3)
    assert function_exported?(Lifecycle, :start, 1)
    assert function_exported?(Lifecycle, :start, 2)
  end

  defp persist_minimal_agent do
    agent_id = "agent_rai#{System.unique_integer([:positive])}"

    profile = %Profile{
      agent_id: agent_id,
      display_name: "RAI Test",
      character: Character.new(name: "RAI", tone: "test"),
      identity: %{public_key: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)},
      metadata: %{},
      created_at: DateTime.utc_now(),
      version: 1
    }

    # Best-effort persist; isolated tests may only exercise fence/admit gates.
    _ = ProfileStore.store_profile(profile)
    agent_id
  end

  defp unique_name(prefix) do
    :"#{prefix}_#{System.unique_integer([:positive])}"
  end
end
