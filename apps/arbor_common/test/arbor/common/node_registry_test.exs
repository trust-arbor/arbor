defmodule Arbor.Common.NodeRegistryTest do
  use ExUnit.Case, async: false

  alias Arbor.Common.NodeRegistry

  @moduletag :fast

  setup do
    start_supervised!(NodeRegistry)
    :ok
  end

  # ===========================================================================
  # Zone defaults (disabled mode)
  # ===========================================================================

  describe "trust_zone/1 (zones disabled)" do
    test "returns Zone 2 for local node" do
      assert NodeRegistry.trust_zone(node()) == 2
    end

    test "returns Zone 2 for any node when zones disabled" do
      assert NodeRegistry.trust_zone(:unknown@host) == 2
    end
  end

  describe "zones_disabled?/0" do
    test "disabled by default" do
      assert NodeRegistry.zones_disabled?()
    end

    test "enabled when config is a map" do
      original = Application.get_env(:arbor_common, :trust_zones)

      try do
        Application.put_env(:arbor_common, :trust_zones, %{
          node() => %{zone: 2, apps: []}
        })

        refute NodeRegistry.zones_disabled?()
      after
        if original do
          Application.put_env(:arbor_common, :trust_zones, original)
        else
          Application.delete_env(:arbor_common, :trust_zones)
        end
      end
    end
  end

  # ===========================================================================
  # Node registration
  # ===========================================================================

  describe "register_node/2" do
    test "registers a node with zone info" do
      assert :ok = NodeRegistry.register_node(:worker@host, %{zone: 1, apps: [:arbor_agent]})
      assert NodeRegistry.trust_zone(:worker@host) == 1
    end

    test "overrides existing registration" do
      NodeRegistry.register_node(:worker@host, %{zone: 1, apps: []})
      assert NodeRegistry.trust_zone(:worker@host) == 1

      NodeRegistry.register_node(:worker@host, %{zone: 0, apps: []})
      assert NodeRegistry.trust_zone(:worker@host) == 0
    end
  end

  # ===========================================================================
  # Zone queries
  # ===========================================================================

  describe "list_nodes/0" do
    test "returns all registered nodes" do
      nodes = NodeRegistry.list_nodes()
      # Local node is always registered
      assert nodes != []
      assert Enum.any?(nodes, fn {n, _} -> n == node() end)
    end
  end

  describe "nodes_in_zone/1" do
    test "filters by zone" do
      NodeRegistry.register_node(:worker@host, %{zone: 1, apps: []})
      NodeRegistry.register_node(:gateway@host, %{zone: 0, apps: []})

      zone_0 = NodeRegistry.nodes_in_zone(0)
      assert :gateway@host in zone_0
      refute :worker@host in zone_0

      zone_1 = NodeRegistry.nodes_in_zone(1)
      assert :worker@host in zone_1
    end
  end

  describe "local_zone/0" do
    test "returns zone for local node" do
      # Disabled mode → Zone 2
      assert NodeRegistry.local_zone() == 2
    end
  end

  # ===========================================================================
  # Cross-zone access rules
  # ===========================================================================

  describe "can_access?/2" do
    test "same zone always allowed" do
      assert :ok = NodeRegistry.can_access?(0, 0)
      assert :ok = NodeRegistry.can_access?(1, 1)
      assert :ok = NodeRegistry.can_access?(2, 2)
    end

    test "higher zone can access lower" do
      assert :ok = NodeRegistry.can_access?(2, 1)
      assert :ok = NodeRegistry.can_access?(2, 0)
      assert :ok = NodeRegistry.can_access?(1, 0)
    end

    test "zone 0 to zone 2 is blocked" do
      assert {:error, {:zone_violation, 0, 2}} = NodeRegistry.can_access?(0, 2)
    end

    test "zone 0 to zone 1 is allowed (with sanitization)" do
      assert :ok = NodeRegistry.can_access?(0, 1)
    end

    test "zone 1 to zone 2 is allowed (with sanitization)" do
      assert :ok = NodeRegistry.can_access?(1, 2)
    end
  end

  # ===========================================================================
  # Resolution rules
  # ===========================================================================

  describe "can_resolve?/2" do
    test "zone 2 entries only from zone 2" do
      assert NodeRegistry.can_resolve?(2, 2)
      refute NodeRegistry.can_resolve?(1, 2)
      refute NodeRegistry.can_resolve?(0, 2)
    end

    test "zone 1 entries from zone 1 and 2" do
      assert NodeRegistry.can_resolve?(2, 1)
      assert NodeRegistry.can_resolve?(1, 1)
      refute NodeRegistry.can_resolve?(0, 1)
    end

    test "zone 0 entries from anywhere" do
      assert NodeRegistry.can_resolve?(2, 0)
      assert NodeRegistry.can_resolve?(1, 0)
      assert NodeRegistry.can_resolve?(0, 0)
    end
  end

  # ===========================================================================
  # Edge cases
  # ===========================================================================

  describe "edge cases" do
    test "trust_zone for unregistered node returns 0 when zones enabled" do
      original = Application.get_env(:arbor_common, :trust_zones)

      try do
        Application.put_env(:arbor_common, :trust_zones, %{
          node() => %{zone: 2, apps: []}
        })

        # Unknown node in enabled mode → Zone 0 (hostile)
        assert NodeRegistry.trust_zone(:unknown_node@somewhere) == 0
      after
        if original do
          Application.put_env(:arbor_common, :trust_zones, original)
        else
          Application.delete_env(:arbor_common, :trust_zones)
        end
      end
    end

    test "trust_zone works when ETS table doesn't exist" do
      # Stop the registry
      stop_supervised!(NodeRegistry)

      # Should return safe default
      result = NodeRegistry.trust_zone(:any@node)
      assert result in [0, 2]
    end
  end
end
