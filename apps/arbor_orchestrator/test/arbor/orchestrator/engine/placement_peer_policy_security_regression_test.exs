defmodule Arbor.Orchestrator.Engine.PlacementPeerPolicySecurityRegressionTest do
  @moduledoc """
  Security regression: `Placement.remote_execute/6` must apply a peer policy
  before it RPCs a handler to another node.

  It used to call `:rpc.call(target_node, Placement, :local_execute, ...)` for
  any target, shipping the handler call, node, context and graph to whatever
  node a DOT `placement` attribute or the scheduler named. Remote placement is
  now deny-by-default: only `Node.self()` and peers listed in
  `config :arbor_orchestrator, :placement_peers` (default `[]`) are admitted.

  The unlisted target below is unreachable on purpose. Without the policy the
  RPC is attempted and fails with `:nodedown`; with it the call is refused
  before any RPC, so the failure names the policy instead.
  """

  # async: false — mutates :arbor_orchestrator app env (:placement_peers).
  use ExUnit.Case, async: false

  @moduletag :security_regression
  @moduletag :fast

  alias Arbor.Orchestrator.Engine.{Outcome, Placement}
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node, as: GNode

  @app :arbor_orchestrator
  @unlisted_peer :"placement_unlisted_peer@nowhere.invalid"
  @listed_peer :"placement_listed_peer@nowhere.invalid"

  defmodule ReportingHandler do
    @moduledoc false
    def execute(_node, _context, _graph, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:placed_handler_ran, Node.self()})
      %Outcome{status: :success, notes: "placed handler ran"}
    end
  end

  setup do
    prev_peers = Application.get_env(@app, :placement_peers)

    on_exit(fn ->
      if is_nil(prev_peers),
        do: Application.delete_env(@app, :placement_peers),
        else: Application.put_env(@app, :placement_peers, prev_peers)
    end)

    Application.delete_env(@app, :placement_peers)

    %{
      node: %GNode{id: "placed", attrs: %{}},
      graph: %Graph{nodes: %{}, edges: [], attrs: %{}},
      opts: [test_pid: self(), placement_timeout: 2_000]
    }
  end

  defp remote_execute(target, ctx) do
    Placement.remote_execute(target, ReportingHandler, ctx.node, %{}, ctx.graph, ctx.opts)
  end

  describe "security regression: remote placement peer policy" do
    test "an unlisted peer is refused before any RPC (default policy)", ctx do
      outcome = remote_execute(@unlisted_peer, ctx)

      assert %Outcome{status: :fail, failure_reason: reason} = outcome
      assert reason =~ "placement_peer_denied"
      refute reason =~ "nodedown"
      refute_received {:placed_handler_ran, _}
    end

    test "a non-list placement_peers value denies every remote peer", ctx do
      Application.put_env(@app, :placement_peers, :all)

      outcome = remote_execute(@unlisted_peer, ctx)

      assert %Outcome{status: :fail, failure_reason: reason} = outcome
      assert reason =~ "placement_peer_denied"
      refute reason =~ "nodedown"
      refute_received {:placed_handler_ran, _}
    end

    test "a listed peer passes the policy and reaches the RPC", ctx do
      Application.put_env(@app, :placement_peers, [@listed_peer])

      outcome = remote_execute(@listed_peer, ctx)

      # Admitted by policy; the RPC itself fails because the peer is unreachable.
      assert %Outcome{status: :fail, failure_reason: reason} = outcome
      assert reason =~ "placement RPC failed"
      refute reason =~ "placement_peer_denied"
    end

    test "a listed peer may be named by string", ctx do
      Application.put_env(@app, :placement_peers, [Atom.to_string(@listed_peer)])

      outcome = remote_execute(@listed_peer, ctx)

      assert %Outcome{status: :fail, failure_reason: reason} = outcome
      assert reason =~ "placement RPC failed"
      refute reason =~ "placement_peer_denied"
    end

    test "listing one peer does not admit another", ctx do
      Application.put_env(@app, :placement_peers, [@listed_peer])

      outcome = remote_execute(@unlisted_peer, ctx)

      assert %Outcome{status: :fail, failure_reason: reason} = outcome
      assert reason =~ "placement_peer_denied"
      refute reason =~ "nodedown"
    end

    test "the local node is always allowed and still executes", ctx do
      outcome = remote_execute(Node.self(), ctx)

      assert %Outcome{status: :success, notes: notes} = outcome
      assert notes =~ "[executed on #{Node.self()}]"
      local = Node.self()
      assert_receive {:placed_handler_ran, ^local}
    end
  end
end
