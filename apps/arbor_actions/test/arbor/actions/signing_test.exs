defmodule Arbor.Actions.SigningTest do
  @moduledoc """
  Tests for cryptographic identity verification in authorize_and_execute.

  Verifies that signed requests flow through to Security.authorize/4
  and that identity/resource binding works correctly.
  """
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Security.Identity
  alias Arbor.Contracts.Security.SignedRequest

  setup do
    # Generate a fresh identity for each test
    {:ok, identity} = Identity.generate(name: "test-signer")
    agent_id = identity.agent_id

    # Register identity so Verifier can look up the public key
    :ok = Arbor.Security.register_identity(identity)

    # Grant capability for file_read
    {:ok, _cap} =
      Arbor.Security.grant(
        principal: agent_id,
        resource: "arbor://actions/execute/file.read"
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

    {:ok, identity: identity, agent_id: agent_id}
  end

  describe "authorize_and_execute with signed_request" do
    test "succeeds with valid signed request", %{identity: identity, agent_id: agent_id} do
      resource = "arbor://actions/execute/file.read"
      {:ok, signed} = SignedRequest.sign(resource, agent_id, identity.private_key)

      # Pass signed_request in context — authorize_and_execute extracts it
      context = %{signed_request: signed}

      # file_read with a valid path should work (action may fail on missing file,
      # but authorization should pass)
      result =
        Arbor.Actions.authorize_and_execute(
          agent_id,
          Arbor.Actions.File.Read,
          %{path: "/tmp/arbor_test_nonexistent_file"},
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

      resource = "arbor://actions/execute/file.read"
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
      # Sign for a different resource
      {:ok, signed} =
        SignedRequest.sign(
          "arbor://actions/execute/shell_execute",
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

      # Resource mismatch: signed for shell_execute, executing file_read
      assert {:error, :unauthorized} = result
    end

    test "backward compatible without signed_request", %{agent_id: agent_id} do
      # No context (default path) — should still work based on capability alone
      result =
        Arbor.Actions.authorize_and_execute(
          agent_id,
          Arbor.Actions.File.Read,
          %{path: "/tmp/arbor_test_nonexistent_file"}
        )

      # Should not be unauthorized (capability is granted)
      case result do
        {:error, :unauthorized} -> flunk("Should be authorized via capability")
        _ -> :ok
      end
    end
  end

  describe "make_signer/2" do
    test "creates a working signer function", %{identity: identity, agent_id: agent_id} do
      signer = Arbor.Security.make_signer(agent_id, identity.private_key)
      assert is_function(signer, 1)

      {:ok, signed} = signer.("arbor://actions/execute/file.read")
      assert %SignedRequest{} = signed
      assert signed.agent_id == agent_id
      assert signed.payload == "arbor://actions/execute/file.read"
    end

    test "each call produces unique nonce", %{identity: identity, agent_id: agent_id} do
      signer = Arbor.Security.make_signer(agent_id, identity.private_key)

      {:ok, signed1} = signer.("test")
      {:ok, signed2} = signer.("test")

      refute signed1.nonce == signed2.nonce
    end
  end
end
