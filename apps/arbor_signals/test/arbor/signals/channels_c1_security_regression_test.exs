defmodule Arbor.Signals.ChannelsC1SecurityRegressionTest do
  @moduledoc """
  C1 security regression (2026-02-16 review): channel authority private keys
  must NOT be stored as plaintext in the Channels GenServer state.

  The threat is memory dumps / process inspection (`:sys.get_state/1`) /
  crash-dump analysis recovering the authority private key in the clear.
  The fix (`channels.ex#encrypt_state_key/1`) stores the authority private
  key as an opaque AES-GCM ciphertext tuple `{ciphertext, iv, tag}` instead
  of the raw key bytes.

  This test asserts behaviorally — via the same `:sys.get_state/1`
  introspection path an attacker would use — that the stored private-key
  material is the encrypted tuple form, not the raw 32-byte X25519 key.

  Uses the global `Arbor.Signals.Test.MockCrypto` (configured in
  test_helper.exs), which performs real AES-256-GCM encryption, so the
  stored ciphertext is genuinely opaque.
  """
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Signals.Channels

  setup do
    Arbor.Signals.TestCase.ensure_processes()
    :ok
  end

  test "C1 security regression: authority private key is not recoverable as plaintext from GenServer state" do
    creator_id = "agent_c1_creator"

    {:ok, channel, _key} = Channels.create("c1-regression-channel", creator_id)
    channel_id = channel.id

    state = :sys.get_state(Channels)
    entry = state.channels[channel_id]

    assert entry != nil, "channel entry must exist in GenServer state"

    stored_private = entry.authority_keypair.private

    # The encrypted-at-rest form is the 3-tuple {ciphertext, iv, tag}.
    # If the C1 fix is reverted, the raw X25519 private key (a 32-byte
    # binary) is stored directly here — which is exactly what this asserts
    # against.
    assert match?({_ciphertext, _iv, _tag}, stored_private),
           "authority private key must be stored as an encrypted {ciphertext, iv, tag} tuple, " <>
             "got: #{inspect(stored_private)}"

    refute is_binary(stored_private),
           "authority private key must NOT be a raw binary in GenServer state (C1)"
  end
end
