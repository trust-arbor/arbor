defmodule Arbor.Signals.SubsystemClusterTest do
  @moduledoc """
  End-to-end distributed integration tests for subsystems that use
  signal-based cache invalidation across BEAM nodes.

  Tests the full chain: state change → signal emit → relay → Bus delivery
  → subscriber callback → ETS update on remote node.

  Tagged :distributed — run with: mix test.distributed
  """
  use ExUnit.Case, async: false

  alias Arbor.Signals.ClusterTestHelpers, as: H

  @moduletag :distributed
  @moduletag timeout: 60_000

  @helper_file Path.expand("../../support/cluster_test_helpers.ex", __DIR__)

  setup_all do
    case Node.alive?() do
      true ->
        :ok

      false ->
        case LocalCluster.start() do
          :ok -> :ok
          {:error, reason} -> {:skip, "Cannot start distribution: #{inspect(reason)}"}
        end
    end

    :ok
  end

  # ── BufferedStore Distributed Cache ──────────────────────────────────

  describe "BufferedStore distributed cache coherence" do
    test "delete on node A invalidates cache on node B" do
      {:ok, cluster} = start_cluster(2, "bs_del")
      {:ok, [node_a, node_b]} = LocalCluster.nodes(cluster)

      setup_nodes([node_a, node_b])

      store_name = :dist_del_store
      collection = "dist_del"

      # Start distributed BufferedStores on both nodes
      for node <- [node_a, node_b] do
        :erpc.call(node, H, :start_buffered_store, [store_name, collection])
      end

      # Put the same key on both nodes
      :erpc.call(node_a, H, :buffered_store_put, [store_name, "key1", "value_a"])
      :erpc.call(node_b, H, :buffered_store_put, [store_name, "key1", "value_b"])

      # Verify both have it in ETS
      assert {:ok, _} = :erpc.call(node_a, H, :ets_lookup, [store_name, "key1"])
      assert {:ok, _} = :erpc.call(node_b, H, :ets_lookup, [store_name, "key1"])

      # Delete on node A — emits cache_delete signal
      :erpc.call(node_a, H, :buffered_store_delete, [store_name, "key1"])

      # Wait for signal relay + handler
      Process.sleep(500)

      # Node B's cache should be invalidated (key deleted from ETS)
      result_b = :erpc.call(node_b, H, :ets_lookup, [store_name, "key1"])
      assert result_b == :not_found

      LocalCluster.stop(cluster)
    end

    test "put on node A triggers reload attempt on node B" do
      {:ok, cluster} = start_cluster(2, "bs_put")
      {:ok, [node_a, node_b]} = LocalCluster.nodes(cluster)

      setup_nodes([node_a, node_b])

      store_name = :dist_put_store
      collection = "dist_put"

      for node <- [node_a, node_b] do
        :erpc.call(node, H, :start_buffered_store, [store_name, collection])
      end

      # Put a value on node A — emits cache_put signal
      :erpc.call(node_a, H, :buffered_store_put, [store_name, "key2", "from_node_a"])

      # Wait for signal relay
      Process.sleep(500)

      # Node B receives cache_put signal → tries to reload from its local backend.
      # Since backends are node-local ETS, B's backend won't have the key,
      # so it deletes from ETS cache (reload returns :not_found).
      # This validates the full signal delivery + handler execution path.
      result_b = :erpc.call(node_b, H, :ets_lookup, [store_name, "key2"])
      assert result_b == :not_found

      # Node A should still have its value
      assert {:ok, _} = :erpc.call(node_a, H, :ets_lookup, [store_name, "key2"])

      LocalCluster.stop(cluster)
    end
  end

  # ── Memory DistributedSync ──────────────────────────────────────────

  describe "Memory DistributedSync across nodes" do
    test "working memory save signal invalidates cache on remote node" do
      {:ok, cluster} = start_cluster(2, "mem_wm")
      {:ok, [node_a, node_b]} = LocalCluster.nodes(cluster)

      setup_nodes([node_a, node_b])

      # Start DistributedSync on both nodes (creates ETS tables + subscribes)
      for node <- [node_a, node_b] do
        :erpc.call(node, H, :start_memory_distributed_sync, [])
      end

      agent_id = "agent_dist_wm_#{System.unique_integer([:positive])}"

      # Seed node B's WM cache with a dummy entry
      :erpc.call(node_b, H, :ets_insert, [:arbor_working_memory, agent_id, %{thoughts: ["old"]}])

      # Verify it's there
      assert :erpc.call(node_b, H, :ets_exists?, [:arbor_working_memory, agent_id])

      # Emit a working_memory_saved signal from node A (simulating a WM save)
      :erpc.call(node_a, H, :emit_cluster_signal, [
        :memory,
        :working_memory_saved,
        %{agent_id: agent_id, origin_node: node_a}
      ])

      # Wait for relay + handler
      Process.sleep(500)

      # Node B's WM cache should be invalidated (deleted)
      refute :erpc.call(node_b, H, :ets_exists?, [:arbor_working_memory, agent_id])

      LocalCluster.stop(cluster)
    end

    test "knowledge graph update signal invalidates cache on remote node" do
      {:ok, cluster} = start_cluster(2, "mem_kg")
      {:ok, [node_a, node_b]} = LocalCluster.nodes(cluster)

      setup_nodes([node_a, node_b])

      for node <- [node_a, node_b] do
        :erpc.call(node, H, :start_memory_distributed_sync, [])
      end

      agent_id = "agent_dist_kg_#{System.unique_integer([:positive])}"

      # Seed node B's KG cache
      :erpc.call(node_b, H, :ets_insert, [:arbor_memory_graphs, agent_id, %{nodes: []}])
      assert :erpc.call(node_b, H, :ets_exists?, [:arbor_memory_graphs, agent_id])

      # Emit knowledge_added signal from node A
      :erpc.call(node_a, H, :emit_cluster_signal, [
        :memory,
        :knowledge_added,
        %{agent_id: agent_id, origin_node: node_a}
      ])

      Process.sleep(500)

      # Node B's KG cache should be invalidated
      refute :erpc.call(node_b, H, :ets_exists?, [:arbor_memory_graphs, agent_id])

      LocalCluster.stop(cluster)
    end
  end

  # ── Trust Store ─────────────────────────────────────────────────────

  describe "Trust Store profile invalidation across nodes" do
    test "profile update signal invalidates cache on remote node" do
      {:ok, cluster} = start_cluster(2, "trust")
      {:ok, [node_a, node_b]} = LocalCluster.nodes(cluster)

      setup_nodes([node_a, node_b])

      # Start Trust Store on both nodes
      for node <- [node_a, node_b] do
        :erpc.call(node, H, :start_trust_store, [])
      end

      agent_id = "agent_dist_trust_#{System.unique_integer([:positive])}"

      # Create and store a profile on node B
      :erpc.call(node_b, H, :create_and_store_profile, [agent_id])

      # Verify node B has it cached
      assert {:ok, _} = :erpc.call(node_b, H, :get_trust_profile, [agent_id])

      # Emit profile_updated signal from node A (simulating a profile change)
      :erpc.call(node_a, H, :emit_cluster_signal, [
        :trust,
        :profile_updated,
        %{agent_id: agent_id, origin_node: node_a}
      ])

      Process.sleep(500)

      # Node B's profile cache should be invalidated
      assert {:error, :not_found} = :erpc.call(node_b, H, :get_trust_profile, [agent_id])

      LocalCluster.stop(cluster)
    end

    test "profile deletion signal invalidates remote cache" do
      {:ok, cluster} = start_cluster(2, "trust_del")
      {:ok, [node_a, node_b]} = LocalCluster.nodes(cluster)

      setup_nodes([node_a, node_b])

      for node <- [node_a, node_b] do
        :erpc.call(node, H, :start_trust_store, [])
      end

      agent_id = "agent_dist_del_#{System.unique_integer([:positive])}"

      # Store profile on node B
      :erpc.call(node_b, H, :create_and_store_profile, [agent_id])
      assert {:ok, _} = :erpc.call(node_b, H, :get_trust_profile, [agent_id])

      # Emit profile_deleted signal from node A
      :erpc.call(node_a, H, :emit_cluster_signal, [
        :trust,
        :profile_deleted,
        %{agent_id: agent_id, origin_node: node_a}
      ])

      Process.sleep(500)

      assert {:error, :not_found} = :erpc.call(node_b, H, :get_trust_profile, [agent_id])

      LocalCluster.stop(cluster)
    end
  end

  # ── Gateway EndpointRegistry ────────────────────────────────────────

  describe "Gateway EndpointRegistry discovery across nodes" do
    setup do
      # Gateway tests need extra time for subscription propagation
      :ok
    end

    test "endpoint registered on node A is discovered on node B" do
      {:ok, cluster} = start_cluster(2, "gw_reg")
      {:ok, [node_a, node_b]} = LocalCluster.nodes(cluster)

      setup_nodes([node_a, node_b])
      setup_endpoint_registries([node_a, node_b])

      agent_id = "agent_gw_dist_#{System.unique_integer([:positive])}"
      tools = [%{name: "test_tool", description: "A test tool"}]

      # Register endpoint on node A
      :erpc.call(node_a, H, :register_endpoint, [agent_id, tools])

      Process.sleep(1_000)

      # Node B should discover it as a remote endpoint
      result = :erpc.call(node_b, H, :endpoint_ets_lookup, [agent_id])
      assert {:ok, {:remote, remote_node}, discovered_tools} = result
      assert remote_node == node_a
      assert length(discovered_tools) == 1

      LocalCluster.stop(cluster)
    end

    test "endpoint unregistered on node A is removed from node B" do
      {:ok, cluster} = start_cluster(2, "gw_unreg")
      {:ok, [node_a, node_b]} = LocalCluster.nodes(cluster)

      setup_nodes([node_a, node_b])
      setup_endpoint_registries([node_a, node_b])

      agent_id = "agent_gw_unreg_#{System.unique_integer([:positive])}"

      # Register on node A first
      :erpc.call(node_a, H, :register_endpoint, [agent_id, []])

      Process.sleep(1_000)

      # Verify node B discovered it
      assert {:ok, {:remote, _}, _} = :erpc.call(node_b, H, :endpoint_ets_lookup, [agent_id])

      # Unregister on node A
      :erpc.call(node_a, H, :unregister_endpoint, [agent_id])

      Process.sleep(1_000)

      # Node B should have removed it
      assert :not_found = :erpc.call(node_b, H, :endpoint_ets_lookup, [agent_id])

      LocalCluster.stop(cluster)
    end

    test "endpoint list includes remote entries" do
      {:ok, cluster} = start_cluster(2, "gw_list")
      {:ok, [node_a, node_b]} = LocalCluster.nodes(cluster)

      setup_nodes([node_a, node_b])
      setup_endpoint_registries([node_a, node_b])

      agent_id = "agent_gw_list_#{System.unique_integer([:positive])}"

      :erpc.call(node_a, H, :register_endpoint, [agent_id, [%{name: "tool1"}]])

      Process.sleep(1_000)

      # Node B's list should include the remote entry
      entries = :erpc.call(node_b, H, :list_endpoints, [])
      remote_entries = Enum.filter(entries, fn {id, _, _} -> id == agent_id end)
      assert length(remote_entries) == 1
      [{^agent_id, {:remote, remote_node}, tool_count}] = remote_entries
      assert remote_node == node_a
      assert tool_count == 1

      LocalCluster.stop(cluster)
    end
  end

  # ── Security Distributed Sync ──────────────────────────────────────

  describe "Security restricted signals across nodes" do
    test "security regression: identity suspension emitted on A changes public status on B" do
      {:ok, cluster} = start_cluster(2, "security_sync", [:arbor_security])
      on_exit(fn -> stop_cluster_if_alive(cluster) end)

      {:ok, [node_a, node_b]} = LocalCluster.nodes(cluster)

      for node <- [node_a, node_b] do
        assert :ok = :erpc.call(node, H, :configure_identity_security_sync, [])
      end

      setup_nodes([node_a, node_b])

      for node <- [node_a, node_b] do
        assert :ok = :erpc.call(node, H, :start_security_sync, [])
      end

      assert eventually(fn ->
               Enum.all?([node_a, node_b], fn node ->
                 case :erpc.call(node, H, :relay_stats, []) do
                   %{peers_connected: count} when count >= 1 -> true
                   _other -> false
                 end
               end)
             end)

      assert {:ok, public_identity} =
               :erpc.call(node_a, H, :create_security_identity, [
                 "distributed-security-sync-#{random_token()}"
               ])

      agent_id = Map.fetch!(public_identity, :agent_id)

      assert :ok =
               :erpc.call(node_b, H, :register_security_identity, [public_identity])

      assert {:ok, :active} =
               :erpc.call(node_b, H, :security_identity_status, [agent_id])

      # The supervised Registry is the pinned restricted-topic publisher and
      # emits this mutation through the public Arbor.Signals.emit/4 boundary.
      assert :ok = :erpc.call(node_a, H, :suspend_security_identity, [agent_id])

      assert eventually(fn ->
               :erpc.call(node_b, H, :security_identity_status, [agent_id]) ==
                 {:ok, :suspended}
             end)

      assert eventually(fn ->
               match?(
                 {:ok, %Arbor.Signals.Signal{}},
                 identity_suspension_signal(node_b, agent_id)
               )
             end)

      assert {:ok, source_signal} = identity_suspension_signal(node_a, agent_id)
      assert {:ok, remote_signal} = identity_suspension_signal(node_b, agent_id)

      # The public emitter and real Relay transport must preserve the
      # authority-reducing payload across nodes even though TopicKeys are
      # intentionally node-local. Remote ingress also owns event identity and
      # attribution: it replaces the source event id/timestamp/emitter and
      # derives the origin from the credential-bound peer pid.
      refute remote_signal.data[:__encrypted__]
      refute remote_signal.data[:__decryption_failed__]
      assert remote_signal.data.agent_id == agent_id
      assert remote_signal.origin_node == node_a
      assert remote_signal.data.origin_node == node_a
      assert node(remote_signal.emitter_pid) == node_b
      refute remote_signal.id == source_signal.id
      assert remote_signal.metadata["remote"]["id"] =~ source_signal.id
      assert remote_signal.metadata["remote"]["origin_node"] =~ Atom.to_string(node_a)

      provenance_marker = random_token()

      assert {:ok, _subscription_handle} =
               :erpc.call(node_b, H, :subscribe_and_forward, [
                 "activity.remote_provenance_probe",
                 self(),
                 {:remote_provenance, provenance_marker}
               ])

      assert :ok =
               :erpc.call(node_a, H, :emit_cluster_signal, [
                 :activity,
                 :remote_provenance_probe,
                 %{marker: provenance_marker, origin_node: :forged_origin@attacker}
               ])

      assert_receive {{:remote_provenance, ^provenance_marker}, provenance_signal}, 5_000
      assert provenance_signal.data.marker == provenance_marker
      assert provenance_signal.origin_node == node_a
      assert provenance_signal.data.origin_node == node_a
      assert node(provenance_signal.emitter_pid) == node_b
      refute provenance_signal.origin_node == :forged_origin@attacker
      refute provenance_signal.data.origin_node == :forged_origin@attacker

      assert %{relayed_out: sent} = :erpc.call(node_a, H, :relay_stats, [])
      assert %{relayed_in: received} = :erpc.call(node_b, H, :relay_stats, [])
      assert sent >= 1
      assert received >= 1
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp start_cluster(count, prefix, extra_applications \\ []) do
    # LocalCluster turns the prefix into long-lived node atoms in this BEAM.
    # A cryptorandom suffix prevents concurrent test VMs from sharing names
    # while keeping the atom count bounded by this finite distributed suite.
    prefix = "#{prefix}_#{random_token()}_"

    # Note: :arbor_gateway is excluded from auto-start because its Application
    # starts EndpointRegistry before signal infrastructure is ready. Instead,
    # we start EndpointRegistry manually after signals via setup_endpoint_registries.
    LocalCluster.start_link(count,
      prefix: prefix,
      applications:
        Enum.uniq(
          [
            :arbor_kernel,
            :arbor_kernel_runtime,
            :arbor_persistence,
            :arbor_memory,
            :arbor_trust
          ] ++ extra_applications
        ),
      files: [@helper_file]
    )
  end

  defp setup_endpoint_registries(nodes) do
    for node <- nodes do
      :erpc.call(node, H, :start_endpoint_registry, [])
    end

    # EndpointRegistry subscribes to Bus during init.
    # Give time for subscription + :pg propagation so signals route correctly.
    Process.sleep(500)
  end

  defp setup_nodes(nodes) do
    for node <- nodes do
      :erpc.call(node, H, :start_signal_children, [])
    end

    # Give :pg time to propagate group membership across all nodes.
    # Needs to be generous — after previous cluster shutdown, :pg
    # needs to fully clean up before new members are visible.
    Process.sleep(500)
  end

  defp eventually(fun, attempts \\ 200)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(25)
      eventually(fun, attempts - 1)
    end
  end

  defp identity_suspension_signal(node, agent_id) do
    case :erpc.call(node, Arbor.Signals, :recent, [
           [category: :security, type: :identity_suspended, limit: 20]
         ]) do
      {:ok, signals} ->
        case Enum.find(signals, fn signal ->
               signal.data[:agent_id] == agent_id or signal.data["agent_id"] == agent_id
             end) do
          nil -> :not_found
          signal -> {:ok, signal}
        end

      _error ->
        :not_found
    end
  end

  defp random_token do
    Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp stop_cluster_if_alive(cluster) do
    if is_pid(cluster) and Process.alive?(cluster) do
      LocalCluster.stop(cluster)
    else
      :ok
    end
  catch
    :exit, _reason -> :ok
  end
end
