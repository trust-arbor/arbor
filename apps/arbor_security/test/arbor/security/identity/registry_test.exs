defmodule Arbor.Security.Identity.RegistryTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Security.Identity
  alias Arbor.Security.Identity.Registry

  setup do
    {:ok, identity} = Identity.generate()
    {:ok, identity: identity}
  end

  describe "register/1 and lookup/1" do
    test "round-trip succeeds", %{identity: identity} do
      :ok = Registry.register(identity)

      assert {:ok, public_key} = Registry.lookup(identity.agent_id)
      assert public_key == identity.public_key
    end

    test "lookup unknown returns :not_found" do
      assert {:error, :not_found} = Registry.lookup("agent_nonexistent")
    end
  end

  describe "register/1 validation" do
    test "rejects mismatched agent_id and public_key" do
      {:ok, identity} = Identity.generate()

      # Tamper with agent_id
      tampered = %{
        identity
        | agent_id: "agent_0000000000000000000000000000000000000000000000000000000000000000"
      }

      assert {:error, {:agent_id_mismatch, _, :expected, _}} = Registry.register(tampered)
    end

    test "rejects duplicate registration", %{identity: identity} do
      :ok = Registry.register(identity)

      assert {:error, {:already_registered, _}} = Registry.register(identity)
    end
  end

  describe "registered?/1" do
    test "returns true for registered agent", %{identity: identity} do
      :ok = Registry.register(identity)
      assert Registry.registered?(identity.agent_id)
    end

    test "returns false for unknown agent" do
      refute Registry.registered?("agent_unknown")
    end
  end

  describe "deregister/1" do
    test "removes identity", %{identity: identity} do
      :ok = Registry.register(identity)
      assert Registry.registered?(identity.agent_id)

      :ok = Registry.deregister(identity.agent_id)
      refute Registry.registered?(identity.agent_id)
      assert {:error, :not_found} = Registry.lookup(identity.agent_id)
    end

    test "returns error for unknown agent" do
      assert {:error, :not_found} = Registry.deregister("agent_unknown")
    end
  end

  describe "stats/0" do
    test "tracks registration counts", %{identity: identity} do
      stats_before = Registry.stats()

      :ok = Registry.register(identity)

      stats_after = Registry.stats()
      assert stats_after.total_registered == stats_before.total_registered + 1
      assert stats_after.active_identities == stats_before.active_identities + 1
    end
  end
end
