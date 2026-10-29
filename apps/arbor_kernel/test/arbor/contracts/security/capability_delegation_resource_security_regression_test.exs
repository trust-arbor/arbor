defmodule Arbor.Contracts.Security.CapabilityDelegationResourceSecurityRegressionTest do
  @moduledoc """
  Security regression: `Capability.delegate/3` must adopt the requested
  sub-resource and refuse a child that escapes the parent.

  Pre-fix, `delegate/3` always copied `parent.resource_uri` into the child.
  Delegating `arbor://fs/read/root/sub` from `arbor://fs/read/root/**` still
  produced a child that authorized every path under `root/**`.
  """

  use ExUnit.Case, async: true

  @moduletag :fast
  @moduletag security: :regression

  alias Arbor.Contracts.Security.Capability

  test "security regression: delegating fs://root/sub from fs://root/** yields a child limited to sub" do
    {:ok, parent} =
      Capability.new(
        resource_uri: "arbor://fs/read/root/**",
        principal_id: "agent_parent"
      )

    assert {:ok, child} =
             Capability.delegate(parent, "agent_child",
               resource_uri: "arbor://fs/read/root/sub"
             )

    assert child.resource_uri == "arbor://fs/read/root/sub"
    assert child.parent_capability_id == parent.id
    assert Capability.grants_access?(child, "arbor://fs/read/root/sub")
    refute Capability.grants_access?(child, "arbor://fs/read/root/other")
    refute Capability.grants_access?(child, "arbor://fs/read/root/sub/nested")
    assert Capability.envelope_subset?(child, parent)
  end

  test "security regression: delegate/3 refuses a requested resource outside the parent" do
    {:ok, parent} =
      Capability.new(
        resource_uri: "arbor://fs/read/root/**",
        principal_id: "agent_parent"
      )

    assert {:error, :widens_envelope} =
             Capability.delegate(parent, "agent_child",
               resource_uri: "arbor://fs/read/other"
             )

    assert {:error, :widens_envelope} =
             Capability.delegate(parent, "agent_child", resource_uri: "arbor://fs/**")
  end

  test "security regression: omitted resource_uri still inherits the parent address" do
    {:ok, parent} =
      Capability.new(
        resource_uri: "arbor://fs/read/root/**",
        principal_id: "agent_parent"
      )

    assert {:ok, child} = Capability.delegate(parent, "agent_child")
    assert child.resource_uri == parent.resource_uri
  end
end
