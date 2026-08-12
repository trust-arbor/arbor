defmodule Arbor.Agent.RuntimeAdmission.CooperatingStoreBypassSecurityRegressionTest do
  @moduledoc """
  Security regression (F-573): public `Lifecycle.start/2` must not route
  ordinary-start admission to a caller-selected cooperating store via `:name`.

  On base 3d31b4b8d, `OrdinaryStart.store_ref/1` honored `:name`, so a fake
  GenServer that always admits could bypass the fixed production TaskStore.
  After the fix, public `:name` is rejected with `{:error, :invalid_start_opts}`.

  Also locks the closed witness contract (reject store_ref / unknown keys) and
  the structural test-only custom-store helper export shape.
  """

  use ExUnit.Case, async: false

  @moduletag :security_regression
  @moduletag :fast

  alias Arbor.Agent.Lifecycle

  defmodule CooperatingStore do
    @moduledoc false
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, %{}, name: name)
    end

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(:runtime_admission_ready?, _from, state), do: {:reply, true, state}

    def handle_call({:admit_ordinary_runtime_start, _target, _fp, _opts}, _from, state) do
      # Cooperating bypass: settle immediately without owner/worker binding.
      dummy = spawn(fn -> Process.sleep(60_000) end)
      {:reply, {:ok, dummy}, state}
    end

    def handle_call({:authenticate_runtime_admission_worker, _, _, _}, _from, state) do
      {:reply, :ok, state}
    end

    def handle_call(_msg, _from, state), do: {:reply, {:error, :unexpected}, state}
  end

  test "security regression: Lifecycle.start/2 rejects cooperating store via :name" do
    fake = :"coop_store_#{System.unique_integer([:positive])}"
    start_supervised!({CooperatingStore, name: fake})

    agent_id = "agent_coop#{System.unique_integer([:positive])}"

    # Base 3d31b4b8d: :name selects the cooperating store → {:ok, pid}.
    # After F-573: public :name is rejected before any store call.
    assert {:error, :invalid_start_opts} =
             Lifecycle.start(agent_id,
               name: fake,
               start_session: false,
               recover_session: false
             )
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

  test "security regression: custom-store helper is test-only export" do
    assert function_exported?(Lifecycle, :ordinary_start_effects, 3)
    # Production path has no arity-4 ordinary_start_effects store selector.
    refute function_exported?(Lifecycle, :ordinary_start_effects, 4)

    # Under MIX_ENV=test the explicit helper is exported.
    assert function_exported?(Lifecycle, :ordinary_start_effects_for_test_store, 4)

    # Structural non-test export evidence: definition is compile-gated so dev/prod
    # BEAMs cannot export the helper (same pattern as Supervisor.start_owner_test/3).
    source =
      Path.expand(
        "apps/arbor_agent/lib/arbor/agent/lifecycle.ex",
        File.cwd!()
      )

    assert File.exists?(source)
    content = File.read!(source)

    assert content =~
             ~r/if Mix\.env\(\) == :test do\s*\n\s*@doc false\s*\n\s*@spec ordinary_start_effects_for_test_store/

    # ordinary_start_effects/3 hardcodes fixed TaskStore (no caller store_ref).
    assert content =~
             ~r/def ordinary_start_effects\(agent_id, opts, witness\).*?Arbor\.Agent\.Orchestration\.TaskStore/s
  end
end
