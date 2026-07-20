defmodule Arbor.Comms.InteractionRegistryClusterTest do
  use ExUnit.Case, async: false

  alias Arbor.Comms.InteractionRegistry
  alias Arbor.Comms.InteractionRouter
  alias Arbor.Contracts.Comms.Interaction

  @moduletag :distributed
  @moduletag :external
  @moduletag timeout: 60_000

  setup_all do
    cond do
      not Code.ensure_loaded?(LocalCluster) ->
        {:skip, "LocalCluster is unavailable"}

      Node.alive?() ->
        :ok

      true ->
        case LocalCluster.start() do
          :ok -> :ok
          {:error, reason} -> {:skip, "cannot start distribution: #{inspect(reason)}"}
        end
    end
  end

  test "security regression: peer response terminalizes only on origin authority" do
    prefix = "interaction_authority_#{System.unique_integer([:positive])}"

    assert {:ok, cluster} =
             LocalCluster.start_link(2,
               prefix: prefix,
               applications: [
                 :arbor_contracts,
                 :arbor_common,
                 :arbor_signals,
                 :arbor_security,
                 :arbor_shell,
                 :arbor_comms
               ]
             )

    assert {:ok, [origin_node, peer_node]} = LocalCluster.nodes(cluster)

    request_id = "irq_cluster_#{System.unique_integer([:positive])}"

    assert {:ok, interaction} =
             :erpc.call(origin_node, Interaction, :new, [
               %{
                 request_id: request_id,
                 kind: :approval,
                 agent_id: "agent_cluster",
                 user_id: "operator_cluster",
                 description: "cluster authority"
               }
             ])

    assert {:ok, ^interaction} =
             :erpc.call(origin_node, InteractionRegistry, :put, [interaction])

    assert_eventually(fn ->
      :erpc.call(peer_node, InteractionRegistry, :authority_for, [request_id]) ==
        {:ok, origin_node}
    end)

    assert {:ok, ^interaction} =
             :erpc.call(peer_node, InteractionRegistry, :resolve, [
               request_id,
               [response: :approved, metadata: %{decision: :approve}]
             ])

    assert {:ok, origin_terminal} =
             :erpc.call(origin_node, InteractionRegistry, :get_terminal, [request_id])

    assert origin_terminal.status == :responded
    assert origin_terminal.decision == :approved
    assert origin_terminal.authority_node == origin_node

    assert_eventually(fn ->
      :erpc.call(peer_node, InteractionRegistry, :get_terminal, [request_id]) ==
        {:ok, origin_terminal}
    end)

    assert {:error, {:already_terminal, :responded}} =
             :erpc.call(origin_node, InteractionRegistry, :abandon, [request_id, :owner_timeout])

    assert :ok = LocalCluster.stop(cluster)
  end

  test "security regression: captured peer waiter deadline rejects late approval without timeout cleanup" do
    prefix = "interaction_deadline_#{System.unique_integer([:positive])}"

    assert {:ok, cluster} =
             LocalCluster.start_link(2,
               prefix: prefix,
               applications: [
                 :arbor_contracts,
                 :arbor_common,
                 :arbor_signals,
                 :arbor_security,
                 :arbor_shell,
                 :arbor_comms
               ]
             )

    assert {:ok, [origin_node, peer_node]} = LocalCluster.nodes(cluster)
    request_id = "irq_deadline_#{System.unique_integer([:positive])}"

    assert {:ok, interaction} =
             :erpc.call(origin_node, Interaction, :new, [
               %{
                 request_id: request_id,
                 kind: :approval,
                 agent_id: "agent_cluster",
                 user_id: "operator_cluster",
                 description: "captured peer deadline"
               }
             ])

    assert {:ok, ^interaction} =
             :erpc.call(origin_node, InteractionRegistry, :put, [interaction])

    assert_eventually(fn ->
      :erpc.call(peer_node, InteractionRegistry, :authority_for, [request_id]) ==
        {:ok, origin_node}
    end)

    # A zero-timeout peer waiter subscribes, captures, and arms the origin in
    # one RPC. The arm itself terminalizes, so no timeout-finalization cleanup
    # RPC is needed for the later approval to fail.
    assert {:error, :timeout} =
             :erpc.call(peer_node, InteractionRouter, :await_response, [
               request_id,
               "agent_cluster",
               [timeout: 0]
             ])

    assert {:ok, terminal} =
             :erpc.call(origin_node, InteractionRegistry, :get_terminal, [request_id])

    assert terminal.status == :abandoned
    assert terminal.authority_node == origin_node

    assert {:error, {:already_terminal, :abandoned}} =
             :erpc.call(origin_node, InteractionRegistry, :resolve, [
               request_id,
               [response: :approved, metadata: %{decision: :approve}]
             ])

    assert :ok = LocalCluster.stop(cluster)
  end

  defp assert_eventually(fun, attempts \\ 200)

  defp assert_eventually(_fun, 0), do: flunk("cluster state did not converge")

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end
end
