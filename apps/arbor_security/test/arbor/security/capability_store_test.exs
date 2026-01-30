defmodule Arbor.Security.CapabilityStoreTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Security.Capability
  alias Arbor.Security.CapabilityStore

  setup do
    # Create unique agent ID for each test
    agent_id = "agent_#{:erlang.unique_integer([:positive])}"
    {:ok, agent_id: agent_id}
  end

  # ===========================================================================
  # Phase 7: Quota enforcement tests
  # ===========================================================================

  describe "put/1 quota enforcement" do
    setup do
      # Save original config values
      original_max_per_agent = Application.get_env(:arbor_security, :max_capabilities_per_agent)
      original_max_global = Application.get_env(:arbor_security, :max_global_capabilities)
      original_max_depth = Application.get_env(:arbor_security, :max_delegation_depth)
      original_enabled = Application.get_env(:arbor_security, :quota_enforcement_enabled)

      on_exit(fn ->
        restore_config(:max_capabilities_per_agent, original_max_per_agent)
        restore_config(:max_global_capabilities, original_max_global)
        restore_config(:max_delegation_depth, original_max_depth)
        restore_config(:quota_enforcement_enabled, original_enabled)
      end)

      :ok
    end

    test "succeeds within per-agent limit", %{agent_id: agent_id} do
      Application.put_env(:arbor_security, :max_capabilities_per_agent, 5)

      for i <- 1..4 do
        {:ok, cap} = build_capability(agent_id, "arbor://fs/read/test/#{i}")
        assert {:ok, :stored} = CapabilityStore.put(cap)
      end
    end

    test "fails when per-agent limit exceeded", %{agent_id: agent_id} do
      Application.put_env(:arbor_security, :max_capabilities_per_agent, 3)

      for i <- 1..3 do
        {:ok, cap} = build_capability(agent_id, "arbor://fs/read/test/#{i}")
        {:ok, :stored} = CapabilityStore.put(cap)
      end

      # 4th should fail
      {:ok, cap4} = build_capability(agent_id, "arbor://fs/read/test/4")

      assert {:error, {:quota_exceeded, :per_agent_capability_limit, context}} =
               CapabilityStore.put(cap4)

      assert context.agent_id == agent_id
      assert context.current == 3
      assert context.limit == 3
    end

    test "fails when global limit exceeded" do
      # Get current count and set limit just above it so we have room to add exactly 2
      stats = CapabilityStore.stats()
      current_count = stats.active_capabilities
      limit = current_count + 2

      Application.put_env(:arbor_security, :max_global_capabilities, limit)
      Application.put_env(:arbor_security, :max_capabilities_per_agent, 1000)

      base = :erlang.unique_integer([:positive])

      # Should succeed (1st within limit)
      agent1 = "agent_global_test_#{base}_1"
      {:ok, cap1} = build_capability(agent1, "arbor://fs/read/test/global/#{base}/1")
      {:ok, :stored} = CapabilityStore.put(cap1)

      # Should succeed (2nd within limit)
      agent2 = "agent_global_test_#{base}_2"
      {:ok, cap2} = build_capability(agent2, "arbor://fs/read/test/global/#{base}/2")
      {:ok, :stored} = CapabilityStore.put(cap2)

      # 3rd should fail (at limit)
      agent3 = "agent_global_test_#{base}_3"
      {:ok, cap3} = build_capability(agent3, "arbor://fs/read/test/global/#{base}/3")

      assert {:error, {:quota_exceeded, :global_capability_limit, context}} =
               CapabilityStore.put(cap3)

      assert is_integer(context.current)
      assert context.limit == limit
    end

    test "fails when delegation_depth exceeds max", %{agent_id: agent_id} do
      Application.put_env(:arbor_security, :max_delegation_depth, 3)

      {:ok, cap} = build_capability(agent_id, "arbor://fs/read/test/deep", delegation_depth: 4)

      assert {:error, {:quota_exceeded, :delegation_depth_limit, context}} =
               CapabilityStore.put(cap)

      assert context.depth == 4
      assert context.limit == 3
    end

    test "succeeds when delegation_depth equals max", %{agent_id: agent_id} do
      Application.put_env(:arbor_security, :max_delegation_depth, 3)

      {:ok, cap} = build_capability(agent_id, "arbor://fs/read/test/exact", delegation_depth: 3)
      assert {:ok, :stored} = CapabilityStore.put(cap)
    end

    test "fails when delegation_depth is negative", %{agent_id: agent_id} do
      Application.put_env(:arbor_security, :max_delegation_depth, 10)

      # Manually create a capability with negative depth (bypassing validation)
      cap = %Capability{
        id: "cap_#{:erlang.unique_integer([:positive])}",
        resource_uri: "arbor://fs/read/test/negative",
        principal_id: agent_id,
        delegation_depth: -1,
        constraints: %{},
        metadata: %{},
        delegation_chain: [],
        granted_at: DateTime.utc_now()
      }

      assert {:error, {:quota_exceeded, :delegation_depth_limit, context}} =
               CapabilityStore.put(cap)

      assert context.depth == -1
      assert context.reason == :negative_depth
    end

    test "quota enforcement disabled ignores limits", %{agent_id: agent_id} do
      Application.put_env(:arbor_security, :max_capabilities_per_agent, 2)
      Application.put_env(:arbor_security, :max_delegation_depth, 1)
      Application.put_env(:arbor_security, :quota_enforcement_enabled, false)

      # Should succeed even with depth > max
      {:ok, cap1} = build_capability(agent_id, "arbor://fs/read/test/no_quota/1", delegation_depth: 10)
      assert {:ok, :stored} = CapabilityStore.put(cap1)

      # Should succeed even with > max_per_agent
      {:ok, cap2} = build_capability(agent_id, "arbor://fs/read/test/no_quota/2")
      assert {:ok, :stored} = CapabilityStore.put(cap2)

      {:ok, cap3} = build_capability(agent_id, "arbor://fs/read/test/no_quota/3")
      assert {:ok, :stored} = CapabilityStore.put(cap3)
    end

    test "revoke frees quota space", %{agent_id: agent_id} do
      Application.put_env(:arbor_security, :max_capabilities_per_agent, 2)

      {:ok, cap1} = build_capability(agent_id, "arbor://fs/read/test/revoke/1")
      {:ok, :stored} = CapabilityStore.put(cap1)

      {:ok, cap2} = build_capability(agent_id, "arbor://fs/read/test/revoke/2")
      {:ok, :stored} = CapabilityStore.put(cap2)

      # At limit
      {:ok, cap3} = build_capability(agent_id, "arbor://fs/read/test/revoke/3")
      assert {:error, {:quota_exceeded, :per_agent_capability_limit, _}} = CapabilityStore.put(cap3)

      # Revoke one
      :ok = CapabilityStore.revoke(cap1.id)

      # Now should succeed
      assert {:ok, :stored} = CapabilityStore.put(cap3)
    end
  end

  describe "stats/0 quota information" do
    test "includes quota limits in stats" do
      stats = CapabilityStore.stats()

      assert Map.has_key?(stats, :quota_max_per_agent)
      assert Map.has_key?(stats, :quota_max_global)
      assert Map.has_key?(stats, :quota_max_delegation_depth)
      assert Map.has_key?(stats, :quota_enforcement_enabled)

      assert is_integer(stats.quota_max_per_agent)
      assert is_integer(stats.quota_max_global)
      assert is_integer(stats.quota_max_delegation_depth)
      assert is_boolean(stats.quota_enforcement_enabled)
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp build_capability(agent_id, resource_uri, opts \\ []) do
    Capability.new(
      resource_uri: resource_uri,
      principal_id: agent_id,
      delegation_depth: Keyword.get(opts, :delegation_depth, 3),
      constraints: Keyword.get(opts, :constraints, %{}),
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  defp restore_config(key, nil), do: Application.delete_env(:arbor_security, key)
  defp restore_config(key, value), do: Application.put_env(:arbor_security, key, value)
end
