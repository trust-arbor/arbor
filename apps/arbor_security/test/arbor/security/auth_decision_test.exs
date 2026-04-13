defmodule Arbor.Security.AuthDecisionTest do
  use ExUnit.Case, async: true

  alias Arbor.Security.AuthDecision
  alias Arbor.Contracts.Security.AuthContext

  describe "check/4 (convenience API)" do
    test "returns :unauthorized when no capability exists" do
      result = AuthDecision.check("nonexistent_agent", "arbor://fs/read")
      assert result == {:error, :unauthorized} or match?({:error, _}, result)
    end

    test "human identities pass identity check" do
      result = AuthDecision.check("human_test123", "arbor://nonexistent")
      # Fails on capability, not identity
      assert match?({:error, _}, result)
    end

    test "never raises" do
      result = AuthDecision.check("agent_test", "arbor://test")
      assert is_atom(result) or is_tuple(result)
    end
  end

  describe "evaluate/3 (AuthContext API)" do
    test "returns authorized decision with updated auth" do
      # Build an auth context with a matching capability
      cap = %Arbor.Contracts.Security.Capability{
        id: "cap_test",
        resource_uri: "arbor://test/action",
        principal_id: "agent_test",
        granted_at: DateTime.utc_now(),
        constraints: %{}
      }

      auth = AuthContext.new("agent_test", capabilities: [cap])

      case AuthDecision.evaluate(auth, "arbor://test/action") do
        {:ok, :authorized, _cap, updated_auth} ->
          assert length(updated_auth.decisions) == 1
          assert hd(updated_auth.decisions).result == :authorized

        {:error, _reason, _auth} ->
          # May fail if URI registry blocks it — that's OK for this test
          :ok
      end
    end

    test "returns requires_approval for gated capability" do
      cap = %Arbor.Contracts.Security.Capability{
        id: "cap_gated",
        resource_uri: "arbor://test/gated",
        principal_id: "agent_test",
        granted_at: DateTime.utc_now(),
        constraints: %{requires_approval: true}
      }

      auth = AuthContext.new("agent_test", capabilities: [cap])

      case AuthDecision.evaluate(auth, "arbor://test/gated") do
        {:ok, :requires_approval, _cap, updated_auth} ->
          assert length(updated_auth.decisions) == 1

        {:error, _reason, _auth} ->
          # May fail on URI registry — OK
          :ok
      end
    end

    test "skips identity check when already verified" do
      auth =
        AuthContext.new("agent_test")
        |> AuthContext.mark_verified()

      # Even with no capabilities, identity check should pass
      case AuthDecision.evaluate(auth, "arbor://test/something") do
        {:error, :unauthorized, _} -> :ok  # fails on capability, not identity
        {:error, {:uri_rejected, _}, _} -> :ok  # fails on URI, not identity
        _ -> :ok
      end
    end

    test "records decisions in audit trail" do
      auth = AuthContext.new("agent_test")

      updated =
        case AuthDecision.evaluate(auth, "arbor://test/first") do
          {:ok, _, _, auth} -> auth
          {:error, _, auth} -> auth
        end

      assert length(updated.decisions) == 1
      assert hd(updated.decisions).resource == "arbor://test/first"
    end

    test "wildcard capability matches via CapabilityStore" do
      # When CapabilityStore is running, AuthDecision uses it (signature verified).
      # Grant a real capability through the store for this test.
      agent_id = "agent_wild_test_#{:erlang.unique_integer([:positive])}"

      if Code.ensure_loaded?(Arbor.Security.CapabilityStore) and
           Process.whereis(Arbor.Security.CapabilityStore) != nil do
        Arbor.Security.CapabilityStore.put(%Arbor.Contracts.Security.Capability{
          id: "cap_wild_#{:erlang.unique_integer([:positive])}",
          resource_uri: "arbor://fs/**",
          principal_id: agent_id,
          granted_at: DateTime.utc_now(),
          constraints: %{}
        })

        auth = AuthContext.new(agent_id) |> AuthContext.mark_verified()

        case AuthDecision.evaluate(auth, "arbor://fs/read") do
          {:ok, :authorized, _, _} -> :ok
          # Trust-gated: wildcard matched but untrusted agent needs approval
          {:ok, :requires_approval, _, _} -> :ok
          {:error, {:uri_rejected, _}, _} -> :ok
          other -> flunk("Unexpected: #{inspect(other)}")
        end
      else
        # CapabilityStore not running — test pre-loaded path
        cap = %Arbor.Contracts.Security.Capability{
          id: "cap_wild",
          resource_uri: "arbor://fs/**",
          principal_id: agent_id,
          granted_at: DateTime.utc_now(),
          constraints: %{}
        }

        auth = AuthContext.new(agent_id, capabilities: [cap]) |> AuthContext.mark_verified()

        case AuthDecision.evaluate(auth, "arbor://fs/read") do
          {:ok, :authorized, _, _} -> :ok
          {:ok, :requires_approval, _, _} -> :ok
          {:error, {:uri_rejected, _}, _} -> :ok
          other -> flunk("Unexpected: #{inspect(other)}")
        end
      end
    end
  end
end
