defmodule Arbor.Security.ChannelAuthoritySecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag spec: "KSEC-018"

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Contracts.Security.Identity
  alias Arbor.Security
  alias Arbor.Security.ChannelAuthorityBroker

  setup do
    identities =
      for name <- ["channel-authority-alice", "channel-authority-bob"] do
        {:ok, identity} = Identity.generate(name: name)
        :ok = Security.register_identity_fixture(Identity.public_only(identity))

        :ok =
          Security.store_signing_keypair_fixture(
            identity.agent_id,
            identity.private_key,
            identity.encryption_private_key
          )

        identity
      end

    on_exit(fn ->
      Enum.each(identities, fn identity ->
        _ = Security.delete_signing_key_fixture(identity.agent_id)
        _ = Security.deregister_identity_fixture(identity.agent_id)
      end)
    end)

    [alice, bob] = identities
    {:ok, alice: alice, bob: bob}
  end

  @tag spec: "KSEC-018"
  test "security regression: legitimate callers sign and exchange direct messages without raw keys",
       %{alice: alice, bob: bob} do
    {:ok, alice_signing_authority} = open_authority(alice)
    {:ok, bob_signing_authority} = open_authority(bob)
    {:ok, send_authority} = Security.issue_channel_authority(alice_signing_authority, :send)
    {:ok, read_authority} = Security.issue_channel_authority(bob_signing_authority, :read)

    on_exit(fn ->
      _ = Security.close_channel_authority(send_authority)
      _ = Security.close_channel_authority(read_authority)
      _ = Security.close_signing_authority(alice_signing_authority)
      _ = Security.close_signing_authority(bob_signing_authority)
    end)

    channel_id = "dm:#{alice.agent_id}:#{bob.agent_id}"
    wire_content = ~s({"encrypted":true,"ciphertext":"opaque"})

    assert {:ok, signature} =
             Security.sign_channel_message(send_authority, channel_id, wire_content)

    assert Security.verify_channel_message_signature(
             alice.agent_id,
             channel_id,
             wire_content,
             signature
           )

    refute Security.verify_channel_message_signature(
             alice.agent_id,
             channel_id,
             wire_content <> "tampered",
             signature
           )

    assert {:ok, sealed} =
             Security.seal_channel_message(send_authority, bob.agent_id, "private payload")

    assert {:ok, "private payload"} =
             Security.unseal_channel_message(read_authority, alice.agent_id, sealed)

    assert {:error, :channel_authority_unauthorized} =
             Security.unseal_channel_message(send_authority, alice.agent_id, sealed)

    assert {:error, :channel_authority_unauthorized} =
             Security.sign_channel_message(read_authority, channel_id, wire_content)
  end

  test "security regression: copied and forged channel authorities cannot sign or decrypt",
       %{alice: alice, bob: bob} do
    {:ok, alice_signing_authority} = open_authority(alice)
    {:ok, bob_signing_authority} = open_authority(bob)
    {:ok, send_authority} = Security.issue_channel_authority(alice_signing_authority, :send)
    {:ok, read_authority} = Security.issue_channel_authority(bob_signing_authority, :read)
    {:ok, sealed} = Security.seal_channel_message(send_authority, bob.agent_id, "secret")

    parent = self()

    attacker =
      spawn(fn ->
        results = %{
          principal: Security.channel_authority_principal(send_authority, :send),
          sign: Security.sign_channel_message(send_authority, "dm:test", "forged"),
          seal: Security.seal_channel_message(send_authority, bob.agent_id, "forged"),
          unseal: Security.unseal_channel_message(read_authority, alice.agent_id, sealed),
          issue: Security.issue_channel_authority(:forged_signing_authority, :send)
        }

        send(parent, {:attacker_results, results})
      end)

    assert_receive {:attacker_results, results}, 1_000
    refute Process.alive?(attacker)

    assert results == %{
             principal: {:error, :channel_authority_unauthorized},
             sign: {:error, :channel_authority_unauthorized},
             seal: {:error, :channel_authority_unauthorized},
             unseal: {:error, :channel_authority_unauthorized},
             issue: {:error, :channel_authority_unauthorized}
           }

    assert {:ok, _signature} =
             Security.sign_channel_message(send_authority, "dm:test", "owner still works")

    assert :ok = Security.close_signing_authority(alice_signing_authority)

    assert {:error, :channel_authority_unauthorized} =
             Security.sign_channel_message(send_authority, "dm:test", "revoked source")

    assert :ok = Security.close_channel_authority(send_authority)
    assert :ok = Security.close_channel_authority(read_authority)
    assert :ok = Security.close_signing_authority(bob_signing_authority)
  end

  test "security regression: raw GenServer caller spoof cannot issue or use channel authority",
       %{alice: alice} do
    {:ok, signing_authority} = open_authority(alice)
    broker = Process.whereis(ChannelAuthorityBroker)
    victim = self()

    assert is_pid(broker)

    assert {:error, :channel_authority_unauthorized} =
             Task.async(fn ->
               forged_call(broker, victim, {:issue, signing_authority, :send})
             end)
             |> Task.await()

    assert {:ok, channel_authority} =
             Security.issue_channel_authority(signing_authority, :send)

    assert {:error, :channel_authority_unauthorized} =
             Task.async(fn ->
               forged_call(
                 broker,
                 victim,
                 {:sign, channel_authority, "dm:raw-spoof", "forged"}
               )
             end)
             |> Task.await()

    assert {:ok, _signature} =
             Security.sign_channel_message(channel_authority, "dm:raw-spoof", "legitimate")

    assert :ok = Security.close_channel_authority(channel_authority)
    assert :ok = Security.close_signing_authority(signing_authority)
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

  defp forged_call(server, asserted_pid, message) do
    reply = :erlang.alias()
    tag = [:alias | reply]
    send(server, {:"$gen_call", {asserted_pid, tag}, message})

    try do
      receive do
        {^tag, result} -> result
      after
        2_000 -> flunk("forged channel-authority call did not settle")
      end
    after
      :erlang.unalias(reply)
    end
  end
end
