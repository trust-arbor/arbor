defmodule Arbor.Trust.ApprovalGuardAlwaysLockedFloorSecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Trust.ApprovalGuard

  # 2026-10-11 cross-library review F-015: the always-locked URI classes were
  # consulted only inside the `:gated` branch, so a profile/ceiling override
  # that resolved `:auto` made shell, governance, hot_load — and now trust
  # mutation — run unattended. The list is a floor, matched segment-aware.
  defmodule AutoPolicy do
    def confirmation_mode(_principal, _uri), do: :auto
  end

  setup do
    prev_enabled = Application.get_env(:arbor_trust, :approval_guard_enabled)
    prev_policy = Application.get_env(:arbor_trust, :policy_module)

    Application.put_env(:arbor_trust, :approval_guard_enabled, true)
    Application.put_env(:arbor_trust, :policy_module, AutoPolicy)

    on_exit(fn ->
      restore(:approval_guard_enabled, prev_enabled)
      restore(:policy_module, prev_policy)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:arbor_trust, key)
  defp restore(key, value), do: Application.put_env(:arbor_trust, key, value)

  defp make_capability(resource_uri) do
    %{
      id: "cap_floor_#{System.unique_integer([:positive])}",
      resource_uri: resource_uri,
      principal_id: "agent_test",
      constraints: %{},
      metadata: %{}
    }
  end

  for uri <- [
        "arbor://shell/exec/ls",
        "arbor://governance/policy/update",
        "arbor://code/hot_load/Some.Module",
        "arbor://trust/write",
        "arbor://trust/auto_promote/agent_x"
      ] do
    test "security regression (F-015): #{uri} is never unattended even when policy resolves :auto" do
      refute ApprovalGuard.check(make_capability(unquote(uri)), "agent_test", unquote(uri)) == :ok
    end
  end

  test "the floor is segment-aware: a sibling namespace with the same prefix bytes is not locked" do
    assert :ok =
             ApprovalGuard.check(
               make_capability("arbor://shellx/exec/ls"),
               "agent_test",
               "arbor://shellx/exec/ls"
             )

    assert :ok =
             ApprovalGuard.check(
               make_capability("arbor://trust/read"),
               "agent_test",
               "arbor://trust/read"
             )
  end
end
