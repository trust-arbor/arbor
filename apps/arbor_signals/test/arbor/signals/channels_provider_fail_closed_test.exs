defmodule Arbor.Signals.ChannelsProviderFailClosedTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Signals.Channels

  setup do
    Arbor.Signals.TestCase.ensure_processes()

    originals = %{
      crypto: Application.get_env(:arbor_signals, :crypto_module, :unset),
      identity: Application.get_env(:arbor_signals, :identity_registry_module, :unset)
    }

    on_exit(fn ->
      restore(:crypto_module, originals.crypto)
      restore(:identity_registry_module, originals.identity)
    end)

    :ok
  end

  test "create fails closed for absent invalid missing raise throw exit crypto" do
    Application.delete_env(:arbor_signals, :crypto_module)
    assert {:error, :crypto_unavailable} = Channels.create("absent", "agent_creator")
    assert_alive()

    Application.put_env(:arbor_signals, :crypto_module, true)
    assert {:error, :crypto_unavailable} = Channels.create("true", "agent_creator")
    assert_alive()

    Application.put_env(:arbor_signals, :crypto_module, "not-a-module")
    assert {:error, :crypto_unavailable} = Channels.create("string", "agent_creator")
    assert_alive()

    Application.put_env(:arbor_signals, :crypto_module, __MODULE__.Empty)
    assert {:error, :crypto_unavailable} = Channels.create("empty", "agent_creator")
    assert_alive()

    Application.put_env(:arbor_signals, :crypto_module, __MODULE__.RaiseCrypto)
    assert {:error, :crypto_failed} = Channels.create("raise", "agent_creator")
    assert_alive()

    Application.put_env(:arbor_signals, :crypto_module, __MODULE__.ThrowCrypto)
    assert {:error, :crypto_failed} = Channels.create("throw", "agent_creator")
    assert_alive()

    Application.put_env(:arbor_signals, :crypto_module, __MODULE__.ExitCrypto)
    assert {:error, :crypto_failed} = Channels.create("exit", "agent_creator")
    assert_alive()

    Application.put_env(:arbor_signals, :crypto_module, __MODULE__.MalformedCrypto)
    assert {:error, :crypto_failed} = Channels.create("malformed", "agent_creator")
    assert_alive()
  end

  test "send fails closed when crypto becomes unavailable after create" do
    Application.put_env(:arbor_signals, :crypto_module, Arbor.Signals.Test.MockCrypto)
    assert {:ok, channel, _key} = Channels.create("send-fail", "agent_sender")

    Application.put_env(:arbor_signals, :crypto_module, __MODULE__.RaiseCrypto)

    assert {:error, :crypto_failed} =
             Channels.send(channel.id, "agent_sender", :hello, %{body: "hi"})

    assert_alive()
  end

  test "invite fails closed for absent invalid missing malformed raise throw exit identity" do
    Application.put_env(:arbor_signals, :crypto_module, Arbor.Signals.Test.MockCrypto)
    Application.delete_env(:arbor_signals, :identity_registry_module)

    assert {:ok, channel, _key} = Channels.create("invite-fail", "agent_inviter")

    keychain = %{
      agent_id: "agent_inviter",
      encryption_keypair: %{private: :crypto.strong_rand_bytes(32)},
      signing_keypair: %{private: :crypto.strong_rand_bytes(32)}
    }

    assert {:error, :registry_unavailable} =
             Channels.invite(channel.id, "agent_invitee", keychain)

    assert_alive()

    Application.put_env(:arbor_signals, :identity_registry_module, true)

    assert {:error, :registry_unavailable} =
             Channels.invite(channel.id, "agent_invitee", keychain)

    assert_alive()

    Application.put_env(:arbor_signals, :identity_registry_module, "not-a-module")

    assert {:error, :registry_unavailable} =
             Channels.invite(channel.id, "agent_invitee", keychain)

    assert_alive()

    Application.put_env(:arbor_signals, :identity_registry_module, __MODULE__.Empty)

    assert {:error, :registry_unavailable} =
             Channels.invite(channel.id, "agent_invitee", keychain)

    assert_alive()

    Application.put_env(:arbor_signals, :identity_registry_module, __MODULE__.MalformedRegistry)

    assert {:error, :registry_unavailable} =
             Channels.invite(channel.id, "agent_invitee", keychain)

    assert_alive()

    Application.put_env(:arbor_signals, :identity_registry_module, __MODULE__.RaiseRegistry)

    assert {:error, :registry_unavailable} =
             Channels.invite(channel.id, "agent_invitee", keychain)

    assert_alive()

    Application.put_env(:arbor_signals, :identity_registry_module, __MODULE__.ThrowRegistry)

    assert {:error, :registry_unavailable} =
             Channels.invite(channel.id, "agent_invitee", keychain)

    assert_alive()

    Application.put_env(:arbor_signals, :identity_registry_module, __MODULE__.ExitRegistry)

    assert {:error, :registry_unavailable} =
             Channels.invite(channel.id, "agent_invitee", keychain)

    assert_alive()
  end

  defp assert_alive do
    pid = Process.whereis(Channels)
    assert is_pid(pid)
    assert Process.alive?(pid)
  end

  defp restore(key, :unset), do: Application.delete_env(:arbor_signals, key)
  defp restore(key, value), do: Application.put_env(:arbor_signals, key, value)

  defmodule Empty do
  end

  defmodule RaiseCrypto do
    def generate_encryption_keypair, do: raise("crypto boom")
    def encrypt(_plaintext, _key), do: raise("crypto boom")
    def seal(_plaintext, _pub, _priv), do: raise("crypto boom")
  end

  defmodule ThrowCrypto do
    def generate_encryption_keypair, do: throw(:crypto_throw)
    def encrypt(_plaintext, _key), do: throw(:crypto_throw)
  end

  defmodule ExitCrypto do
    def generate_encryption_keypair, do: exit(:crypto_exit)
    def encrypt(_plaintext, _key), do: exit(:crypto_exit)
  end

  defmodule MalformedCrypto do
    def generate_encryption_keypair, do: :not_a_keypair
    def encrypt(_plaintext, _key), do: :not_a_triple
  end

  defmodule RaiseRegistry do
    def lookup_encryption_key(_agent_id), do: raise("registry boom")
    def lookup(_agent_id), do: raise("registry boom")
  end

  defmodule ThrowRegistry do
    def lookup_encryption_key(_agent_id), do: throw(:registry_throw)
    def lookup(_agent_id), do: throw(:registry_throw)
  end

  defmodule ExitRegistry do
    def lookup_encryption_key(_agent_id), do: exit(:registry_exit)
    def lookup(_agent_id), do: exit(:registry_exit)
  end

  defmodule MalformedRegistry do
    def lookup_encryption_key(_agent_id), do: :ok
    def lookup(_agent_id), do: :ok
  end
end
