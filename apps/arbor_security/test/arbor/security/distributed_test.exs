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

  describe "CapabilityStore admits remote security mutations by authority direction" do
    test "security regression: remote :capability_revoked evicts without authenticated transport" do
      # Revocation REMOVES authority, so it applies with no authenticated
      # transport. Blocking it is not fail-closed: the capability another
      # node revoked would keep authorizing here. Anyone able to inject this
      # signal is already a cluster member with full :erpc, so refusing it
      # buys nothing and costs the revocation.
      refute Arbor.Signals.authenticated_security_sync_transport?()
      assert Arbor.Signals.admit_remote_security_mutation?(:capability_revoked)

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

      assert {:error, :not_found} = CapabilityStore.get(cap.id)
    end

    test "security regression: remote bulk revocation evicts without authenticated transport" do
      refute Arbor.Signals.authenticated_security_sync_transport?()
      assert Arbor.Signals.admit_remote_security_mutation?(:capabilities_revoked_all)

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
        assert {:error, :not_found} = CapabilityStore.get(cap.id)
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

  describe "Identity.Registry admits remote security mutations by authority direction" do
    test "security regression: remote deregistration applies without authenticated transport" do
      refute Arbor.Signals.authenticated_security_sync_transport?()
      assert Arbor.Signals.admit_remote_security_mutation?(:identity_deregistered)

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

      assert {:error, :not_found} = Registry.lookup(identity.agent_id)
    end

    test "security regression: remote suspension applies without authenticated transport" do
      refute Arbor.Signals.authenticated_security_sync_transport?()
      assert Arbor.Signals.admit_remote_security_mutation?(:identity_suspended)

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

      assert {:error, :identity_suspended} = Registry.lookup(identity.agent_id)
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

    test "security regression: remote revocation applies without authenticated transport" do
      refute Arbor.Signals.authenticated_security_sync_transport?()
      assert Arbor.Signals.admit_remote_security_mutation?(:identity_revoked)

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

      assert {:error, :identity_revoked} = Registry.lookup(identity.agent_id)
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

    test "security regression: an unseen node reads as a replay peer" do
      # The default is the strict one. A node the tracker has never
      # classified — never connected, or seen only after a crash wiped the
      # table — must not read as foreign.
      assert ReplayPeers.classification(:never_seen_by_the_tracker@nowhere) == :replay_peer
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
