defmodule Arbor.Security.FacadeIdIssuanceTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Contracts.Security.Identity
  alias Arbor.Security
  alias Arbor.Security.CapabilityStore
  alias Arbor.Security.Identity.Registry

  setup do
    {:ok, identity} = Identity.generate(name: "facade-id-issuance")
    :ok = Registry.register(identity)
    {:ok, agent_id: identity.agent_id}
  end

  test "ordinary grant id wrapper retains the capability inside Security", %{agent_id: agent_id} do
    assert {:ok, capability_id} =
             Security.grant_capability_id(
               principal: agent_id,
               resource: "arbor://fs/read/facade-id"
             )

    on_exit(fn -> Security.revoke(capability_id) end)

    assert "cap_" <> _ = capability_id
    assert {:ok, capability} = CapabilityStore.get(capability_id)
    assert capability.id == capability_id
  end

  test "disclosure issuance id wrapper retains the capability inside Security", %{
    agent_id: agent_id
  } do
    assert {:ok, capability_id} =
             Security.issue_disclosure_capability_id(
               principal_id: agent_id,
               session_id: "session_facade_id",
               task_id: "turn_facade_id",
               principal_scope: "human_facade_id",
               destination: "api.x.ai",
               provider: "xai",
               runtime: "arbor",
               model: "grok-voice-latest"
             )

    on_exit(fn -> Security.revoke(capability_id) end)

    assert "cap_" <> _ = capability_id
    assert {:ok, capability} = CapabilityStore.get(capability_id)
    assert capability.id == capability_id
  end
end
