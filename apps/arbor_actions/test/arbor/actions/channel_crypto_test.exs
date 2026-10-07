defmodule Arbor.Actions.ChannelCryptoTest do
  use ExUnit.Case, async: false

  alias Arbor.Actions.Channel
  alias Arbor.Contracts.Security.Identity
  alias Arbor.Security
  alias Arbor.Security.Crypto

  @moduletag :integration

  setup do
    ensure_channel_infra()

    {:ok, identity} = Identity.generate(name: "Channel Action Agent")
    :ok = Security.register_identity_fixture(Identity.public_only(identity))

    :ok =
      Security.store_signing_keypair_fixture(
        identity.agent_id,
        identity.private_key,
        identity.encryption_private_key
      )

    {:ok, signing_authority} = open_authority(identity)
    {:ok, send_authority} = Security.issue_channel_authority(signing_authority, :send)
    {:ok, read_authority} = Security.issue_channel_authority(signing_authority, :read)

    {:ok, channel_id} =
      Arbor.Comms.create_channel("crypto_test_channel",
        type: :group,
        owner_id: identity.agent_id,
        members: [%{id: identity.agent_id, name: identity.name, type: :agent}],
        rate_limit_ms: 0
      )

    on_exit(fn ->
      _ = Security.delete_signing_key_fixture(identity.agent_id)
      _ = Security.deregister_identity_fixture(identity.agent_id)
    end)

    %{
      channel_id: channel_id,
      identity: identity,
      send_context: %{
        agent_id: "attacker-controlled-id",
        agent_name: identity.name,
        channel_authority: send_authority
      },
      read_context: %{
        agent_id: identity.agent_id,
        agent_name: identity.name,
        channel_authority: read_authority
      }
    }
  end

  # ============================================================================
  # Sub-Phase 3a: Signing in Actions
  # ============================================================================

  describe "Channel.Send signing" do
    test "security regression: missing channel authority cannot send an unsigned message", %{
      channel_id: channel_id
    } do
      context = %{agent_id: "agent_1", agent_name: "Agent One"}
      params = %{channel_id: channel_id, content: "Unsigned message"}

      assert {:error, :channel_authority_required} = Channel.Send.run(params, context)
      assert {:ok, %{count: 0}} = Channel.Read.run(%{channel_id: channel_id}, %{})
    end

    test "security regression: authority principal signs exact content through send/read", %{
      channel_id: channel_id,
      identity: identity,
      send_context: send_context,
      read_context: read_context
    } do
      content = "Round-trip test message"

      assert {:ok, %{signed: true}} =
               Channel.Send.run(%{channel_id: channel_id, content: content}, send_context)

      {:ok, result} = Channel.Read.run(%{channel_id: channel_id}, read_context)

      assert result.count == 1
      [msg] = result.messages
      assert msg.content == content
      assert msg.signed == true
      assert msg.verified == true

      {:ok, [wire_message]} = Arbor.Comms.channel_history(channel_id)
      assert wire_message.sender_id == identity.agent_id
    end
  end

  describe "Channel.Read verification" do
    test "unsigned messages show verified: nil", %{channel_id: channel_id, identity: identity} do
      Arbor.Comms.send_to_channel(
        channel_id,
        identity.agent_id,
        identity.name,
        :agent,
        "Plain message"
      )

      {:ok, result} = Channel.Read.run(%{channel_id: channel_id}, %{})
      [msg] = result.messages
      assert msg.verified == nil
      assert msg.signed == false
    end

    test "legacy content-only signatures fail the channel-bound verifier", %{
      channel_id: channel_id,
      identity: identity
    } do
      {_pub, priv} = Crypto.generate_keypair()
      content = "Signed at action layer"
      signature = Crypto.sign(content, priv)

      # Send with signature in metadata (simulating what Channel.Send would do)
      Arbor.Comms.send_to_channel(
        channel_id,
        identity.agent_id,
        identity.name,
        :agent,
        content,
        %{signature: signature}
      )

      {:ok, result} = Channel.Read.run(%{channel_id: channel_id}, %{})
      msg = List.last(result.messages)
      assert msg.signed == true
      assert msg.verified == false
    end
  end

  # ============================================================================
  # Sub-Phase 3b: Private Channel via Actions
  # ============================================================================

  describe "private channel via actions" do
    setup %{identity: identity} do
      {:ok, priv_id} =
        Arbor.Comms.create_channel("private_test",
          type: :private,
          owner_id: identity.agent_id,
          members: [%{id: identity.agent_id, name: identity.name, type: :agent}],
          rate_limit_ms: 0
        )

      %{priv_channel_id: priv_id}
    end

    test "can send and read from private channel", %{
      priv_channel_id: channel_id,
      send_context: send_context,
      read_context: read_context
    } do
      content = "Secret message via action"

      {:ok, send_result} =
        Channel.Send.run(%{channel_id: channel_id, content: content}, send_context)

      assert send_result.status == :sent

      {:ok, read_result} = Channel.Read.run(%{channel_id: channel_id}, read_context)
      assert read_result.count == 1
      [msg] = read_result.messages
      assert msg.content == content
    end

    test "channel info shows encrypted for private channel", %{priv_channel_id: channel_id} do
      {:ok, info} = Arbor.Comms.get_channel_info(channel_id)
      assert info.encrypted == true
      assert info.encryption_type == :aes_256_gcm
    end
  end

  # ============================================================================
  # Sub-Phase 3c: DM Channel Type
  # ============================================================================

  describe "DM channel basics" do
    setup do
      {:ok, dm_id} =
        Arbor.Comms.create_channel("dm_test",
          type: :dm,
          owner_id: "agent_1",
          members: [
            %{id: "agent_1", name: "Agent One", type: :agent},
            %{id: "agent_2", name: "Agent Two", type: :agent}
          ],
          rate_limit_ms: 0
        )

      %{dm_channel_id: dm_id}
    end

    test "DM channel info reports double_ratchet encryption type", %{dm_channel_id: dm_id} do
      {:ok, info} = Arbor.Comms.get_channel_info(dm_id)
      assert info.encryption_type == :double_ratchet
    end

    test "security regression: DM without caller-owned keychain never falls back to plaintext", %{
      dm_channel_id: dm_id
    } do
      context = %{agent_id: "agent_1", agent_name: "Agent One"}
      content = "DM without crypto infra"

      assert {:error, :channel_authority_required} =
               Channel.Send.run(%{channel_id: dm_id, content: content}, context)

      {:ok, read_result} = Channel.Read.run(%{channel_id: dm_id}, context)
      assert read_result.count == 0
    end
  end

  # ============================================================================
  # Direct Crypto Round-Trip
  # ============================================================================

  describe "ECDH seal/unseal round-trip" do
    test "seal and unseal (signcryption: recipient X25519 + sender Ed25519)" do
      # seal/3 is authenticated: encrypt to the recipient's X25519 public key AND
      # sign the envelope with the sender's Ed25519 signing key. unseal/3 verifies
      # that signature against the sender's Ed25519 public key before decrypting
      # with the recipient's X25519 private key.
      {bob_pub, bob_priv} = Crypto.generate_encryption_keypair()
      {alice_sign_pub, alice_sign_priv} = Crypto.generate_keypair()

      plaintext = "Secret message from Alice to Bob"
      sealed = Crypto.seal(plaintext, bob_pub, alice_sign_priv)

      assert {:ok, ^plaintext} = Crypto.unseal(sealed, bob_priv, alice_sign_pub)
    end
  end

  describe "signing round-trip" do
    test "sign and verify with Ed25519" do
      {pub, priv} = Crypto.generate_keypair()
      message = "Important message"

      signature = Crypto.sign(message, priv)
      assert Crypto.verify(message, signature, pub) == true
      assert Crypto.verify("tampered", signature, pub) == false
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp ensure_channel_infra do
    case Registry.start_link(keys: :unique, name: Arbor.Comms.ChannelRegistry) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    case DynamicSupervisor.start_link(
           name: Arbor.Comms.ChannelSupervisor,
           strategy: :one_for_one
         ) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  defp open_authority(identity) do
    with {:ok, proof} <-
           Security.build_signing_authority_acquisition_proof(
             identity.agent_id,
             identity.private_key,
             purpose: :session,
             owner: self()
           ) do
      Security.open_signing_authority(proof)
    end
  end
end
