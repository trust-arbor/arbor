defmodule Arbor.Signals.ClusterIntegrationTest do
  @moduledoc """
  Multi-node integration tests using LocalCluster.

  These tests spin up real BEAM nodes and verify that the signal relay
  infrastructure actually propagates signals across nodes via :pg groups.

  Tagged :distributed — excluded by default, run with:
    mix test --only distributed
  """
  use ExUnit.Case, async: false

  alias Arbor.Signals.ClusterTestHelpers, as: H

  @moduletag :distributed
  @moduletag timeout: 60_000

  # Helper file to compile on remote nodes
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

  setup do
    ensure_local_signals_running()
    :ok
  end

  describe "signal relay across nodes" do
    test "cluster-scoped signal emitted on node A arrives on node B" do
      {:ok, cluster} = start_cluster(2, "relay")
      {:ok, [node_a, node_b]} = LocalCluster.nodes(cluster)

      setup_nodes([node_a, node_b])

      test_pid = self()

      :erpc.call(node_b, H, :subscribe_and_forward, ["test.*", test_pid, :signal_on_b])

      signal_id = "test_relay_#{System.unique_integer([:positive])}"

      :erpc.call(node_a, H, :emit_cluster_signal, [
        :test, :relay_check, %{id: signal_id, origin_node: node_a}
      ])

      assert_receive {:signal_on_b, signal}, 5_000
      assert signal.category == :test
      assert signal.type == :relay_check
      assert signal.data.id == signal_id

      LocalCluster.stop(cluster)
    end

    test "local-scoped signal does NOT propagate to other nodes" do
      {:ok, cluster} = start_cluster(2, "local_scope")
      {:ok, [node_a, node_b]} = LocalCluster.nodes(cluster)

      setup_nodes([node_a, node_b])

      test_pid = self()

      :erpc.call(node_b, H, :subscribe_and_forward, ["test.*", test_pid, :local_on_b])

      # Default scope is :local — should NOT relay
      :erpc.call(node_a, H, :emit_local_signal, [:test, :local_only, %{value: 42}])

      Process.sleep(300)
      refute_received {:local_on_b, _}

      LocalCluster.stop(cluster)
    end

    test "relay stats track cross-node activity" do
      {:ok, cluster} = start_cluster(2, "stats")
      {:ok, [node_a, node_b]} = LocalCluster.nodes(cluster)

      setup_nodes([node_a, node_b])

      # Emit several signals on node A
      for i <- 1..5 do
        :erpc.call(node_a, H, :emit_cluster_signal, [
          :test, :stats_check, %{i: i}
        ])
      end

      # Wait for batch flush
      Process.sleep(300)

      stats_a = :erpc.call(node_a, H, :relay_stats, [])
      assert stats_a.relayed_out >= 5
      assert stats_a.batches_sent >= 1

      stats_b = :erpc.call(node_b, H, :relay_stats, [])
      assert stats_b.relayed_in >= 5

      LocalCluster.stop(cluster)
    end

    test "three-node cluster: signal reaches all peers" do
      {:ok, cluster} = start_cluster(3, "three")
      {:ok, [node_a, node_b, node_c]} = LocalCluster.nodes(cluster)

      setup_nodes([node_a, node_b, node_c])

      test_pid = self()

      :erpc.call(node_b, H, :subscribe_and_forward, ["test.*", test_pid, :on_b])
      :erpc.call(node_c, H, :subscribe_and_forward, ["test.*", test_pid, :on_c])

      :erpc.call(node_a, H, :emit_cluster_signal, [:test, :broadcast, %{from: :a}])

      assert_receive {:on_b, _}, 5_000
      assert_receive {:on_c, _}, 5_000

      LocalCluster.stop(cluster)
    end

    test "node departure removes it from relay peers" do
      {:ok, cluster} = start_cluster(2, "departure")
      {:ok, [node_a, _node_b]} = LocalCluster.nodes(cluster)

      setup_nodes([node_a, _node_b])

      stats_before = :erpc.call(node_a, H, :relay_stats, [])
      assert stats_before.peers_connected >= 1

      # Stop node B
      {:ok, members} = LocalCluster.members(cluster)
      node_b_member = Enum.find(members, fn {:member, _pid, name} -> name != node_a end)
      LocalCluster.stop(cluster, node_b_member)

      Process.sleep(500)

      stats_after = :erpc.call(node_a, H, :relay_stats, [])
      assert stats_after.peers_connected < stats_before.peers_connected

      LocalCluster.stop(cluster)
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp start_cluster(count, prefix) do
    LocalCluster.start_link(count,
      prefix: prefix,
      applications: [:arbor_contracts, :arbor_signals],
      files: [@helper_file]
    )
  end

  defp setup_nodes(nodes) do
    for node <- nodes do
      :erpc.call(node, H, :start_signal_children, [])
    end

    # Give :pg time to propagate group membership
    Process.sleep(200)
  end

  defp ensure_local_signals_running do
    children = [
      {Arbor.Signals.Store, []},
      {Arbor.Signals.TopicKeys, []},
      {Arbor.Signals.Channels, []},
      {Arbor.Signals.Bus, []},
      {Arbor.Signals.Relay, []}
    ]

    for child <- children do
      case Supervisor.start_child(Arbor.Signals.Supervisor, child) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
        {:error, :already_present} ->
          {mod, _} = child
          Supervisor.delete_child(Arbor.Signals.Supervisor, mod)
          Supervisor.start_child(Arbor.Signals.Supervisor, child)
        _ -> :ok
      end
    end
  end
end
