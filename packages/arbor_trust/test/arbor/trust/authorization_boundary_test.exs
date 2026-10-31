defmodule Arbor.Trust.AuthorizationBoundaryTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Contracts.Security.Identity
  alias Arbor.Security.CapabilityStore

  import Arbor.Trust.TestHelpers,
    only: [ensure_provisioned_grant_owner!: 0, authorize_opts_with_grant!: 3]

  defmodule AutoPolicy do
    def effective_mode(_principal, _uri, _opts), do: :auto
    def confirmation_mode(_principal, _uri), do: :auto
  end

  setup do
    ensure_started(Arbor.Security.Identity.Registry)
    ensure_started(Arbor.Security.SystemAuthority)
    ensure_started(CapabilityStore)
    ensure_started(Arbor.Security.Constraint.RateLimiter)

    prev_enforcer = Application.get_env(:arbor_trust, :policy_enforcer_enabled)
    prev_guard = Application.get_env(:arbor_trust, :approval_guard_enabled)
    prev_policy = Application.get_env(:arbor_trust, :policy_module)

    Application.put_env(:arbor_trust, :policy_enforcer_enabled, true)
    Application.put_env(:arbor_trust, :approval_guard_enabled, true)
    Application.put_env(:arbor_trust, :policy_module, AutoPolicy)

    :ok = ensure_provisioned_grant_owner!()
    {:ok, identity} = Identity.generate(name: "trust-auth-boundary")
    :ok = Arbor.Security.register_identity_fixture(identity)

    on_exit(fn ->
      restore(:policy_enforcer_enabled, prev_enforcer)
      restore(:approval_guard_enabled, prev_guard)
      restore(:policy_module, prev_policy)
      _ = Arbor.Security.deregister_identity_fixture(identity.agent_id)
    end)

    {:ok, agent_id: identity.agent_id, agent_identity: identity}
  end

  test "security regression: Security.authorize does not mint from trust policy", %{
    agent_id: agent_id
  } do
    uri = "arbor://code/read/a1/no-kernel-mint"

    assert {:error, :unauthorized} = Arbor.Security.authorize(agent_id, uri, :execute)
    assert {:error, :not_found} = CapabilityStore.find_authorizing(agent_id, uri)
  end

  test "Trust.authorize explicitly mints before kernel authorization", %{
    agent_id: agent_id,
    agent_identity: agent_identity
  } do
    uri = "arbor://code/read/a1/trust-mint"

    assert {:ok, :authorized} =
             Arbor.Trust.authorize(
               agent_id,
               uri,
               :execute,
               authorize_opts_with_grant!([], agent_identity, uri)
             )

    assert {:ok, cap} = CapabilityStore.find_authorizing(agent_id, uri)
    assert cap.metadata[:source] == :trust_policy_enforcer
  end

  defp ensure_started(module) do
    if Process.whereis(module), do: :ok, else: start_supervised!({module, []})
  end

  defp restore(key, nil), do: Application.delete_env(:arbor_trust, key)
  defp restore(key, value), do: Application.put_env(:arbor_trust, key, value)
end
