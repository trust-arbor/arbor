defmodule ArborTui.SignerTest do
  use ExUnit.Case, async: true

  alias ArborTui.Signer

  # A throwaway Ed25519 identity (agent_id need only be shaped right for the
  # client; the server derives the real id from the public key).
  defp identity do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    agent_id = "agent_" <> Base.encode16(:crypto.hash(:sha256, pub), case: :lower)
    {%{agent_id: agent_id, private_key: priv}, pub}
  end

  describe "parse_key/1" do
    test "parses a .arbor.key file" do
      {%{agent_id: id, private_key: priv}, _pub} = identity()
      contents = "agent_id=#{id}\nprivate_key_b64=#{Base.encode64(priv)}\n"

      assert {:ok, %{agent_id: ^id, private_key: ^priv}} = Signer.parse_key(contents)
    end

    test "rejects a bad agent_id" do
      assert {:error, {:invalid_agent_id, _}} =
               Signer.parse_key("agent_id=nope\nprivate_key_b64=#{Base.encode64(<<0::256>>)}\n")
    end

    test "rejects missing fields" do
      assert {:error, {:missing_field, "private_key_b64"}} =
               Signer.parse_key("agent_id=agent_abcdef\n")
    end
  end

  describe "authorization_header/4" do
    test "produces a verifiable Ed25519 signature over the canonical payload" do
      {id, pub} = identity()
      method = "GET"
      path = "/api/chat/socket"
      body = ""

      "Signature " <> envelope_b64 = Signer.authorization_header(id, method, path, body)

      # Decode the wire envelope exactly as Arbor.Gateway.SignedRequestAuth does.
      {:ok, json} = Base.decode64(envelope_b64, padding: false)
      env = Jason.decode!(json)

      assert env["agent_id"] == id.agent_id
      {:ok, nonce} = Base.decode64(env["nonce"])
      {:ok, signature} = Base.decode64(env["signature"])
      assert byte_size(nonce) == 16

      # Reconstruct the signed message: length-prefixed canonical payload, agent
      # id, iso8601 timestamp, then the raw nonce — identical to the server's
      # SignedRequest.compute_signing_payload/1.
      canonical = Signer.canonical_payload(method, path, body)

      message =
        len(canonical) <> len(id.agent_id) <> len(env["timestamp"]) <> nonce

      assert :crypto.verify(:eddsa, :sha512, message, signature, [pub, :ed25519])
    end

    test "canonical_payload matches the server fingerprint format" do
      assert Signer.canonical_payload("GET", "/api/chat/socket", "") ==
               "GET\n/api/chat/socket\n"
    end
  end

  defp len(bin), do: <<byte_size(bin)::32, bin::binary>>
end
