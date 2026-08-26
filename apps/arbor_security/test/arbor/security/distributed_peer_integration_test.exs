defmodule Arbor.Security.DistributedPeerIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :slow
  @moduletag :integration

  alias Arbor.Contracts.Security.Identity
  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Security.Identity.Registry
  alias Arbor.Security.Identity.ReplayPeers
  alias Arbor.Security.Identity.Verifier

  setup do
    # Sibling suites restart the :arbor_security application to exercise
    # claim-table ownership. The test env sets `start_children: false`, so
    # ensure the tracker read by the replay gate is available here.
    if is_nil(Process.whereis(ReplayPeers)) do
      start_supervised!({ReplayPeers, []})
    end

    :ok
  end

  test "security regression: a connected node that does not run :arbor_security " <>
         "is not a replay target and does not refuse a valid signed request" do
    # Pre-fix (`cluster_peers_present?` == `Node.list() != []`) this fails:
    # any distribution peer at all - an SDR recorder, a build box, an ops
    # shell - refused every signed request on this node, which is the normal
    # state of a clustered dev machine. The peer started here runs a bare BEAM
    # with no :arbor_security, so it cannot resolve the agent id or verify the
    # signature and cannot accept a replay.
    started_distributed = ensure_distributed_node()
    on_exit(fn -> if started_distributed, do: Node.stop() end)

    peer_name = String.to_atom("replay_foreign_#{System.unique_integer([:positive])}")
    {:ok, peer, peer_node} = start_peer(peer_name)
    on_exit(fn -> safely_stop_peer(peer) end)

    assert peer_node in Node.list()

    refute :arbor_security in Enum.map(
             :rpc.call(peer_node, :application, :which_applications, []),
             &elem(&1, 0)
           )

    await_classification(peer_node, :foreign)

    {:ok, identity} = Identity.generate(name: "foreign-peer-not-a-replay-target")
    :ok = Registry.register(Identity.public_only(identity))

    {:ok, signed} =
      SignedRequest.sign("foreign-peer", identity.agent_id, identity.private_key)

    assert {:ok, agent_id} = Verifier.verify(signed)
    assert agent_id == identity.agent_id
  end

  test "security regression: a peer whose probe cannot complete still refuses" do
    # The gate awaits an outstanding probe rather than assuming the worst. A
    # wedged peer is the realistic version of "cannot determine": suspending
    # its application_controller makes the probe's which_applications call hang.
    started_distributed = ensure_distributed_node()
    on_exit(fn -> if started_distributed, do: Node.stop() end)

    peer_name = String.to_atom("replay_wedged_#{System.unique_integer([:positive])}")
    {:ok, peer, peer_node} = start_peer(peer_name)

    on_exit(fn ->
      try do
        :erpc.call(peer_node, :sys, :resume, [:application_controller], 2_000)
      catch
        _, _ -> :ok
      end

      safely_stop_peer(peer)
    end)

    await_classification(peer_node, :foreign)

    :ok = :erpc.call(peer_node, :sys, :suspend, [:application_controller], 5_000)
    :ok = ReplayPeers.forget(peer_node)

    assert ReplayPeers.classification(peer_node) == :replay_peer
    assert ReplayPeers.peers_present?()
    assert peer_node in ReplayPeers.list()

    {:ok, identity} = Identity.generate(name: "wedged-peer-fails-closed")
    :ok = Registry.register(Identity.public_only(identity))

    {:ok, signed} =
      SignedRequest.sign("wedged-peer", identity.agent_id, identity.private_key)

    assert {:error, :cluster_replay_protection_unavailable} = Verifier.verify(signed)
  end

  test "security regression: an unclassified peer is awaited, not assumed hostile" do
    # The nodeup race. handle_nodeup drops the cached verdict and probes
    # asynchronously, so there is a window where a connected node has no
    # classification. Treating that window as :replay_peer made every local
    # CLI call fail when it connected an ephemeral node and RPCed immediately.
    started_distributed = ensure_distributed_node()
    on_exit(fn -> if started_distributed, do: Node.stop() end)

    peer_name = String.to_atom("replay_race_#{System.unique_integer([:positive])}")
    {:ok, peer, peer_node} = start_peer(peer_name)
    on_exit(fn -> safely_stop_peer(peer) end)

    await_classification(peer_node, :foreign)

    :ok = ReplayPeers.forget(peer_node)
    assert peer_node in Node.list(:connected)

    refute ReplayPeers.peers_present?(),
           "an unclassified peer was assumed to be a replay peer instead of being awaited"

    assert ReplayPeers.classification(peer_node) == :foreign
  end

  test "security regression: a hidden peer is still tracked by the gate" do
    # Node.list/0 defaults to visible peers. A hidden node can still run
    # :arbor_security and accept a replayed request, so the gate must track it.
    started_distributed = ensure_distributed_node()
    on_exit(fn -> if started_distributed, do: Node.stop() end)

    peer_name = String.to_atom("replay_hidden_#{System.unique_integer([:positive])}")

    {:ok, peer, peer_node} = start_peer(peer_name, [~c"-hidden"])

    on_exit(fn -> safely_stop_peer(peer) end)

    refute peer_node in Node.list()
    assert peer_node in Node.list(:connected)
    await_classification(peer_node, :foreign)
  end

  defp ensure_distributed_node do
    if Node.alive?() do
      false
    else
      start_epmd!()
      name = String.to_atom("sec_replay_test_#{System.unique_integer([:positive, :monotonic])}")
      {:ok, _} = :net_kernel.start([name, :shortnames])
      true
    end
  end

  defp start_epmd! do
    epmd = System.find_executable("epmd") || flunk("epmd executable is unavailable")

    case System.cmd(epmd, ["-daemon"], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, code} -> flunk("epmd failed to start (#{code}): #{output}")
    end
  end

  # Contained validation runs with `--network none`. In that namespace,
  # :peer's distribution-backed control channel cannot complete its boot
  # handshake against the container hostname. Keep lifecycle control on stdio,
  # then connect explicitly so the tests still exercise real distribution.
  defp start_peer(name, args \\ []) do
    options = %{
      name: name,
      host: ~c"localhost",
      connection: :standard_io,
      args: args
    }

    with {:ok, peer, peer_node} <- :peer.start_link(options) do
      case Node.connect(peer_node) do
        true ->
          {:ok, peer, peer_node}

        other ->
          safely_stop_peer(peer)
          {:error, {:distribution_connection_failed, peer_node, other}}
      end
    end
  end

  defp safely_stop_peer(peer) do
    :peer.stop(peer)
  catch
    _, _ -> :ok
  end

  # The probe is asynchronous by design, so wait for the verdict instead of
  # sleeping for a fixed interval.
  defp await_classification(node, expected, remaining_ms \\ 5_000) do
    cond do
      ReplayPeers.classification(node) == expected ->
        :ok

      remaining_ms <= 0 ->
        flunk(
          "#{inspect(node)} was never classified #{inspect(expected)}; " <>
            "it is #{inspect(ReplayPeers.classification(node))}"
        )

      true ->
        Process.sleep(50)
        await_classification(node, expected, remaining_ms - 50)
    end
  end
end
