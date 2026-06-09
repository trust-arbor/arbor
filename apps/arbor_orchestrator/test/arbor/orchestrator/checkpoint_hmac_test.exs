defmodule Arbor.Orchestrator.CheckpointHmacTest do
  @moduledoc """
  Regression guard for crypto-review C7.

  The checkpoint HMAC secret used to be derived two different ways for the
  same key — HKDF when `Arbor.Security.Crypto` was loaded, plain HMAC
  otherwise — so a checkpoint signed in one mode failed verification in the
  other whenever load state differed (hot reload, a different node,
  arbor_security not yet started). The fix collapses to a single,
  load-INDEPENDENT derivation that depends only on the key.

  This pins that derivation: the secret must equal
  `HMAC-SHA256(key, "arbor-checkpoint-hmac-v2")` and nothing else. Reverting
  to the HKDF/branch path changes the bytes and fails this test.
  """

  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Orchestrator.Engine

  test "checkpoint HMAC secret is a single pinned load-independent derivation" do
    key = :binary.copy(<<0x37>>, 32)
    expected = :crypto.mac(:hmac, :sha256, key, "arbor-checkpoint-hmac-v2")

    assert Engine.derive_checkpoint_hmac_secret(identity_private_key: key) == expected
    # Deterministic across calls.
    assert Engine.derive_checkpoint_hmac_secret(identity_private_key: key) == expected
  end

  test "no identity key → no secret" do
    assert Engine.derive_checkpoint_hmac_secret([]) == nil
    assert Engine.derive_checkpoint_hmac_secret(identity_private_key: "") == nil
    assert Engine.derive_checkpoint_hmac_secret(identity_private_key: nil) == nil
  end
end
