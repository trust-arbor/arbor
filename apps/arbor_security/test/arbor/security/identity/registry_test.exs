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

  describe "lookup_by_name/1" do
    test "finds agents by name" do
      {:ok, identity} = Identity.generate(name: "code-reviewer")
      :ok = Registry.register(identity)

      assert {:ok, [agent_id]} = Registry.lookup_by_name("code-reviewer")
      assert agent_id == identity.agent_id
    end

    test "returns multiple agents with the same name" do
      {:ok, id1} = Identity.generate(name: "worker")
      {:ok, id2} = Identity.generate(name: "worker")
      :ok = Registry.register(id1)
      :ok = Registry.register(id2)

      assert {:ok, agent_ids} = Registry.lookup_by_name("worker")
      assert length(agent_ids) == 2
      assert id1.agent_id in agent_ids
      assert id2.agent_id in agent_ids
    end

    test "returns not_found for unknown name" do
      assert {:error, :not_found} = Registry.lookup_by_name("nonexistent")
    end

    test "unnamed agents are not indexed" do
      {:ok, identity} = Identity.generate()
      :ok = Registry.register(identity)

      # nil name should not be indexed
      assert {:error, :not_found} = Registry.lookup_by_name("nil")
    end
  end

  describe "deregister removes name index" do
    test "name lookup fails after deregister" do
      {:ok, identity} = Identity.generate(name: "temp-agent")
      :ok = Registry.register(identity)

      assert {:ok, _} = Registry.lookup_by_name("temp-agent")

      :ok = Registry.deregister(identity.agent_id)

      # Name index should have empty list, returning not_found
      result = Registry.lookup_by_name("temp-agent")
      assert result == {:error, :not_found} or match?({:ok, []}, result)
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
