defmodule Arbor.Actions.PrincipalAuthoritySecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression
  @resource "arbor://action/test/principal-sensitive"

  defmodule PrincipalSensitiveAction do
    @resource "arbor://action/test/principal-sensitive"

    use Jido.Action,
      name: "principal_sensitive_security_regression",
      description: "Records execution only after exact principal authorization",
      schema: []

    @impl true
    def run(_params, context) do
      with {:ok, principal_id} <- Arbor.Actions.authorized_principal(context, __MODULE__) do
        send(Map.fetch!(context, :test_pid), {:principal_sensitive_executed, principal_id})
        {:ok, %{principal_id: principal_id}}
      end
    end

    @doc false
    def requires_authenticated_principal?, do: true

    @doc false
    def authorization_resource(_params), do: {:ok, @resource}
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:arbor_security)
    {:ok, _} = Application.ensure_all_started(:arbor_trust)

    unless Process.whereis(Arbor.Trust.Store), do: start_supervised!(Arbor.Trust.Store)

    previous = %{
      reflex: Application.get_env(:arbor_security, :reflex_checking_enabled),
      signing: Application.get_env(:arbor_security, :capability_signing_required),
      identity: Application.get_env(:arbor_security, :identity_verification),
      strict: Application.get_env(:arbor_security, :strict_identity_mode),
      uri: Application.get_env(:arbor_security, :uri_registry_enforcement),
      escalation: Application.get_env(:arbor_security, :consensus_escalation_enabled),
      security_approval: Application.get_env(:arbor_security, :approval_guard_enabled),
      trust_approval: Application.get_env(:arbor_trust, :approval_guard_enabled),
      trust_enforcer: Application.get_env(:arbor_trust, :policy_enforcer_enabled)
    }

    Application.put_env(:arbor_security, :reflex_checking_enabled, false)
    Application.put_env(:arbor_security, :capability_signing_required, false)
    Application.put_env(:arbor_security, :identity_verification, false)
    Application.put_env(:arbor_security, :strict_identity_mode, false)
    Application.put_env(:arbor_security, :uri_registry_enforcement, false)
    Application.put_env(:arbor_security, :consensus_escalation_enabled, false)
    Application.put_env(:arbor_security, :approval_guard_enabled, false)
    Application.put_env(:arbor_trust, :approval_guard_enabled, false)
    Application.put_env(:arbor_trust, :policy_enforcer_enabled, true)

    on_exit(fn ->
      restore(:arbor_security, :reflex_checking_enabled, previous.reflex)
      restore(:arbor_security, :capability_signing_required, previous.signing)
      restore(:arbor_security, :identity_verification, previous.identity)
      restore(:arbor_security, :strict_identity_mode, previous.strict)
      restore(:arbor_security, :uri_registry_enforcement, previous.uri)
      restore(:arbor_security, :consensus_escalation_enabled, previous.escalation)
      restore(:arbor_security, :approval_guard_enabled, previous.security_approval)
      restore(:arbor_trust, :approval_guard_enabled, previous.trust_approval)
      restore(:arbor_trust, :policy_enforcer_enabled, previous.trust_enforcer)
    end)

    :ok
  end

  test "security regression: generic public scalar helper cannot impersonate a privileged principal" do
    agent_id = "agent_scalar_privileged_#{System.unique_integer([:positive])}"
    authorize_agent(agent_id)

    result = call_through_removed_scalar_helper(agent_id)

    assert {:error, :authenticated_principal_required} = result
    refute_receive {:principal_sensitive_executed, ^agent_id}

    Arbor.Security.CapabilityStore.revoke_all(agent_id)
    Arbor.Trust.Store.delete_profile(agent_id)
  end

  test "security regression: no-grant scalar cannot acquire principal authority" do
    agent_id = "agent_scalar_no_grant_#{System.unique_integer([:positive])}"

    result = call_through_removed_scalar_helper(agent_id)

    assert {:error, _reason} = result
    refute_receive {:principal_sensitive_executed, ^agent_id}
  end

  # The conditional keeps this behavioral regression runnable on exact parent
  # e4441ce: there the public helper exists and executes the side effect, so the
  # assertions above fail. On R4 the helper is absent and the same scalar-only
  # public authorize_and_execute call fails closed.
  defp call_through_removed_scalar_helper(agent_id) do
    callback = fn ->
      Arbor.Actions.authorize_and_execute(
        agent_id,
        PrincipalSensitiveAction,
        %{},
        %{agent_id: agent_id, test_pid: self()}
      )
    end

    if function_exported?(Arbor.Actions, :with_principal_authority, 2) do
      apply(Arbor.Actions, :with_principal_authority, [agent_id, callback])
    else
      callback.()
    end
  end

  defp authorize_agent(agent_id) do
    {:ok, profile} = Arbor.Contracts.Trust.Profile.new(agent_id)
    :ok = Arbor.Trust.Store.store_profile(%{profile | rules: %{@resource => :auto}})
    assert {:ok, _capability} = Arbor.Security.grant(principal: agent_id, resource: @resource)
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
