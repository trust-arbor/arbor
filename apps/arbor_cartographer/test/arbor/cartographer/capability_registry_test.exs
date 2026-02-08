defmodule Arbor.Cartographer.CapabilityRegistryTest do
  # No async since we're managing global processes
  use ExUnit.Case, async: false

  alias Arbor.Cartographer.CapabilityRegistry

  @moduletag :fast

  # Start the registry fresh for each test
  setup do
    # Stop existing registry if running
    safe_stop(CapabilityRegistry)
    Process.sleep(50)

    # Start fresh registry
    {:ok, _pid} = CapabilityRegistry.start_link([])

    on_exit(fn ->
      safe_stop(CapabilityRegistry)
      Process.sleep(50)
    end)

    :ok
  end

  # Helper to stop a process safely
  defp safe_stop(name) do
    case Process.whereis(name) do
      nil ->
        :ok

      pid ->
        try do
          Process.unlink(pid)
          GenServer.stop(pid, :normal, 1000)
        catch
          :exit, _ -> :ok
          _, _ -> :ok
        end
    end
  rescue
    _ -> :ok
  end

  describe "register/2" do
    test "registers node capabilities" do
      capabilities = build_capabilities(:test_node, [:gpu, :high_memory])

      assert :ok = CapabilityRegistry.register(:test_node, capabilities)
    end

    test "overwrites existing registration" do
      caps1 = build_capabilities(:test_node, [:gpu])
      caps2 = build_capabilities(:test_node, [:high_memory])

      :ok = CapabilityRegistry.register(:test_node, caps1)
      :ok = CapabilityRegistry.register(:test_node, caps2)

      {:ok, result} = CapabilityRegistry.get(:test_node)
      assert :high_memory in result.tags
      refute :gpu in result.tags
    end
  end

  describe "get/1" do
    test "returns capabilities for registered node" do
      capabilities = build_capabilities(:test_node, [:gpu, :arm64])
      :ok = CapabilityRegistry.register(:test_node, capabilities)

      {:ok, result} = CapabilityRegistry.get(:test_node)
      assert result.node == :test_node
      assert :gpu in result.tags
      assert :arm64 in result.tags
    end

    test "returns error for unregistered node" do
      assert {:error, :not_found} = CapabilityRegistry.get(:unknown_node)
    end
  end

  describe "my_capabilities/0" do
    test "returns tags for current node when registered" do
      capabilities = build_capabilities(Node.self(), [:x86_64, :high_memory])
      :ok = CapabilityRegistry.register(Node.self(), capabilities)

      {:ok, tags} = CapabilityRegistry.my_capabilities()
      assert :x86_64 in tags
      assert :high_memory in tags
    end

    test "returns error when not registered" do
      assert {:error, :not_registered} = CapabilityRegistry.my_capabilities()
    end
  end

  describe "add_tags/2" do
    test "adds tags to existing registration" do
      capabilities = build_capabilities(:test_node, [:gpu])
      :ok = CapabilityRegistry.register(:test_node, capabilities)

      :ok = CapabilityRegistry.add_tags(:test_node, [:high_memory, :production])

      {:ok, result} = CapabilityRegistry.get(:test_node)
      assert :gpu in result.tags
      assert :high_memory in result.tags
      assert :production in result.tags
    end

    test "returns error for unregistered node" do
      assert {:error, :not_found} = CapabilityRegistry.add_tags(:unknown_node, [:tag])
    end

    test "deduplicates tags" do
      capabilities = build_capabilities(:test_node, [:gpu, :arm64])
      :ok = CapabilityRegistry.register(:test_node, capabilities)

      :ok = CapabilityRegistry.add_tags(:test_node, [:gpu, :new_tag])

      {:ok, result} = CapabilityRegistry.get(:test_node)
      # Should only have one :gpu
      assert Enum.count(result.tags, &(&1 == :gpu)) == 1
    end
  end

  describe "remove_tags/2" do
    test "removes tags from existing registration" do
      capabilities = build_capabilities(:test_node, [:gpu, :high_memory, :production])
      :ok = CapabilityRegistry.register(:test_node, capabilities)

      :ok = CapabilityRegistry.remove_tags(:test_node, [:production])

      {:ok, result} = CapabilityRegistry.get(:test_node)
      assert :gpu in result.tags
      assert :high_memory in result.tags
      refute :production in result.tags
    end

    test "returns ok for unregistered node" do
      assert :ok = CapabilityRegistry.remove_tags(:unknown_node, [:tag])
    end
  end

  describe "list_all/0" do
    test "returns empty list when no registrations" do
      assert {:ok, []} = CapabilityRegistry.list_all()
    end

    test "returns all registered capabilities" do
      caps1 = build_capabilities(:node1, [:gpu])
      caps2 = build_capabilities(:node2, [:high_memory])

      :ok = CapabilityRegistry.register(:node1, caps1)
      :ok = CapabilityRegistry.register(:node2, caps2)

      {:ok, all} = CapabilityRegistry.list_all()
      assert length(all) == 2

      nodes = Enum.map(all, & &1.node)
      assert :node1 in nodes
      assert :node2 in nodes
    end
  end

  describe "find_nodes/2" do
    setup do
      # Register some test nodes
      :ok =
        CapabilityRegistry.register(
          :node1,
          build_capabilities(:node1, [:gpu, :high_memory], 20.0)
        )

      :ok = CapabilityRegistry.register(:node2, build_capabilities(:node2, [:gpu], 50.0))
      :ok = CapabilityRegistry.register(:node3, build_capabilities(:node3, [:high_memory], 10.0))
      :ok
    end

    test "finds nodes with required capabilities" do
      {:ok, nodes} = CapabilityRegistry.find_nodes([:gpu])
      assert :node1 in nodes
      assert :node2 in nodes
      refute :node3 in nodes
    end

    test "finds nodes with multiple required capabilities" do
      {:ok, nodes} = CapabilityRegistry.find_nodes([:gpu, :high_memory])
      assert nodes == [:node1]
    end

    test "returns empty list when no nodes match" do
      {:ok, nodes} = CapabilityRegistry.find_nodes([:coral_tpu])
      assert nodes == []
    end

    test "filters by max_load" do
      {:ok, nodes} = CapabilityRegistry.find_nodes([:gpu], max_load: 30)
      assert :node1 in nodes
      refute :node2 in nodes
    end

    test "limits results" do
      {:ok, nodes} = CapabilityRegistry.find_nodes([], limit: 2)
      assert length(nodes) == 2
    end

    test "sorts by load ascending" do
      {:ok, nodes} = CapabilityRegistry.find_nodes([])
      # Should be sorted by load: node3 (10), node1 (20), node2 (50)
      assert List.first(nodes) == :node3
    end
  end

  describe "nodes_with_tag/1" do
    setup do
      :ok = CapabilityRegistry.register(:node1, build_capabilities(:node1, [:gpu, :production]))
      :ok = CapabilityRegistry.register(:node2, build_capabilities(:node2, [:gpu, :staging]))
      :ok = CapabilityRegistry.register(:node3, build_capabilities(:node3, [:production]))
      :ok
    end

    test "returns nodes with specific tag" do
      {:ok, nodes} = CapabilityRegistry.nodes_with_tag(:production)
      assert :node1 in nodes
      assert :node3 in nodes
      refute :node2 in nodes
    end

    test "returns empty list for unknown tag" do
      {:ok, nodes} = CapabilityRegistry.nodes_with_tag(:unknown_tag)
      assert nodes == []
    end
  end

  describe "node_has_capabilities?/2" do
    setup do
      :ok =
        CapabilityRegistry.register(
          :test_node,
          build_capabilities(:test_node, [:gpu, :high_memory])
        )

      :ok
    end

    test "returns true when node has all capabilities" do
      assert CapabilityRegistry.node_has_capabilities?(:test_node, [:gpu])
      assert CapabilityRegistry.node_has_capabilities?(:test_node, [:gpu, :high_memory])
    end

    test "returns false when node missing capabilities" do
      refute CapabilityRegistry.node_has_capabilities?(:test_node, [:coral_tpu])
      refute CapabilityRegistry.node_has_capabilities?(:test_node, [:gpu, :coral_tpu])
    end

    test "returns false for unregistered node" do
      refute CapabilityRegistry.node_has_capabilities?(:unknown_node, [:gpu])
    end
  end

  describe "load tracking" do
    setup do
      :ok = CapabilityRegistry.register(:test_node, build_capabilities(:test_node, [:gpu], 25.0))
      :ok
    end

    test "update_load/2 updates load score" do
      :ok = CapabilityRegistry.update_load(:test_node, 75.0)

      {:ok, load} = CapabilityRegistry.get_load(:test_node)
      assert load == 75.0
    end

    test "get_load/1 returns load for registered node" do
      {:ok, load} = CapabilityRegistry.get_load(:test_node)
      assert load == 25.0
    end

    test "get_load/1 returns error for unknown node" do
      assert {:error, :not_found} = CapabilityRegistry.get_load(:unknown_node)
    end

    test "get_all_loads/0 returns all load scores" do
      :ok = CapabilityRegistry.register(:node2, build_capabilities(:node2, [], 50.0))

      {:ok, loads} = CapabilityRegistry.get_all_loads()
      assert Map.get(loads, :test_node) == 25.0
      assert Map.get(loads, :node2) == 50.0
    end
  end

  describe "unregister/1" do
    test "removes node from registry" do
      :ok = CapabilityRegistry.register(:test_node, build_capabilities(:test_node, [:gpu]))

      :ok = CapabilityRegistry.unregister(:test_node)

      assert {:error, :not_found} = CapabilityRegistry.get(:test_node)
    end
  end

  # Helper to build test capabilities
  defp build_capabilities(node, tags, load \\ 0.0) do
    %{
      node: node,
      tags: tags,
      hardware: %{
        arch: :x86_64,
        cpus: 8,
        memory_gb: 32.0,
        gpu: nil,
        accelerators: []
      },
      load: load,
      registered_at: DateTime.utc_now()
    }
  end
end
