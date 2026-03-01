defmodule Arbor.Actions.ChannelCryptoTest do
  use ExUnit.Case, async: false

  alias Arbor.Actions.Channel
  alias Arbor.Security.Crypto

  @moduletag :integration

  setup do
    ensure_channel_infra()

    {:ok, channel_id} =
      Arbor.Comms.create_channel("crypto_test_channel", [
        type: :group,
        owner_id: "agent_1",
        members: [%{id: "agent_1", name: "Agent One", type: :agent}],
        rate_limit_ms: 0
      ])

    %{channel_id: channel_id}
  end

  # ============================================================================
  # Sub-Phase 3a: Signing in Actions
  # ============================================================================

  describe "Channel.Send signing" do
    test "sends message without signing key (graceful fallback)", %{channel_id: channel_id} do
      context = %{agent_id: "agent_1", agent_name: "Agent One"}
      params = %{channel_id: channel_id, content: "Unsigned message"}

      assert {:ok, result} = Channel.Send.run(params, context)
      assert result.status == :sent
      # No signing key store available in test → sends unsigned
      assert result.signed == false
    end

    test "message content preserved through send/read cycle", %{channel_id: channel_id} do
      context = %{agent_id: "agent_1", agent_name: "Agent One"}
      content = "Round-trip test message"

      {:ok, _} = Channel.Send.run(%{channel_id: channel_id, content: content}, context)
      {:ok, result} = Channel.Read.run(%{channel_id: channel_id}, context)

      assert result.count == 1
      [msg] = result.messages
      assert msg.content == content
    end
  end

  describe "Channel.Read verification" do
    test "unsigned messages show verified: nil", %{channel_id: channel_id} do
      Arbor.Comms.send_to_channel(channel_id, "agent_1", "Agent One", :agent, "Plain message")

      {:ok, result} = Channel.Read.run(%{channel_id: channel_id}, %{})
      [msg] = result.messages
      assert msg.verified == nil
      assert msg.signed == false
    end

    test "manually signed messages show signed: true", %{channel_id: channel_id} do
      {_pub, priv} = Crypto.generate_keypair()
      content = "Signed at action layer"
      signature = Crypto.sign(content, priv)

      # Send with signature in metadata (simulating what Channel.Send would do)
      Arbor.Comms.send_to_channel(
        channel_id,
        "agent_1",
        "Agent One",
        :agent,
        content,
        %{signature: signature}
      )

      {:ok, result} = Channel.Read.run(%{channel_id: channel_id}, %{})
      msg = List.last(result.messages)
      assert msg.signed == true
      # verified is nil because Identity Registry isn't running with this agent's key
      assert msg.verified == nil
    end
  end

  # ============================================================================
  # Sub-Phase 3b: Private Channel via Actions
  # ============================================================================

  describe "private channel via actions" do
    setup do
      {:ok, priv_id} =
        Arbor.Comms.create_channel("private_test", [
          type: :private,
          owner_id: "agent_1",
          members: [%{id: "agent_1", name: "Agent One", type: :agent}],
          rate_limit_ms: 0
        ])

      %{priv_channel_id: priv_id}
    end

    test "can send and read from private channel", %{priv_channel_id: channel_id} do
      context = %{agent_id: "agent_1", agent_name: "Agent One"}
      content = "Secret message via action"

      {:ok, send_result} = Channel.Send.run(%{channel_id: channel_id, content: content}, context)
      assert send_result.status == :sent

      {:ok, read_result} = Channel.Read.run(%{channel_id: channel_id}, context)
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
        Arbor.Comms.create_channel("dm_test", [
          type: :dm,
          owner_id: "agent_1",
          members: [
            %{id: "agent_1", name: "Agent One", type: :agent},
            %{id: "agent_2", name: "Agent Two", type: :agent}
          ],
          rate_limit_ms: 0
        ])

      %{dm_channel_id: dm_id}
    end

    test "DM channel info reports double_ratchet encryption type", %{dm_channel_id: dm_id} do
      {:ok, info} = Arbor.Comms.get_channel_info(dm_id)
      assert info.encryption_type == :double_ratchet
    end

    test "DM messages sent without keychain fall back to plaintext", %{dm_channel_id: dm_id} do
      # Without SigningKeyStore running, DM encryption falls back to plaintext
      context = %{agent_id: "agent_1", agent_name: "Agent One"}
      content = "DM without crypto infra"

      {:ok, send_result} = Channel.Send.run(%{channel_id: dm_id, content: content}, context)
      assert send_result.status == :sent

      {:ok, read_result} = Channel.Read.run(%{channel_id: dm_id}, context)
      assert read_result.count == 1
      [msg] = read_result.messages
      # Falls back to plaintext since no keychain infrastructure
      assert msg.content == content
    end
  end

  # ============================================================================
  # Direct Crypto Round-Trip
  # ============================================================================

  describe "ECDH seal/unseal round-trip" do
    test "seal and unseal with X25519 keypairs" do
      {_alice_pub, alice_priv} = Crypto.generate_encryption_keypair()
      {bob_pub, bob_priv} = Crypto.generate_encryption_keypair()

      plaintext = "Secret message from Alice to Bob"
      sealed = Crypto.seal(plaintext, bob_pub, alice_priv)

      assert {:ok, ^plaintext} = Crypto.unseal(sealed, bob_priv)
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
end
