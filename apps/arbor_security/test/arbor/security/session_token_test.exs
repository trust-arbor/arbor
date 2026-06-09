defmodule Arbor.Security.SessionTokenTest do
  @moduledoc """
  Tests for `Arbor.Security.SessionToken`, including the C4 review fix:
  the HMAC is verified over the raw transported payload bytes BEFORE any
  `binary_to_term`, so untrusted/garbage input is never deserialized.
  """

  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Security.SessionToken

  setup do
    prev = Application.get_env(:arbor_security, :session_token_secret)

    Application.put_env(
      :arbor_security,
      :session_token_secret,
      "test-session-secret-#{:rand.uniform(1_000_000)}"
    )

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:arbor_security, :session_token_secret)
        v -> Application.put_env(:arbor_security, :session_token_secret, v)
      end
    end)

    :ok
  end

  describe "generate/2 and verify/1 round-trip" do
    test "a freshly generated token verifies to its principal" do
      {:ok, token} = SessionToken.generate("human_abc123")
      assert {:ok, "human_abc123"} = SessionToken.verify(token)
    end

    test "expired token is rejected" do
      {:ok, token} = SessionToken.generate("human_x", ttl: -1)
      assert {:error, :token_expired} = SessionToken.verify(token)
    end
  end

  describe "tamper resistance" do
    test "a token signed with a different secret does not verify" do
      {:ok, token} = SessionToken.generate("human_x")

      # Re-key: the existing token's HMAC no longer matches.
      Application.put_env(:arbor_security, :session_token_secret, "a-completely-different-secret")
      assert {:error, :invalid_signature} = SessionToken.verify(token)
    end

    test "flipping a byte in the token invalidates it" do
      {:ok, token} = SessionToken.generate("human_x")
      {:ok, raw} = Base.url_decode64(token, padding: false)

      # Flip a byte in the payload region (after the 32-byte HMAC prefix).
      <<sig::binary-size(32), first, rest::binary>> = raw
      tampered = Base.url_encode64(sig <> <<Bitwise.bxor(first, 0xFF)>> <> rest, padding: false)

      assert {:error, _} = SessionToken.verify(tampered)
      refute match?({:ok, _}, SessionToken.verify(tampered))
    end
  end

  describe "MAC checked before deserialization (C4 regression guard)" do
    # The security property: untrusted bytes are NEVER fed to binary_to_term
    # before the HMAC is verified. A token whose payload region is arbitrary
    # (not even a valid erlang term) and whose signature is wrong must be
    # rejected with :invalid_signature — proving the MAC gate runs first. If
    # verification were reordered to deserialize first, this same input would
    # surface as :invalid_binary (or worse, materialize an attacker term).

    test "garbage payload + wrong signature → :invalid_signature, no crash" do
      garbage_sig = :crypto.strong_rand_bytes(32)
      garbage_payload = :crypto.strong_rand_bytes(64)
      token = Base.url_encode64(garbage_sig <> garbage_payload, padding: false)

      assert {:error, :invalid_signature} = SessionToken.verify(token)
    end

    test "too-short token is rejected cleanly" do
      short = Base.url_encode64(:crypto.strong_rand_bytes(10), padding: false)
      assert {:error, :malformed_token} = SessionToken.verify(short)
    end

    test "non-base64 input is rejected cleanly" do
      assert {:error, :invalid_base64} = SessionToken.verify("!!!not base64!!!")
    end

    test "non-binary input is rejected" do
      assert {:error, :invalid_token} = SessionToken.verify(:not_a_token)
    end
  end
end
