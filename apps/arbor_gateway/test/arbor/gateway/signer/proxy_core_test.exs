defmodule Arbor.Gateway.Signer.ProxyCoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Gateway.Signer.ProxyCore

  @moduletag :fast

  # Helper: build a valid key_material map for tests that need to sign.
  defp generate_key_material do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    agent_id = "agent_" <> Base.encode16(:crypto.hash(:sha256, public_key), case: :lower)
    %{agent_id: agent_id, private_key: private_key, public_key: public_key}
  end

  describe "parse_key_file/1" do
    test "parses a well-formed key file" do
      contents = """
      agent_id=agent_30b455a27f7f4e02ef291fd9f7862677f731a1f8b08c997f5fb8ad430d594b6e
      private_key_b64=#{Base.encode64(:crypto.strong_rand_bytes(32))}
      """

      assert {:ok, key_material} = ProxyCore.parse_key_file(contents)
      assert key_material.agent_id =~ "agent_"
      assert is_binary(key_material.private_key)
      assert byte_size(key_material.private_key) == 32
    end

    test "accepts a 64-byte expanded Ed25519 private key" do
      contents = """
      agent_id=agent_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
      private_key_b64=#{Base.encode64(:crypto.strong_rand_bytes(64))}
      """

      assert {:ok, key_material} = ProxyCore.parse_key_file(contents)
      assert byte_size(key_material.private_key) == 64
    end

    test "tolerates extra blank lines and trailing whitespace" do
      contents = """

      agent_id=agent_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
      private_key_b64=#{Base.encode64(:crypto.strong_rand_bytes(32))}

      """

      assert {:ok, _} = ProxyCore.parse_key_file(contents)
    end

    test "errors on missing agent_id" do
      contents = "private_key_b64=#{Base.encode64(:crypto.strong_rand_bytes(32))}"
      assert {:error, {:missing_field, "agent_id"}} = ProxyCore.parse_key_file(contents)
    end

    test "errors on missing private_key_b64" do
      contents = "agent_id=agent_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      assert {:error, {:missing_field, "private_key_b64"}} = ProxyCore.parse_key_file(contents)
    end

    test "errors on invalid base64 in private_key_b64" do
      contents = """
      agent_id=agent_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
      private_key_b64=!!!not-base64!!!
      """

      assert {:error, :invalid_private_key_base64} = ProxyCore.parse_key_file(contents)
    end

    test "errors on wrong-size private key" do
      # 16 random bytes, base64-encoded — not a valid Ed25519 key size
      contents = """
      agent_id=agent_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
      private_key_b64=#{Base.encode64(:crypto.strong_rand_bytes(16))}
      """

      assert {:error, {:invalid_private_key_size, 16}} = ProxyCore.parse_key_file(contents)
    end

    test "errors on agent_id that doesn't start with 'agent_'" do
      contents = """
      agent_id=human_30b455a27f7f4e02ef291fd9f7862677f731a1f8b08c997f5fb8ad430d594b6e
      private_key_b64=#{Base.encode64(:crypto.strong_rand_bytes(32))}
      """

      assert {:error, {:invalid_agent_id, _}} = ProxyCore.parse_key_file(contents)
    end
  end

  describe "canonical_payload/3" do
    test "produces method + path + body separated by newlines" do
      result = ProxyCore.canonical_payload("POST", "/mcp", "request body")
      assert result == "POST\n/mcp\nrequest body"
    end

    test "handles empty body" do
      result = ProxyCore.canonical_payload("POST", "/mcp", "")
      assert result == "POST\n/mcp\n"
    end

    test "handles binary body with embedded newlines" do
      body = ~s({"jsonrpc":"2.0",\n  "method":"tools/call",\n  "id":1})
      result = ProxyCore.canonical_payload("POST", "/mcp", body)
      assert result == "POST\n/mcp\n" <> body
    end

    test "method and path are not interpreted, just concatenated" do
      result = ProxyCore.canonical_payload("PATCH", "/api/v2/things", "{}")
      assert result == "PATCH\n/api/v2/things\n{}"
    end
  end

  describe "sign_request/5 (happy path)" do
    test "produces a valid SignedRequest with the canonical payload" do
      key_material = generate_key_material()

      assert {:ok, %SignedRequest{} = signed} =
               ProxyCore.sign_request(key_material, "POST", "/mcp", "body bytes")

      assert signed.payload == "POST\n/mcp\nbody bytes"
      assert signed.agent_id == key_material.agent_id
      assert is_binary(signed.signature)
      assert byte_size(signed.signature) == 64
      assert is_binary(signed.nonce)
      assert byte_size(signed.nonce) == 16
      assert %DateTime{} = signed.timestamp
    end

    test "the signature actually verifies against the canonical payload" do
      # End-to-end check: sign, then verify with the public key. This is the
      # property we ACTUALLY care about — the signed bytes line up with the
      # canonical bytes the server reconstructs.
      key_material = generate_key_material()

      {:ok, signed} =
        ProxyCore.sign_request(key_material, "POST", "/mcp", "request body")

      # Reconstruct the same canonical bytes the server would
      message = SignedRequest.signing_payload(signed)

      assert :crypto.verify(
               :eddsa,
               :sha512,
               message,
               signed.signature,
               [key_material.public_key, :ed25519]
             )
    end
  end

  describe "encode_envelope/1" do
    test "produces base64-encoded JSON with the four expected fields" do
      key_material = generate_key_material()
      {:ok, signed} = ProxyCore.sign_request(key_material, "POST", "/mcp", "body")

      encoded = ProxyCore.encode_envelope(signed)
      assert is_binary(encoded)

      {:ok, decoded_json} = Base.decode64(encoded, padding: false)
      {:ok, decoded} = Jason.decode(decoded_json)

      assert decoded["agent_id"] == key_material.agent_id
      assert is_binary(decoded["timestamp"])
      assert is_binary(decoded["nonce"])
      assert is_binary(decoded["signature"])

      # The four expected fields and nothing else
      assert Map.keys(decoded) |> Enum.sort() ==
               ["agent_id", "nonce", "signature", "timestamp"]
    end

    test "timestamp round-trips through ISO8601" do
      key_material = generate_key_material()
      {:ok, signed} = ProxyCore.sign_request(key_material, "POST", "/mcp", "body")

      encoded = ProxyCore.encode_envelope(signed)
      {:ok, decoded_json} = Base.decode64(encoded, padding: false)
      {:ok, decoded} = Jason.decode(decoded_json)

      {:ok, parsed, _} = DateTime.from_iso8601(decoded["timestamp"])
      # Should match within a millisecond (ISO8601 round trip preserves microsecond precision)
      assert DateTime.compare(parsed, signed.timestamp) == :eq
    end

    test "nonce and signature round-trip through base64" do
      key_material = generate_key_material()
      {:ok, signed} = ProxyCore.sign_request(key_material, "POST", "/mcp", "body")

      encoded = ProxyCore.encode_envelope(signed)
      {:ok, decoded_json} = Base.decode64(encoded, padding: false)
      {:ok, decoded} = Jason.decode(decoded_json)

      assert {:ok, nonce_bytes} = Base.decode64(decoded["nonce"])
      assert nonce_bytes == signed.nonce

      assert {:ok, sig_bytes} = Base.decode64(decoded["signature"])
      assert sig_bytes == signed.signature
    end

    test "the envelope does NOT include the payload field" do
      # Critical security property: the server reconstructs the canonical
      # payload from the actual request bytes. The envelope must NOT carry
      # a separate payload field, or an attacker could supply a payload that
      # disagrees with the body and confuse the verification.
      key_material = generate_key_material()
      {:ok, signed} = ProxyCore.sign_request(key_material, "POST", "/mcp", "body")

      encoded = ProxyCore.encode_envelope(signed)
      {:ok, decoded_json} = Base.decode64(encoded, padding: false)
      {:ok, decoded} = Jason.decode(decoded_json)

      refute Map.has_key?(decoded, "payload")
    end
  end

  describe "authorization_header_value/1" do
    test "starts with 'Signature ' followed by the encoded envelope" do
      key_material = generate_key_material()
      {:ok, signed} = ProxyCore.sign_request(key_material, "POST", "/mcp", "body")

      header = ProxyCore.authorization_header_value(signed)

      assert String.starts_with?(header, "Signature ")
      assert String.length(header) > String.length("Signature ")
    end
  end

  describe "jsonrpc_error_response/4" do
    test "builds a JSON-RPC 2.0 error response with id and code" do
      result = ProxyCore.jsonrpc_error_response(42, -32_603, "internal error")

      assert result["jsonrpc"] == "2.0"
      assert result["id"] == 42
      assert result["error"]["code"] == -32_603
      assert result["error"]["message"] == "internal error"
      refute Map.has_key?(result["error"], "data")
    end

    test "includes data field when provided" do
      result =
        ProxyCore.jsonrpc_error_response("req-1", -32_700, "parse error", %{"line" => 5})

      assert result["error"]["data"] == %{"line" => 5}
      assert result["id"] == "req-1"
    end

    test "accepts nil id (e.g., for parse errors before id is known)" do
      result = ProxyCore.jsonrpc_error_response(nil, -32_700, "parse error")
      assert result["id"] == nil
    end
  end

  describe "extract_id/1" do
    test "returns the id field when present and an integer" do
      assert ProxyCore.extract_id(%{"id" => 42}) == 42
    end

    test "returns the id field when present and a string" do
      assert ProxyCore.extract_id(%{"id" => "req-abc"}) == "req-abc"
    end

    test "returns nil when id is missing" do
      assert ProxyCore.extract_id(%{"jsonrpc" => "2.0"}) == nil
    end

    test "returns nil when id is the wrong type" do
      assert ProxyCore.extract_id(%{"id" => %{}}) == nil
      assert ProxyCore.extract_id(%{"id" => [1, 2, 3]}) == nil
    end

    test "returns nil for nil input" do
      assert ProxyCore.extract_id(nil) == nil
    end
  end

  describe "round-trip property: client signs, server can verify the canonical bytes" do
    test "the bytes the client signs match what the server would reconstruct" do
      # This is the property that the proxy's whole correctness depends on:
      # the client (this proxy) and the server (SignedRequestAuth) MUST agree
      # on the canonical byte layout. If either side changes, every signed
      # request breaks. This test locks the format.
      key_material = generate_key_material()
      method = "POST"
      path = "/mcp"
      body = ~s({"jsonrpc":"2.0","method":"tools/call","id":1})

      # Client side (proxy)
      {:ok, signed} = ProxyCore.sign_request(key_material, method, path, body)
      client_canonical = signed.payload

      # Server side reconstruction (mirroring SignedRequestAuth.bind_payload)
      server_canonical = IO.iodata_to_binary([method, "\n", path, "\n", body])

      assert client_canonical == server_canonical
    end
  end
end
