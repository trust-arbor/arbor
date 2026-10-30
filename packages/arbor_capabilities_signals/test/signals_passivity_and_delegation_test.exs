defmodule Arbor.Capabilities.Signals.PassivityAndDelegationTest do
  use ExUnit.Case, async: false

  alias Arbor.Capabilities.Signals

  @moduletag :fast

  test "loading the passive adapter starts no Core authority or Signals runtime" do
    before = started_applications()
    authority = Process.whereis(Arbor.Security.Supervisor)
    bus = Process.whereis(Arbor.Signals.Bus)
    distributed = Node.alive?()

    assert {:ok, _} = Application.ensure_all_started(:arbor_capabilities_signals)
    assert Application.spec(:arbor_capabilities_signals, :mod) in [nil, []]
    assert Application.spec(:arbor_capabilities_signals, :registered) in [nil, []]

    for key <- [:applications, :optional_applications, :included_applications],
        owner <- [:arbor_capabilities, :arbor_signals, :arbor_kernel_runtime, :arbor_security] do
      refute owner in (Application.spec(:arbor_capabilities_signals, key) || [])
    end

    after_start = started_applications()

    for owner <- [:arbor_capabilities, :arbor_signals] do
      assert MapSet.member?(after_start, owner) == MapSet.member?(before, owner)
    end

    assert Process.whereis(Arbor.Security.Supervisor) == authority
    assert Process.whereis(Arbor.Signals.Bus) == bus
    assert Node.alive?() == distributed
  end

  test "public crypto delegates preserve real round trips and authentication failures without authority startup" do
    before = started_applications()
    assert {:ok, _} = Application.ensure_all_started(:crypto)

    key = :crypto.strong_rand_bytes(32)
    plaintext = "adapter owning suite"
    {ciphertext, iv, tag} = Signals.encrypt(plaintext, key)
    assert {:ok, ^plaintext} = Signals.decrypt(ciphertext, key, iv, tag)
    assert {:ok, ^plaintext} = Arbor.Security.decrypt(ciphertext, key, iv, tag)
    <<first, rest::binary>> = tag
    tampered = <<Bitwise.bxor(first, 1), rest::binary>>
    assert {:error, :decryption_failed} = Signals.decrypt(ciphertext, key, iv, tampered)

    {recipient_public, recipient_private} = Signals.generate_encryption_keypair()
    {sender_public, sender_private} = :crypto.generate_key(:eddsa, :ed25519)
    sealed = Signals.seal(plaintext, recipient_public, sender_private)
    assert {:ok, ^plaintext} = Signals.unseal(sealed, recipient_private, sender_public)

    after_calls = started_applications()

    for owner <- [:arbor_capabilities, :arbor_signals] do
      assert MapSet.member?(after_calls, owner) == MapSet.member?(before, owner)
    end
  end

  defp started_applications do
    Application.started_applications() |> Enum.map(&elem(&1, 0)) |> MapSet.new()
  end
end
