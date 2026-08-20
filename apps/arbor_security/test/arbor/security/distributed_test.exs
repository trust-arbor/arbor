defmodule Arbor.Security.DistributedTest do
  @moduledoc """
  Tests for distributed security features:
  - Persistent SystemAuthority keypair
  - Unauthenticated remote security-sync mutations fail closed
  - Identity.Registry and CapabilityStore ignore own-node echoes
  - Multi-node signed-request acceptance fails closed without authenticated sync
  """
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Contracts.Security.Capability
  alias Arbor.Contracts.Security.Identity
  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Security
  alias Arbor.Security.CapabilityStore
  alias Arbor.Security.Identity.Registry
  alias Arbor.Security.Identity.ReplayPeers
  alias Arbor.Security.Identity.Verifier
  alias Arbor.Security.SystemAuthority

  # ── SystemAuthority Mode Config ─────────────────────────────────────

  describe "SystemAuthority mode config" do
    test "ephemeral mode is default in test env" do
      assert Application.get_env(:arbor_security, :system_authority_mode) == :ephemeral
    end

    test "system authority has a valid keypair" do
      agent_id = SystemAuthority.agent_id()
      assert is_binary(agent_id)
      assert String.starts_with?(agent_id, "agent_")

      pk = SystemAuthority.public_key()
      assert byte_size(pk) == 32
    end

    test "system authority is registered in Identity.Registry" do
      agent_id = SystemAuthority.agent_id()
      assert {:ok, pk} = Registry.lookup(agent_id)
      assert pk == SystemAuthority.public_key()
    end
  end

  # ── CapabilityStore Signal Handling ─────────────────────────────────

  describe "CapabilityStore rejects unauthenticated remote signals" do
    test "security regression: remote :capability_revoked does not evict without authenticated transport" do
      refute Arbor.Signals.authenticated_security_sync_transport?()

      {:ok, cap} =
        Capability.new(
          resource_uri: "arbor://test/remote_revoke",
          principal_id: "agent_remote"
        )

      CapabilityStore.put(cap)
      assert {:ok, ^cap} = CapabilityStore.get(cap.id)

      # Simulate a remote revocation signal
      send(
        Process.whereis(CapabilityStore),
        {:signal_received,
         %{
           type: :capability_revoked,
           data: %{
             capability_ids: [cap.id],
             origin_node: :remote@node
           }
         }}
      )

      _ = :sys.get_state(CapabilityStore)

      # Unauthenticated remote apply fails closed — capability still exists
      assert {:ok, ^cap} = CapabilityStore.get(cap.id)
    end

    test "security regression: remote bulk revocation does not evict without authenticated transport" do
      refute Arbor.Signals.authenticated_security_sync_transport?()

      caps =
        for i <- 1..3 do
          {:ok, cap} =
            Capability.new(
              resource_uri: "arbor://test/bulk_revoke/#{i}",
              principal_id: "agent_bulk"
            )

          CapabilityStore.put(cap)
          cap
        end

      cap_ids = Enum.map(caps, & &1.id)

      # Simulate remote bulk revocation
      send(
        Process.whereis(CapabilityStore),
        {:signal_received,
         %{
           type: :capabilities_revoked_all,
           data: %{
             capability_ids: cap_ids,
             origin_node: :remote@node
           }
         }}
      )

      _ = :sys.get_state(CapabilityStore)

      for cap <- caps do
        assert {:ok, ^cap} = CapabilityStore.get(cap.id)
      end
    end

    test "ignores capability signals from own node" do
      {:ok, cap} =
        Capability.new(
          resource_uri: "arbor://test/self_signal",
          principal_id: "agent_self"
        )

      CapabilityStore.put(cap)

      # Simulate a signal from THIS node — should be ignored
      send(
        Process.whereis(CapabilityStore),
        {:signal_received,
         %{
           type: :capability_revoked,
           data: %{
             capability_ids: [cap.id],
             origin_node: node()
           }
         }}
      )

      Process.sleep(10)

      # Should still exist (signal from own node is ignored)
      assert {:ok, ^cap} = CapabilityStore.get(cap.id)
    end

    test "handles unknown message types gracefully" do
      # Should not crash
      send(
        Process.whereis(CapabilityStore),
        {:signal_received,
         %{
           type: :unknown_type,
           data: %{origin_node: :remote@node}
         }}
      )

      Process.sleep(10)

      # Store should still be functional
      stats = CapabilityStore.stats()
      assert is_map(stats)
    end
  end

  # ── Identity Registry Signal Handling ───────────────────────────────

  describe "Identity.Registry rejects unauthenticated remote signals" do
    test "security regression: remote deregistration does not apply without authenticated transport" do
      refute Arbor.Signals.authenticated_security_sync_transport?()

      {:ok, identity} = Identity.generate(name: "dist-test")
      :ok = Registry.register(Identity.public_only(identity))

      assert {:ok, _pk} = Registry.lookup(identity.agent_id)

      # Simulate remote deregistration
      send(
        Process.whereis(Registry),
        {:signal_received,
         %{
           type: :identity_deregistered,
           data: %{
             agent_id: identity.agent_id,
             origin_node: :remote@node
           }
         }}
      )

      _ = :sys.get_state(Registry)

      assert {:ok, _pk} = Registry.lookup(identity.agent_id)
    end

    test "security regression: remote suspension does not apply without authenticated transport" do
      refute Arbor.Signals.authenticated_security_sync_transport?()

      {:ok, identity} = Identity.generate(name: "suspend-test")
      :ok = Registry.register(Identity.public_only(identity))

      send(
        Process.whereis(Registry),
        {:signal_received,
         %{
           type: :identity_suspended,
           data: %{
             agent_id: identity.agent_id,
             origin_node: :remote@node
           }
         }}
      )

      _ = :sys.get_state(Registry)

      assert {:ok, _pk} = Registry.lookup(identity.agent_id)
    end

    test "security regression: remote resume does not unsuspend without authenticated transport" do
      refute Arbor.Signals.authenticated_security_sync_transport?()

      {:ok, identity} = Identity.generate(name: "resume-test")
      :ok = Registry.register(Identity.public_only(identity))

      # Suspend first
      :ok = Registry.suspend(identity.agent_id, "test")

      # Resume via unauthenticated remote signal
      send(
        Process.whereis(Registry),
        {:signal_received,
         %{
           type: :identity_resumed,
           data: %{
             agent_id: identity.agent_id,
             origin_node: :remote@node
           }
         }}
      )

      _ = :sys.get_state(Registry)

      assert {:error, :identity_suspended} = Registry.lookup(identity.agent_id)
    end

    test "security regression: remote revocation does not apply without authenticated transport" do
      refute Arbor.Signals.authenticated_security_sync_transport?()

      {:ok, identity} = Identity.generate(name: "revoke-test")
      :ok = Registry.register(Identity.public_only(identity))

      send(
        Process.whereis(Registry),
        {:signal_received,
         %{
           type: :identity_revoked,
           data: %{
             agent_id: identity.agent_id,
             origin_node: :remote@node
           }
         }}
      )

      _ = :sys.get_state(Registry)

      assert {:ok, _pk} = Registry.lookup(identity.agent_id)
    end

    test "ignores identity signals from own node" do
      {:ok, identity} = Identity.generate(name: "self-signal-test")
      :ok = Registry.register(Identity.public_only(identity))

      send(
        Process.whereis(Registry),
        {:signal_received,
         %{
           type: :identity_deregistered,
           data: %{
             agent_id: identity.agent_id,
             origin_node: node()
           }
         }}
      )

      Process.sleep(10)

      # Should still be registered
      assert {:ok, _pk} = Registry.lookup(identity.agent_id)
    end

    test "ignores signals for unknown agents" do
      # Should not crash
      send(
        Process.whereis(Registry),
        {:signal_received,
         %{
           type: :identity_suspended,
           data: %{
             agent_id: "agent_does_not_exist",
             origin_node: :remote@node
           }
         }}
      )

      Process.sleep(10)

      stats = Registry.stats()
      assert is_map(stats)
    end
  end

  # ── Signed-request cluster replay gate ──────────────────────────────

  describe "signed-request acceptance fails closed on multi-node without authenticated transport" do
    setup do
      # Sibling suites restart the :arbor_security application to exercise
      # claim-table ownership. The test env sets `start_children: false`, so
      # the children test_helper.exs added are gone and nothing brings them
      # back — including the tracker the gate reads. An absent tracker fails
      # closed (every peer is a replay peer), which would mask the very
      # behavior these tests assert, so make sure it is up.
      if is_nil(Process.whereis(ReplayPeers)) do
        start_supervised!({ReplayPeers, []})
      end

      :ok
    end

    test "security regression: valid signed request is denied when peers are present" do
      refute Arbor.Signals.authenticated_security_sync_transport?()
      assert Node.list() == []
      refute Arbor.Security.Config.cluster_peers_present?()

      {:ok, identity} = Identity.generate(name: "cluster-replay-gate")
      :ok = Registry.register(Identity.public_only(identity))

      {:ok, single_node_signed} =
        SignedRequest.sign("single-node", identity.agent_id, identity.private_key)

      assert {:ok, agent_id} = Security.verify_signed_request_authenticity(single_node_signed)
      assert agent_id == identity.agent_id

      Arbor.Security.Config.inject_test_cluster_peers_present(true)

      try do
        {:ok, clustered_signed} =
          SignedRequest.sign("clustered", identity.agent_id, identity.private_key)

        assert {:error, :cluster_replay_protection_unavailable} =
                 Security.verify_signed_request_authenticity(clustered_signed)

        {:ok, clustered_signed_verifier} =
          SignedRequest.sign("clustered-verifier", identity.agent_id, identity.private_key)

        assert {:error, :cluster_replay_protection_unavailable} =
                 Verifier.verify(clustered_signed_verifier)
      after
        Arbor.Security.Config.inject_test_cluster_peers_present(false)
      end
    end

    @tag :slow
    @tag :integration
    test "security regression: a connected node that does not run :arbor_security " <>
           "is not a replay target and does not refuse a valid signed request" do
      # Pre-fix (`cluster_peers_present?` == `Node.list() != []`) this fails:
      # any distribution peer at all — an SDR recorder, a build box, an ops
      # shell — refused every signed request on this node, which is the
      # normal state of a clustered dev machine. The peer started here runs
      # a bare BEAM with no :arbor_security, so it cannot resolve the agent
      # id or verify the signature and cannot accept a replay.
      started_distributed = ensure_distributed_node()
      on_exit(fn -> if started_distributed, do: Node.stop() end)

      peer_name = String.to_atom("replay_foreign_#{System.unique_integer([:positive])}")
      {:ok, peer, peer_node} = :peer.start_link(%{name: peer_name})
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

    @tag :slow
    @tag :integration
    @tag :slow
    @tag :integration
    test "security regression: a peer whose probe cannot complete still refuses" do
      # The gate now AWAITS an outstanding probe rather than assuming the
      # worst (see the nodeup-race test below). This pins the other half of
      # that change: when the probe genuinely cannot produce a verdict, the
      # answer is still `:replay_peer` and the request is still refused.
      #
      # A wedged peer is the realistic version of "cannot determine" — the
      # node is connected and may well be running :arbor_security, we simply
      # cannot find out. Suspending its application_controller makes
      # `which_applications` hang, which is exactly what the probe calls.
      started_distributed = ensure_distributed_node()
      on_exit(fn -> if started_distributed, do: Node.stop() end)

      peer_name = String.to_atom("replay_wedged_#{System.unique_integer([:positive])}")
      {:ok, peer, peer_node} = :peer.start_link(%{name: peer_name})

      on_exit(fn ->
        # Best-effort: the peer may already be gone by teardown, and a raised
        # :noconnection here would fail an otherwise-passing test.
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

      # Non-blocking cached read: unknown is always :replay_peer.
      assert ReplayPeers.classification(peer_node) == :replay_peer

      # Resolved read: the probe times out, so the verdict stays :replay_peer.
      assert ReplayPeers.peers_present?()
      assert peer_node in ReplayPeers.list()

      {:ok, identity} = Identity.generate(name: "wedged-peer-fails-closed")
      :ok = Registry.register(Identity.public_only(identity))

      {:ok, signed} =
        SignedRequest.sign("wedged-peer", identity.agent_id, identity.private_key)

      assert {:error, :cluster_replay_protection_unavailable} = Verifier.verify(signed)
    end

    @tag :slow
    @tag :integration
    test "security regression: an unclassified peer is awaited, not assumed hostile" do
      # The nodeup race. `handle_nodeup` drops the cached verdict and probes
      # asynchronously, so there is a window where a connected node has no
      # classification. Treating that window as ":replay_peer" made every
      # local CLI call fail: `mix arbor.agent chat` connects an ephemeral node
      # and RPCs immediately, losing the race every time and getting
      # `:cluster_replay_protection_unavailable` on a single-node install.
      #
      # `forget/1` reproduces exactly that window — it can only REMOVE a
      # verdict, so it cannot be used to fake a permissive one.
      started_distributed = ensure_distributed_node()
      on_exit(fn -> if started_distributed, do: Node.stop() end)

      peer_name = String.to_atom("replay_race_#{System.unique_integer([:positive])}")
      {:ok, peer, peer_node} = :peer.start_link(%{name: peer_name})
      on_exit(fn -> safely_stop_peer(peer) end)

      await_classification(peer_node, :foreign)

      # Re-open the window, then ask the gate.
      :ok = ReplayPeers.forget(peer_node)
      assert peer_node in Node.list(:connected)

      # Must await the re-probe and conclude :foreign — not shortcut to true.
      refute ReplayPeers.peers_present?(),
             "an unclassified peer was assumed to be a replay peer instead of being awaited"

      assert ReplayPeers.classification(peer_node) == :foreign
    end

    @tag :slow
    @tag :integration
    test "security regression: a hidden peer is still tracked by the gate" do
      # `Node.list/0` defaults to `:visible`, so a peer started `-hidden` is
      # invisible to it. A hidden node can still run :arbor_security and
      # accept a replayed request, so counting only visible nodes would let
      # anyone silence this gate by adding one flag to a peer's launch — the
      # exact flag we recommend for foreign nodes like SDR recorders.
      started_distributed = ensure_distributed_node()
      on_exit(fn -> if started_distributed, do: Node.stop() end)

      peer_name = String.to_atom("replay_hidden_#{System.unique_integer([:positive])}")

      {:ok, peer, peer_node} =
        :peer.start_link(%{name: peer_name, args: [~c"-hidden"]})

      on_exit(fn -> safely_stop_peer(peer) end)

      # The premise: invisible to the default listing, present in :connected.
      refute peer_node in Node.list()
      assert peer_node in Node.list(:connected)

      # It must be probed, not ignored. This peer runs no :arbor_security,
      # so it lands on :foreign — reaching a verdict at all is the assertion.
      await_classification(peer_node, :foreign)
    end

    test "security regression: an unseen node reads as a replay peer" do
      # The default is the strict one. A node the tracker has never
      # classified — never connected, or seen only after a crash wiped the
      # table — must not read as foreign.
      assert ReplayPeers.classification(:never_seen_by_the_tracker@nowhere) == :replay_peer
    end
  end

  defp ensure_distributed_node do
    if Node.alive?() do
      false
    else
      name = String.to_atom("sec_replay_test_#{System.unique_integer([:positive, :monotonic])}")
      {:ok, _} = :net_kernel.start([name, :shortnames])
      true
    end
  end

  defp safely_stop_peer(peer) do
    :peer.stop(peer)
  catch
    _, _ -> :ok
  end

  # The probe is asynchronous by design (a wedged peer must never block the
  # auth path), so the test waits for the verdict instead of sleeping.
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

  # ── Config ──────────────────────────────────────────────────────────

  describe "distributed config" do
    test "distributed_signals defaults to true when a sync transport is configured" do
      original = Application.get_env(:arbor_security, :distributed_signals)
      Application.delete_env(:arbor_security, :distributed_signals)

      assert Arbor.Signals.Config.security_sync_transport_configured?()
      assert Arbor.Security.Config.distributed_signals_enabled?() == true
      refute Arbor.Signals.authenticated_security_sync_transport?()

      if original != nil do
        Application.put_env(:arbor_security, :distributed_signals, original)
      end
    end

    test "system_authority_mode defaults to persistent" do
      original = Application.get_env(:arbor_security, :system_authority_mode)
      Application.delete_env(:arbor_security, :system_authority_mode)

      assert Arbor.Security.Config.system_authority_mode() == :persistent

      if original != nil do
        Application.put_env(:arbor_security, :system_authority_mode, original)
      end
    end
  end
end
