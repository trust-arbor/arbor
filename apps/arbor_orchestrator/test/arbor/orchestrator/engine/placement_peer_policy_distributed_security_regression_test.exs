defmodule Arbor.Orchestrator.Engine.PlacementPeerPolicyDistributedSecurityRegressionTest do
  @moduledoc """
  Security regression for the placement peer policy against a real connected
  peer (LocalCluster).

  A connected peer is what reaches the resolve-time check: `Placement.resolve/1`
  must refuse an unlisted peer, and the executor must fail the node rather than
  fall back to local execution (even without `placement_required`). A listed
  peer still runs the handler remotely.

  Run: `./bin/mix test path/to/this_file.exs --include distributed`
  """

  use ExUnit.Case, async: false

  @moduletag :distributed
  @moduletag :integration
  @moduletag :security_regression
  @moduletag timeout: 120_000

  alias Arbor.Orchestrator.Engine.{Context, Executor, Placement}
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node, as: GNode
  alias Arbor.Orchestrator.Handlers.StartHandler

  @app :arbor_orchestrator

  setup_all do
    if not Node.alive?() do
      :ok = LocalCluster.start()
      on_exit(fn -> LocalCluster.stop() end)
    end

    # A private cookie keeps this test node (and its peer, which inherits the
    # cookie) from ever authenticating to another local Arbor node.
    Node.set_cookie(:"placement_peer_policy_#{System.unique_integer([:positive])}")

    {:ok, cluster} =
      LocalCluster.start_link(1, prefix: "placement-peer-policy-", applications: [])

    {:ok, [peer]} = LocalCluster.nodes(cluster)

    on_exit(fn ->
      try do
        LocalCluster.stop(cluster)
      catch
        :exit, _ -> :ok
      end
    end)

    # Placement.local_execute/5 checks function_exported?/3, which does not
    # autoload; a fresh interactive-mode peer has not loaded the handler yet.
    {:module, StartHandler} = :erpc.call(peer, Code, :ensure_loaded, [StartHandler])

    %{peer: peer}
  end

  setup do
    prev_peers = Application.get_env(@app, :placement_peers)

    on_exit(fn ->
      if is_nil(prev_peers),
        do: Application.delete_env(@app, :placement_peers),
        else: Application.put_env(@app, :placement_peers, prev_peers)
    end)

    Application.delete_env(@app, :placement_peers)
    :ok
  end

  defp placed_start_node(peer) do
    GNode.from_attrs("placed", %{
      "type" => "start",
      "shape" => "Mdiamond",
      "placement" => "node:#{peer}"
    })
  end

  defp execute_placed(peer, opts) do
    node = placed_start_node(peer)
    graph = %Graph{nodes: %{"placed" => node}, edges: [], attrs: %{}}
    {outcome, _retries} = Executor.execute_with_retry(node, Context.new(), graph, %{}, opts)
    outcome
  end

  describe "security regression: placement peer policy with a connected peer" do
    test "resolve/1 refuses a connected peer that is not listed", %{peer: peer} do
      assert peer in Node.list()

      assert {:error, {:placement_peer_denied, ^peer}} =
               Placement.resolve(%{requirements: [], strategy: :first_match, node: peer})
    end

    test "the executor fails an unlisted peer instead of running locally", %{peer: peer} do
      outcome = execute_placed(peer, placement_required: false)

      assert outcome.status == :fail
      assert outcome.failure_reason =~ "placement_peer_denied"
    end

    test "a listed peer still executes the handler remotely", %{peer: peer} do
      Application.put_env(@app, :placement_peers, [peer])

      assert {:ok, ^peer} =
               Placement.resolve(%{requirements: [], strategy: :first_match, node: peer})

      outcome = execute_placed(peer, [])

      assert outcome.status == :success
      assert outcome.notes =~ "[executed on #{peer}]"
    end
  end
end
