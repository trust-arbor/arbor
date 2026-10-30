defmodule Arbor.Security.KeychainLegacyVersionSecurityRegressionTest do
  use ExUnit.Case, async: true

  @moduletag :fast
  @moduletag :security_regression
  @moduletag spec: "SSEC-014"

  alias Arbor.Security.Crypto
  alias Arbor.Security.Keychain

  test "security regression: deserialize rejects an authenticated legacy v1 keychain" do
    keychain = Keychain.new("agent_legacy_keychain")
    root_key = :crypto.strong_rand_bytes(32)

    private_data = %{
      "signing_private" => Base.encode64(keychain.signing_keypair.private),
      "encryption_private" => Base.encode64(keychain.encryption_keypair.private),
      "channel_keys" => %{},
      "ratchet_sessions" => %{}
    }

    {ciphertext, iv, tag} = Crypto.encrypt(Jason.encode!(private_data), root_key)

    inner =
      Jason.encode!(%{
        "version" => 1,
        "public" => %{
          "agent_id" => keychain.agent_id,
          "signing_public" => Base.encode64(keychain.signing_keypair.public),
          "encryption_public" => Base.encode64(keychain.encryption_keypair.public),
          "peers" => %{},
          "channel_ids" => []
        },
        "private_encrypted" => Base.encode64(ciphertext),
        "iv" => Base.encode64(iv),
        "tag" => Base.encode64(tag)
      })

    legacy_payload =
      Jason.encode!(%{
        "payload" => inner,
        "hmac" => Base.encode64(:crypto.mac(:hmac, :sha256, root_key, inner))
      })

    assert {:error, :unsupported_version} = Keychain.deserialize(legacy_payload, root_key)
  end
end
