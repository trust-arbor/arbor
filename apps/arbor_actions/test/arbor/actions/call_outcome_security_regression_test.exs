defmodule Arbor.Actions.CallOutcomeSecurityRegressionTest do
  @moduledoc """
  Security regression (D5, imp-dspy-port review 2026-09-27): a failed action
  call must say whether its effect may have started. Before this, every
  failure flattened to `{:error, reason}`, so a live caller could not tell a
  refusal (safe to repeat) from a crash or timeout mid-effect (repeating it
  may duplicate the effect).
  """
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Trust.Profile
  alias Arbor.Trust.Store, as: TrustStore

  @moduletag :fast
  @moduletag :security_regression
  @resource "arbor://action/test/call-outcome-probe"

  defmodule OutcomeProbeAction do
    @resource "arbor://action/test/call-outcome-probe"

    use Jido.Action,
      name: "call_outcome_probe_security_regression",
      description: "Runs one scripted behaviour after admission",
      schema: []

    @impl true
    def run(_params, context) do
      send(Map.fetch!(context, :test_pid), :outcome_probe_ran)

      send(context.test_pid, {
        :source_context_observation,
        Map.has_key?(context, :conversation_source),
        Process.get({Arbor.Actions, :conversation_source}, :absent)
      })

      case Map.fetch!(context, :behaviour) do
        :succeed -> {:ok, %{done: true}}
        {:return_error, reason} -> {:error, reason}
        :raise -> raise "probe exploded mid-effect"
        :exit -> exit({:timeout, {GenServer, :call, [:probe_backend, :write, 5_000]}})
        :throw -> throw(:probe_thrown)
        {:nested, agent_id} -> nested(agent_id, context)
      end
    end

    # A nested call gets its own outcome frame: its refusal is not confused with
    # the admitted outer call, and the outer frame survives it.
    defp nested(agent_id, context) do
      inner =
        Arbor.Actions.authorize_and_execute_with_outcome(agent_id, __MODULE__, %{}, %{
          test_pid: context.test_pid,
          behaviour: :succeed
        })

      {:ok, %{inner_outcome: inner.outcome, inner_admitted: inner.effect_admitted}}
    end

    @doc false
    def authorization_resource(_params), do: {:ok, @resource}
  end

  defmodule PendingApprovalProbe do
    # Only the notification seam is sealed. The public Actions call still uses
    # the real Trust policy, Security grant and requires-approval decision.
    def healthy?, do: true

    def request(attrs, _opts) do
      send(self(), {:pending_approval_requested, attrs.agent_id, attrs.resource_uri})
      {:ok, "req_call_outcome_pending_contract"}
    end
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:arbor_security)
    {:ok, _} = Application.ensure_all_started(:arbor_trust)

    unless Process.whereis(TrustStore), do: start_supervised!(TrustStore)

    keys = [
      {:arbor_security, :reflex_checking_enabled, false},
      {:arbor_security, :capability_signing_required, false},
      {:arbor_security, :identity_verification, false},
      {:arbor_security, :strict_identity_mode, false},
      {:arbor_security, :uri_registry_enforcement, false},
      {:arbor_security, :consensus_escalation_enabled, false},
      {:arbor_security, :consensus_module, PendingApprovalProbe},
      {:arbor_security, :interaction_router, PendingApprovalProbe},
      {:arbor_security, :use_interaction_router_for_approval, true},
      {:arbor_security, :approval_guard_enabled, false},
      {:arbor_trust, :approval_guard_enabled, false},
      {:arbor_trust, :policy_enforcer_enabled, true}
    ]

    previous =
      Map.new(keys, fn {app, key, _value} -> {{app, key}, Application.fetch_env(app, key)} end)

    Enum.each(keys, fn {app, key, value} -> Application.put_env(app, key, value) end)

    on_exit(fn ->
      Enum.each(previous, fn
        {{app, key}, {:ok, value}} -> Application.put_env(app, key, value)
        {{app, key}, :error} -> Application.delete_env(app, key)
      end)
    end)

    agent_id = "agent_call_outcome_#{System.unique_integer([:positive])}"

    # Registered before the grant so a failed setup cannot leak authority.
    # A start_supervised Trust.Store is already stopped when on_exit runs.
    on_exit(fn ->
      Arbor.Security.revoke_all_fixture(agent_id)
      if Process.whereis(TrustStore), do: TrustStore.delete_profile(agent_id)
    end)

    authorize_agent(agent_id)

    %{agent_id: agent_id}
  end

  test "security regression: a call refused before admission is :refused and never ran" do
    unauthorized = "agent_call_outcome_no_grant_#{System.unique_integer([:positive])}"

    assert %{result: {:error, _}, effect_admitted: false, outcome: :refused} =
             call(unauthorized, :succeed)

    refute_received :outcome_probe_ran
  end

  test "security regression: Trust pending approval retains its request ID without admitting an effect",
       %{agent_id: agent_id} do
    {:ok, capabilities} = Arbor.Security.list_capabilities(agent_id)
    Enum.each(capabilities, &Arbor.Security.revoke_fixture(&1.id))

    assert {:ok, _} =
             Arbor.Security.grant_fixture(
               principal: agent_id,
               resource: @resource,
               constraints: %{requires_approval: true}
             )

    Application.put_env(:arbor_security, :consensus_escalation_enabled, true)

    assert %{
             result: {:ok, :pending_approval, "req_call_outcome_pending_contract"},
             effect_admitted: false,
             outcome: nil
           } = call(agent_id, :succeed)

    assert_received {:pending_approval_requested, ^agent_id, @resource}
    refute_received :outcome_probe_ran
  end

  test "an admitted successful call has no failure outcome", %{agent_id: agent_id} do
    assert %{result: {:ok, %{done: true}}, effect_admitted: true, outcome: nil} =
             call(agent_id, :succeed)
  end

  test "security regression: an admitted action's own error is :failed, never :refused",
       %{agent_id: agent_id} do
    # The value an action returns is its answer. Even a refusal-shaped term must
    # not read as "nothing ran": only the admission boundary decides that.
    for reason <- [:unauthorized, {:unauthorized, "looks like a gate"}, :bad_input] do
      assert %{result: {:error, ^reason}, effect_admitted: true, outcome: :failed} =
               call(agent_id, {:return_error, reason})

      assert_received :outcome_probe_ran
    end
  end

  test "security regression: a timeout reported after admission is :unknown",
       %{agent_id: agent_id} do
    for reason <- [:timeout, {:timeout, :backend}, {:http_error, :timeout}] do
      assert %{effect_admitted: true, outcome: :unknown} = call(agent_id, {:return_error, reason})
    end
  end

  test "security regression: a raise, exit or throw mid-effect is contained and :unknown",
       %{agent_id: agent_id} do
    for {behaviour, kind} <- [raise: :error, exit: :exit, throw: :throw] do
      assert %{
               result: {:error, {:action_interrupted, ^kind, detail}},
               effect_admitted: true,
               outcome: :unknown
             } = call(agent_id, behaviour)

      assert is_binary(detail) and detail != ""
      assert_received :outcome_probe_ran
    end
  end

  test "authorize_and_execute/4 keeps its historical contract: a raise still escapes",
       %{agent_id: agent_id} do
    assert_raise RuntimeError, ~r/probe exploded/, fn ->
      Arbor.Actions.authorize_and_execute(agent_id, OutcomeProbeAction, %{}, %{
        test_pid: self(),
        behaviour: :raise
      })
    end
  end

  test "a nested call is classified in its own frame", %{agent_id: agent_id} do
    unauthorized = "agent_call_outcome_nested_#{System.unique_integer([:positive])}"

    assert %{
             result: {:ok, %{inner_outcome: :refused, inner_admitted: false}},
             effect_admitted: true,
             outcome: nil
           } = call(agent_id, {:nested, unauthorized})
  end

  test "security regression: private source control is stripped from action context and restored after all exits",
       %{agent_id: agent_id} do
    source = %{session_pid: self(), generation: make_ref(), handle: {self(), make_ref()}}

    for behaviour <- [:succeed, :raise, :exit, :throw] do
      _ =
        Arbor.Actions.authorize_and_execute_with_outcome(agent_id, OutcomeProbeAction, %{}, %{
          test_pid: self(),
          behaviour: behaviour,
          conversation_source: source
        })

      assert_receive {:source_context_observation, false, {:present, ^source}}
      assert %{result: {:ok, %{done: true}}} = call(agent_id, :succeed)
      assert_receive {:source_context_observation, false, :absent}
    end
  end

  test "security regression: synchronous nested native calls retain private source without exposing it",
       %{agent_id: agent_id} do
    source = %{session_pid: self(), generation: make_ref(), handle: {self(), make_ref()}}

    assert %{result: {:ok, %{inner_admitted: true}}} =
             Arbor.Actions.authorize_and_execute_with_outcome(
               agent_id,
               OutcomeProbeAction,
               %{},
               %{
                 test_pid: self(),
                 behaviour: {:nested, agent_id},
                 conversation_source: source
               }
             )

    assert_receive {:source_context_observation, false, {:present, ^source}}
    assert_receive {:source_context_observation, false, {:present, ^source}}
    assert %{result: {:ok, %{done: true}}} = call(agent_id, :succeed)
    assert_receive {:source_context_observation, false, :absent}
  end

  defp call(agent_id, behaviour) do
    Arbor.Actions.authorize_and_execute_with_outcome(agent_id, OutcomeProbeAction, %{}, %{
      test_pid: self(),
      behaviour: behaviour
    })
  end

  defp authorize_agent(agent_id) do
    {:ok, profile} = Profile.new(agent_id)
    :ok = TrustStore.store_profile(%{profile | rules: %{@resource => :auto}})

    assert {:ok, _capability} =
             Arbor.Security.grant_fixture(principal: agent_id, resource: @resource)
  end
end
