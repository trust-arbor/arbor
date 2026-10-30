defmodule Arbor.Security.RevokeAllIndexCleanupSecurityRegressionTest do
  @moduledoc """
  Security regression: revoking every capability of a principal must clear the
  delegation, issuer and usage indexes of what it revoked, as single and cascade
  revocation do.

  `exec_revoke_all/2` removed revoked ids from `by_id`, `by_principal` and the
  resource index only. The stale `by_parent` entry made a later cascade from the
  parent collect, delete, count and broadcast the already-revoked child again,
  and the stale `by_usage` count carried over to a capability stored again under
  the same id, so its use budget started part spent.
  """
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Contracts.Security.Capability
  alias Arbor.Security.CapabilityStore

  setup do
    n = :erlang.unique_integer([:positive])

    {:ok,
     owner: "agent_revoke_all_owner_#{n}",
     holder: "agent_revoke_all_holder_#{n}",
     resource: "arbor://fs/read/revoke-all-index-cleanup/#{n}"}
  end

  test "security regression: a cascade after revoke_all does not revisit the revoked child", %{
    owner: owner,
    holder: holder,
    resource: resource
  } do
    {:ok, parent} = Capability.new(resource_uri: resource, principal_id: owner)

    {:ok, child} =
      Capability.new(
        resource_uri: resource,
        principal_id: holder,
        parent_capability_id: parent.id
      )

    assert {:ok, :stored} = CapabilityStore.put_fixture(parent)
    assert {:ok, :stored} = CapabilityStore.put_fixture(child)

    assert {:ok, 1} = CapabilityStore.revoke_all_fixture(holder)

    # Only the parent is still live, so the cascade revokes exactly one capability.
    assert {:ok, 1} = CapabilityStore.cascade_revoke_fixture(parent.id)
  end

  test "security regression: a capability stored again after revoke_all starts with no uses", %{
    holder: holder,
    resource: resource
  } do
    {:ok, cap} = Capability.new(resource_uri: resource, principal_id: holder)

    assert {:ok, :stored} = CapabilityStore.put_fixture(cap)
    assert {:ok, 1} = CapabilityStore.increment_usage_fixture(cap.id)
    assert {:ok, 1} = CapabilityStore.revoke_all_fixture(holder)

    assert {:ok, :stored} = CapabilityStore.put_fixture(cap)
    assert {:ok, 1} = CapabilityStore.increment_usage_fixture(cap.id)
  end
end
