defmodule Arbor.Security.KernelTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Contracts.Security.Capability
  alias Arbor.Security.CapabilityStore
  alias Arbor.Security.Kernel

  setup do
    agent_id = "agent_kernel_#{:erlang.unique_integer([:positive])}"
    {:ok, agent_id: agent_id}
  end

  describe "grant_capability/1" do
    test "grants capability with minimal options", %{agent_id: agent_id} do
      {:ok, cap} =
        Kernel.grant_capability(
          principal_id: agent_id,
          resource_uri: "arbor://fs/read/workspace"
        )

      assert %Capability{} = cap
      assert cap.principal_id == agent_id
      assert cap.resource_uri == "arbor://fs/read/workspace"
    end

    test "grants capability with all options", %{agent_id: agent_id} do
      expires = DateTime.add(DateTime.utc_now(), 3600)

      {:ok, cap} =
        Kernel.grant_capability(
          principal_id: agent_id,
          resource_uri: "arbor://fs/write/data",
          constraints: %{rate_limit: 10},
          metadata: %{purpose: "testing"},
          expires_at: expires
        )

      assert cap.principal_id == agent_id
      assert cap.resource_uri == "arbor://fs/write/data"
      assert cap.constraints == %{rate_limit: 10}
      assert cap.metadata == %{purpose: "testing"}
      assert cap.expires_at == expires
    end

    test "stores capability in CapabilityStore", %{agent_id: agent_id} do
      {:ok, cap} =
        Kernel.grant_capability(
          principal_id: agent_id,
          resource_uri: "arbor://fs/read/stored"
        )

      assert {:ok, retrieved} = CapabilityStore.get(cap.id)
      assert retrieved.id == cap.id
      assert retrieved.principal_id == agent_id
    end

    test "raises on missing principal_id" do
      assert_raise KeyError, ~r/principal_id/, fn ->
        Kernel.grant_capability(resource_uri: "arbor://fs/read/docs")
      end
    end

    test "raises on missing resource_uri", %{agent_id: agent_id} do
      assert_raise KeyError, ~r/resource_uri/, fn ->
        Kernel.grant_capability(principal_id: agent_id)
      end
    end
  end

  describe "revoke_capability/1" do
    test "revokes an existing capability", %{agent_id: agent_id} do
      {:ok, cap} =
        Kernel.grant_capability(
          principal_id: agent_id,
          resource_uri: "arbor://fs/read/revokable"
        )

      assert {:ok, _} = CapabilityStore.get(cap.id)
      assert :ok = Kernel.revoke_capability(capability_id: cap.id)
      assert {:error, :not_found} = CapabilityStore.get(cap.id)
    end

    test "returns error for non-existent capability" do
      assert {:error, :not_found} =
               Kernel.revoke_capability(capability_id: "cap_nonexistent_#{:erlang.unique_integer([:positive])}")
    end

    test "raises on missing capability_id" do
      assert_raise KeyError, ~r/capability_id/, fn ->
        Kernel.revoke_capability([])
      end
    end
  end
end
