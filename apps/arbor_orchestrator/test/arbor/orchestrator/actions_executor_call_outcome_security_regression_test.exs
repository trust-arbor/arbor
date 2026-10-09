defmodule Arbor.Orchestrator.ActionsExecutorCallOutcomeSecurityRegressionTest do
  @moduledoc """
  Security regression (D5, imp-dspy-port review 2026-09-27): ActionsExecutor
  flattened every failure to a string, so the tool loop could not tell a call
  that never ran from one that crashed mid-effect. `execute_classified/4`
  carries the admission boundary's outcome and the action's replay class;
  `execute/4` keeps its string contract.
  """
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Common.ActionRegistry
  alias Arbor.Contracts.Tool.CallFailure
  alias Arbor.Contracts.Trust.Profile
  alias Arbor.Orchestrator.ActionsExecutor
  alias Arbor.Trust.Store, as: TrustStore

  @resource "arbor://action/test/executor-call-outcome-probe"
  # Core lock requires a plugin namespace. A bare name is rejected.
  @action_name "test.executor_call_outcome_probe"

  defmodule ProbeAction do
    use Jido.Action,
      name: "executor_call_outcome_probe",
      description: "Scripted admitted behaviour for executor outcome tests",
      schema: [behaviour: [type: :string, required: true]]

    @impl true
    def run(%{behaviour: behaviour}, _context) do
      send(:executor_call_outcome_probe, {:probe_ran, behaviour})

      case behaviour do
        "raise" -> raise "probe exploded mid-effect"
        "exit" -> exit({:timeout, {GenServer, :call, [:probe_backend, :write, 5_000]}})
        "error" -> {:error, :probe_rejected_input}
        "succeed" -> {:ok, %{done: true}}
      end
    end

    @doc false
    def authorization_resource(_params),
      do: {:ok, "arbor://action/test/executor-call-outcome-probe"}
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:arbor_security)
    {:ok, _} = Application.ensure_all_started(:arbor_trust)

    unless Process.whereis(TrustStore), do: start_supervised!(TrustStore)
    unless Process.whereis(ActionRegistry), do: start_supervised!(ActionRegistry)

    # Every restore is registered before the step it undoes, so a setup failure
    # (e.g. a grant refused by an unavailable audit journal) cannot leak global
    # registry or security configuration into later tests.
    registry_snapshot = ActionRegistry.snapshot()

    on_exit(fn ->
      # start_supervised children are already stopped when on_exit runs.
      if Process.whereis(ActionRegistry), do: :ok = ActionRegistry.restore(registry_snapshot)
    end)

    case ActionRegistry.resolve(@action_name) do
      {:ok, ProbeAction} -> :ok
      {:error, :not_found} -> :ok = ActionRegistry.register(@action_name, ProbeAction)
    end

    Process.register(self(), :executor_call_outcome_probe)

    env = [
      {:arbor_security, :reflex_checking_enabled, false},
      {:arbor_security, :capability_signing_required, false},
      {:arbor_security, :identity_verification, false},
      {:arbor_security, :strict_identity_mode, false},
      {:arbor_security, :uri_registry_enforcement, false},
      {:arbor_security, :consensus_escalation_enabled, false},
      {:arbor_security, :approval_guard_enabled, false},
      {:arbor_trust, :approval_guard_enabled, false},
      {:arbor_trust, :policy_enforcer_enabled, true}
    ]

    previous = Map.new(env, fn {app, key, _} -> {{app, key}, Application.fetch_env(app, key)} end)

    on_exit(fn ->
      Enum.each(previous, fn
        {{app, key}, {:ok, value}} -> Application.put_env(app, key, value)
        {{app, key}, :error} -> Application.delete_env(app, key)
      end)
    end)

    Enum.each(env, fn {app, key, value} -> Application.put_env(app, key, value) end)

    agent_id = "agent_executor_outcome_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Arbor.Security.revoke_all_fixture(agent_id)
      if Process.whereis(TrustStore), do: TrustStore.delete_profile(agent_id)
    end)

    {:ok, profile} = Profile.new(agent_id)
    :ok = TrustStore.store_profile(%{profile | rules: %{@resource => :auto}})

    assert {:ok, _capability} =
             Arbor.Security.grant_fixture(principal: agent_id, resource: @resource)

    %{agent_id: agent_id}
  end

  test "security regression: a crash mid-effect is :unknown with the action's replay class",
       %{agent_id: agent_id} do
    for behaviour <- ["raise", "exit"] do
      assert {:error,
              %CallFailure{
                outcome: :unknown,
                tool: @action_name,
                idempotency: :side_effecting,
                message: message
              } = failure} = classified(agent_id, behaviour)

      assert message =~ "was interrupted while running"
      assert CallFailure.indeterminate_effect?(failure)
      assert_received {:probe_ran, ^behaviour}
    end
  end

  test "an admitted action's error is :failed", %{agent_id: agent_id} do
    assert {:error, %CallFailure{outcome: :failed, message: message}} =
             classified(agent_id, "error")

    assert message =~ "probe_rejected_input"
  end

  test "security regression: calls stopped before admission are :refused and never run" do
    unauthorized = "agent_executor_outcome_no_grant_#{System.unique_integer([:positive])}"

    assert {:error, %CallFailure{outcome: :refused, tool: @action_name}} =
             classified(unauthorized, "succeed")

    assert {:error, %CallFailure{outcome: :refused, message: "Unknown action: no_such_probe"}} =
             ActionsExecutor.execute_classified("no_such_probe", %{}, File.cwd!(),
               agent_id: unauthorized
             )

    refute_received {:probe_ran, _}
  end

  test "execute/4 keeps the string contract and no longer lets a crash escape",
       %{agent_id: agent_id} do
    assert {:error, message} =
             ActionsExecutor.execute(
               @action_name,
               %{"behaviour" => "exit"},
               File.cwd!(),
               agent_id: agent_id
             )

    assert is_binary(message)
    assert message =~ "was interrupted while running"

    assert {:ok, _formatted} =
             ActionsExecutor.execute(
               @action_name,
               %{"behaviour" => "succeed"},
               File.cwd!(),
               agent_id: agent_id
             )
  end

  defp classified(agent_id, behaviour) do
    ActionsExecutor.execute_classified(
      @action_name,
      %{"behaviour" => behaviour},
      File.cwd!(),
      agent_id: agent_id
    )
  end
end
