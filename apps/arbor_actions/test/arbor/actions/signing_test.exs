defmodule Arbor.Actions.SigningTest do
  @moduledoc """
  Tests for cryptographic identity verification in authorize_and_execute.

  Verifies that signed requests flow through to Security.authorize/4
  and that identity/resource binding works correctly.
  """
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Contracts.Security.Identity
  alias Arbor.Contracts.Security.SignedRequest

  setup do
    # Generate a fresh identity for each test
    {:ok, identity} = Identity.generate(name: "test-signer")
    agent_id = identity.agent_id

    # Register identity so Verifier can look up the public key
    :ok = Arbor.Security.register_identity(identity)

    # A read target the auth chain will actually accept. Two layers must pass:
    # (1) capability matching — since the C8 fix (2026-06-09) a concrete cap grants
    # NO implicit subtree, and authorize_and_execute path-synthesizes the resource
    # to "arbor://fs/read/<path>", so we need a `/**` subtree cap whose root
    # contains the path; (2) FileGuard — which resolves symlinks, so the path must
    # NOT be under /tmp or /var (macOS symlinks those to /private/... → symlink
    # escape vs the cap root). The repo cwd is symlink-free, so scope there.
    read_dir = File.cwd!()
    read_path = Path.join(read_dir, "arbor_signing_test_nonexistent_file")

    {:ok, _cap} =
      Arbor.Security.grant(
        principal: agent_id,
        resource: "arbor://fs/read#{read_dir}/**"
      )

    on_exit(fn ->
      # Clean up capabilities for this agent
      case Arbor.Security.list_capabilities(agent_id) do
        {:ok, caps} ->
          Enum.each(caps, fn cap -> Arbor.Security.revoke(cap.id) end)

        _ ->
          :ok
      end
    end)

    {:ok, identity: identity, agent_id: agent_id, read_path: read_path}
  end

  describe "authorize_and_execute with signed_request" do
    test "succeeds with valid signed request", %{
      identity: identity,
      agent_id: agent_id,
      read_path: read_path
    } do
      resource = "arbor://fs/read"
      {:ok, signed} = SignedRequest.sign(resource, agent_id, identity.private_key)

      # Pass signed_request in context — authorize_and_execute extracts it
      context = %{signed_request: signed}

      # file_read with a valid path should work (action may fail on missing file,
      # but authorization should pass)
      result =
        Arbor.Actions.authorize_and_execute(
          agent_id,
          Arbor.Actions.File.Read,
          %{path: read_path},
          context
        )

      # Either succeeds with file content or fails with file error (not :unauthorized)
      case result do
        {:ok, _} -> :ok
        {:error, :unauthorized} -> flunk("Should not be unauthorized with valid signed request")
        {:error, _reason} -> :ok
      end
    end

    test "fails with wrong agent_id in signed request", %{identity: identity} do
      # Sign with the correct key but a different agent_id
      other_agent_id = "agent_impersonator_#{:erlang.unique_integer([:positive])}"

      resource = "arbor://fs/read"
      # Sign as the real identity
      {:ok, signed} = SignedRequest.sign(resource, identity.agent_id, identity.private_key)

      # Try to use it for a different agent
      context = %{signed_request: signed}

      # This should fail — the signed agent_id doesn't match other_agent_id
      # But it depends on identity_verification being enabled
      # In test, it's typically disabled, so this tests the opt-in path
      result =
        Arbor.Actions.authorize_and_execute(
          other_agent_id,
          Arbor.Actions.File.Read,
          %{path: "/tmp/test"},
          context
        )

      # With signed_request in context, verify_identity is forced to true
      # The identity_mismatch should cause :unauthorized
      assert {:error, :unauthorized} = result
    end

    test "fails with resource mismatch", %{identity: identity, agent_id: agent_id} do
      # Sign for a different resource (shell instead of fs/read)
      {:ok, signed} =
        SignedRequest.sign(
          "arbor://shell/exec",
          agent_id,
          identity.private_key
        )

      context = %{signed_request: signed}

      result =
        Arbor.Actions.authorize_and_execute(
          agent_id,
          Arbor.Actions.File.Read,
          %{path: "/tmp/test"},
          context
        )

      # Resource mismatch: signed for shell/exec, executing fs/read
      assert {:error, :unauthorized} = result
    end

    test "backward compatible without signed_request", %{agent_id: agent_id, read_path: read_path} do
      # No context (default path) — should still work based on capability alone
      result =
        Arbor.Actions.authorize_and_execute(
          agent_id,
          Arbor.Actions.File.Read,
          %{path: read_path}
        )

      # Should not be unauthorized (capability is granted)
      case result do
        {:error, :unauthorized} -> flunk("Should be authorized via capability")
        _ -> :ok
      end
    end

    test "security regression: gateway-preverified MCP HTTP signature is not re-verified", %{
      identity: identity,
      agent_id: agent_id,
      read_path: read_path
    } do
      # MCP signer proxy signs method+path+body. Gateway SignedRequestAuth verifies
      # once and consumes the nonce. The handler then forwards the same proof with
      # identity_verified: true. Pre-fix, authorize_and_execute always set
      # verify_identity: true + expected_resource: action URI, so every MCP tools/call
      # failed as :unauthorized (replayed_nonce and/or resource_mismatch).
      http_payload = "POST\n/mcp\n{\"jsonrpc\":\"2.0\",\"method\":\"tools/call\"}"
      {:ok, signed} = SignedRequest.sign(http_payload, agent_id, identity.private_key)

      # Simulate gateway consume of the nonce (first verify wins).
      assert {:ok, ^agent_id} = Arbor.Security.verify_request(signed)

      result =
        Arbor.Actions.authorize_and_execute(
          agent_id,
          Arbor.Actions.File.Read,
          %{path: read_path},
          %{signed_request: signed, identity_verified: true}
        )

      case result do
        {:error, :unauthorized} ->
          flunk(
            "Gateway-preverified MCP signature must not be re-verified — would hit :replayed_nonce / :resource_mismatch"
          )

        _ ->
          :ok
      end
    end

    test "security regression: nested action reuses parent auth_context.identity_verified", %{
      identity: identity,
      agent_id: agent_id,
      read_path: read_path
    } do
      # coding_produce_reviewable_change (and similar composites) authorize once,
      # mark AuthContext verified, then nest authorize_and_execute for validation
      # actions like Mix.Compile. The nested call reuses the parent's
      # resource-bound signed_request; re-verifying it against the nested URI
      # fails with :resource_mismatch / :replayed_nonce → :unauthorized.
      parent_resource = "arbor://action/coding/produce_reviewable_change"
      {:ok, signed} = SignedRequest.sign(parent_resource, agent_id, identity.private_key)

      # Parent layer consumes the nonce and marks the AuthContext verified.
      assert {:ok, ^agent_id} = Arbor.Security.verify_request(signed)

      auth_context =
        Arbor.Contracts.Security.AuthContext.new(agent_id, signed_request: signed)
        |> Arbor.Contracts.Security.AuthContext.mark_verified()

      result =
        Arbor.Actions.authorize_and_execute(
          agent_id,
          Arbor.Actions.File.Read,
          %{path: read_path},
          %{signed_request: signed, auth_context: auth_context}
        )

      case result do
        {:error, :unauthorized} ->
          flunk(
            "Nested authorize_and_execute must honor parent auth_context.identity_verified; " <>
              "re-verifying the parent signed_request against a nested resource is a security regression"
          )

        _ ->
          :ok
      end
    end

    test "security regression: plain identity_verified map does not skip signed-request verify",
         %{
           identity: identity,
           agent_id: agent_id,
           read_path: read_path
         } do
      parent_resource = "arbor://action/coding/produce_reviewable_change"
      {:ok, signed} = SignedRequest.sign(parent_resource, agent_id, identity.private_key)
      assert {:ok, ^agent_id} = Arbor.Security.verify_request(signed)

      # Spoof: caller injects a plain map instead of %AuthContext{}.
      # After the parent nonce is consumed, re-verify must fail closed —
      # a bare map must not widen the identity_verified bypass.
      result =
        Arbor.Actions.authorize_and_execute(
          agent_id,
          Arbor.Actions.File.Read,
          %{path: read_path},
          %{
            signed_request: signed,
            auth_context: %{identity_verified: true, principal_id: agent_id}
          }
        )

      assert result == {:error, :unauthorized}
    end

    test "security regression: AuthContext for a different principal does not skip verify", %{
      identity: identity,
      agent_id: agent_id,
      read_path: read_path
    } do
      parent_resource = "arbor://action/coding/produce_reviewable_change"
      {:ok, signed} = SignedRequest.sign(parent_resource, agent_id, identity.private_key)
      assert {:ok, ^agent_id} = Arbor.Security.verify_request(signed)

      other = "agent_other_#{System.unique_integer([:positive])}"

      auth_context =
        Arbor.Contracts.Security.AuthContext.new(other, signed_request: signed)
        |> Arbor.Contracts.Security.AuthContext.mark_verified()

      result =
        Arbor.Actions.authorize_and_execute(
          agent_id,
          Arbor.Actions.File.Read,
          %{path: read_path},
          %{signed_request: signed, auth_context: auth_context}
        )

      assert result == {:error, :unauthorized}
    end
  end

  describe "authorized file_glob base enforcement" do
    test "security regression: public agent call cannot evaluate an absolute pattern without a base",
         %{agent_id: agent_id} do
      {:ok, _cap} =
        Arbor.Security.grant(
          principal: agent_id,
          resource: "arbor://fs/read"
        )

      result =
        Arbor.Actions.authorize_and_execute(
          agent_id,
          Arbor.Actions.File.Glob,
          %{pattern: Path.join(File.cwd!(), "apps/*/mix.exs")}
        )

      assert {:error, message} = result
      assert message =~ "authorized base_path or workspace"
    end

    test "public agent call preserves workspace-relative glob behavior", %{agent_id: agent_id} do
      {:ok, _cap} =
        Arbor.Security.grant(
          principal: agent_id,
          resource: "arbor://fs/read"
        )

      workspace = File.cwd!()

      assert {:ok, result} =
               Arbor.Actions.authorize_and_execute(
                 agent_id,
                 Arbor.Actions.File.Glob,
                 %{pattern: "apps/*/mix.exs"},
                 %{workspace: workspace}
               )

      assert result.count > 0
      assert Enum.all?(result.matches, &String.starts_with?(&1, Path.join(workspace, "apps")))
    end
  end

  describe "make_signer/2" do
    test "creates a working signer function", %{identity: identity, agent_id: agent_id} do
      signer = Arbor.Security.make_signer(agent_id, identity.private_key)
      assert is_function(signer, 1)

      {:ok, signed} = signer.("arbor://fs/read")
      assert %SignedRequest{} = signed
      assert signed.agent_id == agent_id
      assert signed.payload == "arbor://fs/read"
    end

    test "each call produces unique nonce", %{identity: identity, agent_id: agent_id} do
      signer = Arbor.Security.make_signer(agent_id, identity.private_key)

      {:ok, signed1} = signer.("test")
      {:ok, signed2} = signer.("test")

      refute signed1.nonce == signed2.nonce
    end
  end
end
