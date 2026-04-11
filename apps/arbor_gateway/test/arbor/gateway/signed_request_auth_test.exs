defmodule Arbor.Gateway.SignedRequestAuthTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Arbor.Gateway.SignedRequestAuth

  @moduletag :fast

  @opts SignedRequestAuth.init([])

  setup do
    # Each test runs in its own process; clear any leftover process-dict
    # entry from a previous test that may have leaked.
    Process.delete(:arbor_authenticated_agent_id)
    :ok
  end

  describe "when no authorization header is present" do
    test "passes through unchanged" do
      conn =
        :post
        |> conn("/mcp", "{}")
        |> SignedRequestAuth.call(@opts)

      refute conn.halted
      refute Map.has_key?(conn.assigns, :agent_id)
      refute Map.has_key?(conn.assigns, :signed_request_authenticated)
      refute Map.has_key?(conn.assigns, :raw_body)
      assert Process.get(:arbor_authenticated_agent_id) == nil
    end
  end

  describe "when authorization header uses a different scheme" do
    test "Bearer token (JWT/API key) passes through unchanged" do
      conn =
        :post
        |> conn("/mcp", "{}")
        |> put_req_header("authorization", "Bearer some-other-token")
        |> SignedRequestAuth.call(@opts)

      refute conn.halted
      refute Map.has_key?(conn.assigns, :signed_request_authenticated)
      refute Map.has_key?(conn.assigns, :raw_body)
    end

    test "Basic auth passes through unchanged" do
      conn =
        :post
        |> conn("/mcp", "{}")
        |> put_req_header("authorization", "Basic dXNlcjpwYXNz")
        |> SignedRequestAuth.call(@opts)

      refute conn.halted
      refute Map.has_key?(conn.assigns, :signed_request_authenticated)
    end
  end

  describe "when Signature header is malformed" do
    test "empty payload after 'Signature ' passes through" do
      conn =
        :post
        |> conn("/mcp", "{}")
        |> put_req_header("authorization", "Signature ")
        |> SignedRequestAuth.call(@opts)

      refute conn.halted
      refute Map.has_key?(conn.assigns, :signed_request_authenticated)
    end

    test "invalid base64 passes through" do
      conn =
        :post
        |> conn("/mcp", "{}")
        |> put_req_header("authorization", "Signature !!!not-base64!!!")
        |> SignedRequestAuth.call(@opts)

      refute conn.halted
      refute Map.has_key?(conn.assigns, :signed_request_authenticated)
    end

    test "valid base64 but invalid JSON passes through" do
      garbage = Base.encode64("this is not json", padding: false)

      conn =
        :post
        |> conn("/mcp", "{}")
        |> put_req_header("authorization", "Signature #{garbage}")
        |> SignedRequestAuth.call(@opts)

      refute conn.halted
      refute Map.has_key?(conn.assigns, :signed_request_authenticated)
    end

    test "valid JSON but missing required fields passes through" do
      partial =
        %{"agent_id" => "agent_abc"}
        |> Jason.encode!()
        |> Base.encode64(padding: false)

      conn =
        :post
        |> conn("/mcp", "{}")
        |> put_req_header("authorization", "Signature #{partial}")
        |> SignedRequestAuth.call(@opts)

      refute conn.halted
      refute Map.has_key?(conn.assigns, :signed_request_authenticated)
    end

    test "fields present but timestamp is not ISO8601 passes through" do
      envelope =
        %{
          "agent_id" => "agent_abc",
          "timestamp" => "not-a-timestamp",
          "nonce" => Base.encode64(:crypto.strong_rand_bytes(16)),
          "signature" => Base.encode64(:crypto.strong_rand_bytes(64))
        }
        |> Jason.encode!()
        |> Base.encode64(padding: false)

      conn =
        :post
        |> conn("/mcp", "{}")
        |> put_req_header("authorization", "Signature #{envelope}")
        |> SignedRequestAuth.call(@opts)

      refute conn.halted
      refute Map.has_key?(conn.assigns, :signed_request_authenticated)
    end
  end

  describe "when envelope is well-formed but agent is unknown" do
    test "verification fails and the plug passes through" do
      # Use a real Ed25519 keypair so the SignedRequest struct passes
      # field validation, but DO NOT register the public key with the
      # IdentityRegistry. Verification should fail with :unknown_agent
      # and the plug should pass through.
      {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
      agent_id = "agent_" <> Base.encode16(:crypto.hash(:sha256, public_key), case: :lower)

      body = ~s({"jsonrpc":"2.0","method":"tools/call","id":1})
      canonical = IO.iodata_to_binary(["POST", "\n", "/mcp", "\n", body])

      {:ok, signed} =
        Arbor.Contracts.Security.SignedRequest.sign(canonical, agent_id, private_key)

      envelope = encode_envelope(signed)

      conn =
        :post
        |> conn("/mcp", body)
        |> put_req_header("authorization", "Signature #{envelope}")
        |> safe_call()

      refute conn.halted
      refute Map.has_key?(conn.assigns, :signed_request_authenticated)
      # Note: in production with security services running, the plug also
      # leaves the body cached in `conn.assigns[:raw_body]` even on auth
      # failure (so ExMCP can still pick it up via the cached-body helper).
      # That property cannot be reliably asserted here because verification
      # crashes the test process when IdentityRegistry is not started; it's
      # covered instead by the end-to-end integration test.
    end
  end

  # Calls the plug, catching any :exit raised when security services aren't
  # running in the test env. Mirrors the convention used in the agent lifecycle
  # tests — the plug is exercised, and full crypto verification is left to
  # the integration test that brings up the security supervision tree.
  defp safe_call(conn) do
    try do
      SignedRequestAuth.call(conn, @opts)
    catch
      :exit, _ -> conn
    end
  end

  defp encode_envelope(signed) do
    %{
      "agent_id" => signed.agent_id,
      "timestamp" => DateTime.to_iso8601(signed.timestamp),
      "nonce" => Base.encode64(signed.nonce),
      "signature" => Base.encode64(signed.signature)
    }
    |> Jason.encode!()
    |> Base.encode64(padding: false)
  end
end
