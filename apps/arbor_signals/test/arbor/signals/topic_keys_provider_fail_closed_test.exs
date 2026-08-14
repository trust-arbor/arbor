defmodule Arbor.Signals.TopicKeysProviderFailClosedTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Signals.Config.Testing
  alias Arbor.Signals.TopicKeys

  setup do
    Arbor.Signals.TestCase.ensure_processes()
    Testing.isolate_namespace()
    :ok
  end

  test "encrypt and decrypt fail closed for absent invalid missing raise throw exit crypto" do
    Testing.delete(:crypto_module)
    assert {:error, :crypto_unavailable} = TopicKeys.encrypt(:k1f_absent, "plain")
    assert_alive()

    Testing.put(:crypto_module, true)
    assert {:error, :crypto_unavailable} = TopicKeys.encrypt(:k1f_true, "plain")
    assert_alive()

    Testing.put(:crypto_module, "not-a-module")
    assert {:error, :crypto_unavailable} = TopicKeys.encrypt(:k1f_string, "plain")
    assert_alive()

    Testing.put(:crypto_module, __MODULE__.Empty)
    assert {:error, :crypto_unavailable} = TopicKeys.encrypt(:k1f_empty, "plain")
    assert_alive()

    Testing.put(:crypto_module, __MODULE__.RaiseCrypto)
    assert {:error, :crypto_failed} = TopicKeys.encrypt(:k1f_raise, "plain")
    assert_alive()

    Testing.put(:crypto_module, __MODULE__.ThrowCrypto)
    assert {:error, :crypto_failed} = TopicKeys.encrypt(:k1f_throw, "plain")
    assert_alive()

    Testing.put(:crypto_module, __MODULE__.ExitCrypto)
    assert {:error, :crypto_failed} = TopicKeys.encrypt(:k1f_exit, "plain")
    assert_alive()

    Testing.put(:crypto_module, __MODULE__.MalformedCrypto)
    assert {:error, :crypto_failed} = TopicKeys.encrypt(:k1f_malformed, "plain")
    assert_alive()
  end

  test "decrypt preserves version mismatch and fails closed on provider crash" do
    Testing.put(:crypto_module, Arbor.Signals.Test.MockCrypto)
    assert {:ok, encrypted} = TopicKeys.encrypt(:k1f_mismatch, "data")
    assert {:ok, _} = TopicKeys.rotate(:k1f_mismatch)
    assert {:error, :key_version_mismatch} = TopicKeys.decrypt(:k1f_mismatch, encrypted)

    Testing.put(:crypto_module, Arbor.Signals.Test.MockCrypto)
    assert {:ok, live} = TopicKeys.encrypt(:k1f_decrypt_fail, "data")
    Testing.put(:crypto_module, __MODULE__.RaiseDecrypt)

    assert {:error, :crypto_failed} = TopicKeys.decrypt(:k1f_decrypt_fail, live)
    assert_alive()
  end

  defp assert_alive do
    pid = Process.whereis(TopicKeys)
    assert is_pid(pid)
    assert Process.alive?(pid)
  end

  defmodule Empty do
  end

  defmodule RaiseCrypto do
    def encrypt(_plaintext, _key), do: raise("crypto boom")
    def decrypt(_ciphertext, _key, _iv, _tag), do: raise("crypto boom")
  end

  defmodule ThrowCrypto do
    def encrypt(_plaintext, _key), do: throw(:crypto_throw)
  end

  defmodule ExitCrypto do
    def encrypt(_plaintext, _key), do: exit(:crypto_exit)
  end

  defmodule MalformedCrypto do
    def encrypt(_plaintext, _key), do: :not_a_triple
  end

  defmodule RaiseDecrypt do
    def encrypt(plaintext, key), do: Arbor.Signals.Test.MockCrypto.encrypt(plaintext, key)
    def decrypt(_ciphertext, _key, _iv, _tag), do: raise("decrypt boom")
  end
end
