defmodule Arbor.Security.DistributedTest do
  @moduledoc """
  Tests for distributed security features:
  - Persistent SystemAuthority keypair
  - CapabilityStore signal handling from remote nodes
  - Identity.Registry signal handling from remote nodes
  """
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Contracts.Security.Capability
  alias Arbor.Contracts.Security.Identity
  alias Arbor.Security.CapabilityStore
  alias Arbor.Security.Identity.Registry
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

  describe "CapabilityStore handles remote signals" do
    test "handles :signal_received for revocation from remote node" do
      {:ok, cap} =
        Capability.new(
          resource_uri: "arbor://test/remote_revoke",
          principal_id: "agent_remote"
        )

      CapabilityStore.put(cap)
      assert {:ok, ^cap} = CapabilityStore.get(cap.id)

      # Simulate a remote revocation signal
      send(Process.whereis(CapabilityStore), {:signal_received, %{
        type: :capability_revoked,
        data: %{
          capability_ids: [cap.id],
          origin_node: :remote@node
        }
      }})

      Process.sleep(10)

      # Should be revoked
      assert {:error, :not_found} = CapabilityStore.get(cap.id)
    end

    test "handles :signal_received for bulk revocation" do
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
      send(Process.whereis(CapabilityStore), {:signal_received, %{
        type: :capabilities_revoked_all,
        data: %{
          capability_ids: cap_ids,
          origin_node: :remote@node
        }
      }})

      Process.sleep(10)

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
      send(Process.whereis(CapabilityStore), {:signal_received, %{
        type: :capability_revoked,
        data: %{
          capability_ids: [cap.id],
          origin_node: node()
        }
      }})

      Process.sleep(10)

      # Should still exist (signal from own node is ignored)
      assert {:ok, ^cap} = CapabilityStore.get(cap.id)
    end

    test "handles unknown message types gracefully" do
      # Should not crash
      send(Process.whereis(CapabilityStore), {:signal_received, %{
        type: :unknown_type,
        data: %{origin_node: :remote@node}
      }})

      Process.sleep(10)

      # Store should still be functional
      stats = CapabilityStore.stats()
      assert is_map(stats)
    end
  end

  # ── Identity Registry Signal Handling ───────────────────────────────

  describe "Identity.Registry handles remote signals" do
    test "handles remote deregistration signal" do
      {:ok, identity} = Identity.generate(name: "dist-test")
      :ok = Registry.register(Identity.public_only(identity))

      assert {:ok, _pk} = Registry.lookup(identity.agent_id)

      # Simulate remote deregistration
      send(Process.whereis(Registry), {:signal_received, %{
        type: :identity_deregistered,
        data: %{
          agent_id: identity.agent_id,
          origin_node: :remote@node
        }
      }})

      Process.sleep(10)

      assert {:error, :not_found} = Registry.lookup(identity.agent_id)
    end

    test "handles remote suspension signal" do
      {:ok, identity} = Identity.generate(name: "suspend-test")
      :ok = Registry.register(Identity.public_only(identity))

      send(Process.whereis(Registry), {:signal_received, %{
        type: :identity_suspended,
        data: %{
          agent_id: identity.agent_id,
          origin_node: :remote@node
        }
      }})

      Process.sleep(10)

      assert {:error, :identity_suspended} = Registry.lookup(identity.agent_id)
    end

    test "handles remote resume signal" do
      {:ok, identity} = Identity.generate(name: "resume-test")
      :ok = Registry.register(Identity.public_only(identity))

      # Suspend first
      :ok = Registry.suspend(identity.agent_id, "test")

      # Resume via signal
      send(Process.whereis(Registry), {:signal_received, %{
        type: :identity_resumed,
        data: %{
          agent_id: identity.agent_id,
          origin_node: :remote@node
        }
      }})

      Process.sleep(10)

      assert {:ok, _pk} = Registry.lookup(identity.agent_id)
    end

    test "handles remote revocation signal" do
      {:ok, identity} = Identity.generate(name: "revoke-test")
      :ok = Registry.register(Identity.public_only(identity))

      send(Process.whereis(Registry), {:signal_received, %{
        type: :identity_revoked,
        data: %{
          agent_id: identity.agent_id,
          origin_node: :remote@node
        }
      }})

      Process.sleep(10)

      assert {:error, :identity_revoked} = Registry.lookup(identity.agent_id)
    end

    test "ignores identity signals from own node" do
      {:ok, identity} = Identity.generate(name: "self-signal-test")
      :ok = Registry.register(Identity.public_only(identity))

      send(Process.whereis(Registry), {:signal_received, %{
        type: :identity_deregistered,
        data: %{
          agent_id: identity.agent_id,
          origin_node: node()
        }
      }})

      Process.sleep(10)

      # Should still be registered
      assert {:ok, _pk} = Registry.lookup(identity.agent_id)
    end

    test "ignores signals for unknown agents" do
      # Should not crash
      send(Process.whereis(Registry), {:signal_received, %{
        type: :identity_suspended,
        data: %{
          agent_id: "agent_does_not_exist",
          origin_node: :remote@node
        }
      }})

      Process.sleep(10)

      stats = Registry.stats()
      assert is_map(stats)
    end
  end

  # ── Config ──────────────────────────────────────────────────────────

  describe "distributed config" do
    test "distributed_signals defaults to true" do
      original = Application.get_env(:arbor_security, :distributed_signals)
      Application.delete_env(:arbor_security, :distributed_signals)

      assert Arbor.Security.Config.distributed_signals_enabled?() == true

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
