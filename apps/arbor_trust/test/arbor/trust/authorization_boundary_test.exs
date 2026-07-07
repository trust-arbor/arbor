defmodule Arbor.Trust.AuthorizationBoundaryTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Security.CapabilityStore

  defmodule AutoPolicy do
    def effective_mode(_principal, _uri, _opts), do: :auto
    def confirmation_mode(_principal, _uri), do: :auto
  end

  setup do
    ensure_started(Arbor.Security.Identity.Registry)
    ensure_started(Arbor.Security.SystemAuthority)
    ensure_started(CapabilityStore)

    prev_enforcer = Application.get_env(:arbor_trust, :policy_enforcer_enabled)
    prev_guard = Application.get_env(:arbor_trust, :approval_guard_enabled)
    prev_policy = Application.get_env(:arbor_trust, :policy_module)

    Application.put_env(:arbor_trust, :policy_enforcer_enabled, true)
    Application.put_env(:arbor_trust, :approval_guard_enabled, true)
    Application.put_env(:arbor_trust, :policy_module, AutoPolicy)

    on_exit(fn ->
      restore(:policy_enforcer_enabled, prev_enforcer)
      restore(:approval_guard_enabled, prev_guard)
      restore(:policy_module, prev_policy)
    end)

    {:ok, agent_id: "agent_auth_boundary_#{System.unique_integer([:positive])}"}
  end

  test "security regression: Security.authorize does not mint from trust policy", %{
    agent_id: agent_id
  } do
    uri = "arbor://code/read/a1/no-kernel-mint"

    assert {:error, :unauthorized} = Arbor.Security.authorize(agent_id, uri, :execute)
    assert {:error, :not_found} = CapabilityStore.find_authorizing(agent_id, uri)
  end

  test "Trust.authorize explicitly mints before kernel authorization", %{agent_id: agent_id} do
    uri = "arbor://code/read/a1/trust-mint"

    assert {:ok, :authorized} = Arbor.Trust.authorize(agent_id, uri, :execute)
    assert {:ok, cap} = CapabilityStore.find_authorizing(agent_id, uri)
    assert cap.metadata[:source] == :trust_policy_enforcer
  end

  defp ensure_started(module) do
    if Process.whereis(module), do: :ok, else: start_supervised!({module, []})
  end

  defp restore(key, nil), do: Application.delete_env(:arbor_trust, key)
  defp restore(key, value), do: Application.put_env(:arbor_trust, key, value)
end
