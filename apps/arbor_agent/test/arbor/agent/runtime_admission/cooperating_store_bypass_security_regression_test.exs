defmodule Arbor.Agent.RuntimeAdmission.CooperatingStoreBypassSecurityRegressionTest do
  @moduledoc """
  Security regression (F-573): public `Lifecycle.start/2` must not route
  ordinary-start admission to a caller-selected cooperating store via `:name`.

  On base 3d31b4b8d, `OrdinaryStart.store_ref/1` honored `:name`, so a fake
  GenServer that always admits could bypass the fixed production TaskStore.
  After the fix, public `:name` is rejected with `{:error, :invalid_start_opts}`
  and the cooperating store receives zero requests.

  Also locks the closed witness contract (reject store_ref / unknown keys) and
  the structural MIX_ENV=test custom-store helper export shape. Non-test export
  absence is proven by executable MIX_ENV=dev/prod builds, not source-text.
  """

  use ExUnit.Case, async: false

  @moduletag :security_regression
  @moduletag :fast

  alias Arbor.Agent.Lifecycle
  alias Arbor.Agent.Orchestration.TaskStore
  alias Arbor.Agent.Test.RuntimeAdmissionTopology

  defmodule CooperatingStore do
    @moduledoc false
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, %{calls: 0}, name: name)
    end

    @doc false
    def call_count(name) do
      GenServer.call(name, :call_count)
    end

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(:call_count, _from, state) do
      {:reply, state.calls, state}
    end

    def handle_call(:runtime_admission_ready?, _from, state) do
      {:reply, true, bump(state)}
    end

    def handle_call({:admit_ordinary_runtime_start, _target, _fp, _opts}, _from, state) do
      # Cooperating bypass: settle immediately without owner/worker binding.
      dummy = spawn(fn -> Process.sleep(60_000) end)
      {:reply, {:ok, dummy}, bump(state)}
    end

    def handle_call({:authenticate_runtime_admission_worker, _, _, _}, _from, state) do
      {:reply, :ok, bump(state)}
    end

    def handle_call(_msg, _from, state), do: {:reply, {:error, :unexpected}, bump(state)}

    defp bump(%{calls: n} = state), do: %{state | calls: n + 1}
  end

  test "security regression: Lifecycle.start/2 rejects cooperating store via :name" do
    fake = :"coop_store_#{System.unique_integer([:positive])}"
    start_supervised!({CooperatingStore, name: fake})

    agent_id = "agent_coop#{System.unique_integer([:positive])}"

    # Base 3d31b4b8d: :name selects the cooperating store -> {:ok, pid} and
    # nonzero call_count. After F-573: public :name is rejected before any
    # store call, so the cooperating store is never invoked.
    assert {:error, :invalid_start_opts} =
             Lifecycle.start(agent_id,
               name: fake,
               start_session: false,
               recover_session: false
             )

    assert CooperatingStore.call_count(fake) == 0
  end

  test "security regression: ordinary_start_effects rejects witness store_ref" do
    fake = :"coop_auth_#{System.unique_integer([:positive])}"
    start_supervised!({CooperatingStore, name: fake})

    agent_id = "agent_wref#{System.unique_integer([:positive])}"

    # Closed witness contract: store_ref is rejected, not silently ignored.
    assert {:error, :invalid_ordinary_admission_witness} =
             Lifecycle.ordinary_start_effects(agent_id, [], %{
               v: 1,
               kind: :ordinary_start,
               intent_id: "rai_forged_#{System.unique_integer([:positive])}",
               fingerprint: "fp_forged",
               store_ref: fake
             })

    assert {:error, :invalid_ordinary_admission_witness} =
             Lifecycle.ordinary_start_effects(agent_id, [], %{
               "v" => 1,
               "kind" => "ordinary_start",
               "intent_id" => "rai_forged_str",
               "fingerprint" => "fp_forged",
               "store_ref" => fake
             })
  end

  test "security regression: ordinary_start_effects rejects arbitrary unknown witness key" do
    agent_id = "agent_wunk#{System.unique_integer([:positive])}"

    # Closed scalar contract: any key outside the allowlist is rejected.
    assert {:error, :invalid_ordinary_admission_witness} =
             Lifecycle.ordinary_start_effects(agent_id, [], %{
               v: 1,
               kind: :ordinary_start,
               intent_id: "rai_unknown_key_#{System.unique_integer([:positive])}",
               fingerprint: "fp_unknown_key",
               extra_authority: "forged"
             })

    assert {:error, :invalid_ordinary_admission_witness} =
             Lifecycle.ordinary_start_effects(agent_id, [], %{
               "v" => 1,
               "kind" => "ordinary_start",
               "intent_id" => "rai_unknown_key_str",
               "fingerprint" => "fp_unknown_key",
               "extra_authority" => "forged"
             })
  end

  test "security regression: start_fixed_production! is idempotent and ready" do
    first = RuntimeAdmissionTopology.start_fixed_production!()
    second = RuntimeAdmissionTopology.start_fixed_production!()

    assert first.store == TaskStore
    assert second.store == TaskStore
    assert first.store_pid == second.store_pid
    assert first.ra_sup == second.ra_sup
    assert first.task_sup == second.task_sup
    assert first.registry_pid == second.registry_pid

    assert Process.alive?(first.store_pid)
    assert Process.whereis(TaskStore) == first.store_pid
    assert Process.whereis(Arbor.Agent.RuntimeAdmission.Supervisor) == first.ra_sup
    assert Process.whereis(Arbor.Agent.Orchestration.TaskSupervisor) == first.task_sup
    assert Process.whereis(Arbor.Agent.RuntimeAdmissionRegistry) == first.registry_pid

    assert TaskStore.runtime_admission_ready?(name: TaskStore) == true
  end

  test "security regression: custom-store helper is test-only export" do
    assert function_exported?(Lifecycle, :ordinary_start_effects, 3)
    # Production path has no arity-4 ordinary_start_effects store selector.
    refute function_exported?(Lifecycle, :ordinary_start_effects, 4)

    # Under MIX_ENV=test the explicit helper is exported. Re-run the executable
    # dev/prod absence proof in scripts/verify_lifecycle_test_only_exports.exs.
    assert function_exported?(Lifecycle, :ordinary_start_effects_for_test_store, 4)
  end
end
