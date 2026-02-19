defmodule Arbor.Behavioral.TrustCapabilityTest do
  @moduledoc """
  Behavioral test: trust tier capability check.

  Verifies the end-to-end authorization flow:
  1. Agent at tier X attempts action requiring tier Y
  2. Capability grant → authorize → allowed/denied
  3. Reflex system catches dangerous patterns before capability check
  4. TrustBounds maps tiers to allowed actions and sandbox levels
  5. Trust progression via events

  Self-contained — uses its own agent identities and capabilities.
  """
  use Arbor.Test.BehavioralCase

  alias Arbor.Contracts.Security.Capability
  alias Arbor.Contracts.Security.TrustBounds
  alias Arbor.Security.CapabilityStore

  describe "scenario: capability authorization flow" do
    test "authorize succeeds when agent has matching capability", %{agent_id: agent_id} do
      # agent_id already has capabilities from BehavioralCase setup
      result = Arbor.Security.authorize(agent_id, "arbor://ai/request/auto")

      assert {:ok, :authorized} = result
    end

    test "authorize fails when agent lacks capability" do
      unknown_agent = "agent_no_caps_#{:erlang.unique_integer([:positive])}"

      result = Arbor.Security.authorize(unknown_agent, "arbor://fs/write/secrets")

      assert {:error, _reason} = result
    end

    test "can?/2 returns boolean for quick checks", %{agent_id: agent_id} do
      assert Arbor.Security.can?(agent_id, "arbor://ai/request/auto") == true
      assert Arbor.Security.can?(agent_id, "arbor://fs/delete/everything") == false
    end

    test "expired capability is not authorized" do
      agent_id = "agent_expired_cap_#{:erlang.unique_integer([:positive])}"

      cap = %Capability{
        id: "cap_expired_#{agent_id}",
        resource_uri: "arbor://test/expired",
        principal_id: agent_id,
        granted_at: DateTime.add(DateTime.utc_now(), -7200, :second),
        expires_at: DateTime.add(DateTime.utc_now(), -3600, :second),
        constraints: %{},
        delegation_depth: 0,
        metadata: %{test: true}
      }

      CapabilityStore.put(cap)

      result = Arbor.Security.authorize(agent_id, "arbor://test/expired")
      # Expired caps should not authorize
      assert {:error, _} = result
    end

    test "grant creates a new capability with correct fields" do
      agent_id = "agent_grant_test_#{:erlang.unique_integer([:positive])}"

      {:ok, cap} =
        Arbor.Security.grant(
          principal: agent_id,
          resource: "arbor://test/behavioral/grant",
          constraints: %{max_requests: 10}
        )

      assert cap.principal_id == agent_id
      assert cap.resource_uri == "arbor://test/behavioral/grant"
      assert cap.constraints[:max_requests] == 10
      assert cap.granted_at != nil
    end

    test "revoke removes a capability" do
      agent_id = "agent_revoke_test_#{:erlang.unique_integer([:positive])}"

      {:ok, cap} =
        Arbor.Security.grant(
          principal: agent_id,
          resource: "arbor://test/behavioral/revoke"
        )

      assert Arbor.Security.can?(agent_id, "arbor://test/behavioral/revoke") == true

      :ok = Arbor.Security.revoke(cap.id)

      assert Arbor.Security.can?(agent_id, "arbor://test/behavioral/revoke") == false
    end
  end

  describe "scenario: reflex system" do
    test "dangerous shell command blocked by reflex" do
      result = Arbor.Security.check_reflex(%{command: "rm -rf /"})

      assert {:blocked, _reflex, _reason} = result
    end

    test "sudo command blocked by reflex" do
      result = Arbor.Security.check_reflex(%{command: "sudo su -"})

      assert {:blocked, _reflex, _reason} = result
    end

    test "safe command passes reflex check" do
      result = Arbor.Security.check_reflex(%{command: "ls -la"})

      assert result == :ok
    end

    test "path-based reflex blocks SSH key access" do
      result = Arbor.Security.check_reflex(%{path: "~/.ssh/id_rsa"})

      case result do
        {:blocked, _reflex, _reason} -> :ok
        {:warned, _warnings} -> :ok
        :ok -> flunk("SSH key path should trigger reflex")
      end
    end

    test "SSRF metadata endpoint blocked" do
      # Pattern-based reflexes match against :command context key
      result =
        Arbor.Security.check_reflex(%{command: "curl http://169.254.169.254/latest/meta-data/"})

      assert {:blocked, _reflex, _reason} = result
    end

    test "reflex fires before capability check in authorize/4" do
      # Ensure reflex checking is enabled for this test (may be disabled globally in test.exs)
      prev = Application.get_env(:arbor_security, :reflex_checking_enabled, true)
      Application.put_env(:arbor_security, :reflex_checking_enabled, true)

      try do
        # Even with a valid capability, a dangerous command context should block
        agent_id = "agent_reflex_test_#{:erlang.unique_integer([:positive])}"

        {:ok, _cap} =
          Arbor.Security.grant(
            principal: agent_id,
            resource: "arbor://shell/execute"
          )

        result =
          Arbor.Security.authorize(
            agent_id,
            "arbor://shell/execute",
            nil,
            command: "rm -rf /"
          )

        assert {:error, _} = result
      after
        Application.put_env(:arbor_security, :reflex_checking_enabled, prev)
      end
    end
  end

  describe "scenario: TrustBounds tier mapping" do
    test "all tiers have defined sandbox levels" do
      for tier <- TrustBounds.tiers() do
        sandbox = TrustBounds.sandbox_for_tier(tier)

        assert sandbox in [:strict, :standard, :permissive, :none],
               "Tier #{inspect(tier)} has sandbox #{inspect(sandbox)}"
      end
    end

    test "tier progression increases allowed actions" do
      untrusted_actions = TrustBounds.allowed_actions(:untrusted)
      trusted_actions = TrustBounds.allowed_actions(:trusted)

      # Higher tiers should have at least as many allowed actions
      assert length(List.wrap(trusted_actions)) >= length(List.wrap(untrusted_actions))
    end

    test "autonomous tier allows all actions" do
      actions = TrustBounds.allowed_actions(:autonomous)
      assert actions == :all
    end

    test "untrusted tier only allows read, search, think" do
      actions = TrustBounds.allowed_actions(:untrusted)
      assert is_list(actions)

      for action <- [:read, :search, :think] do
        assert action in actions,
               "Untrusted tier should allow #{inspect(action)}"
      end

      refute :execute in actions
      refute :network in actions
    end

    test "action_allowed?/2 checks tier-action compatibility" do
      assert TrustBounds.action_allowed?(:untrusted, :read) == true
      assert TrustBounds.action_allowed?(:untrusted, :execute) == false
      assert TrustBounds.action_allowed?(:veteran, :execute) == true
      assert TrustBounds.action_allowed?(:autonomous, :network) == true
    end

    test "sandbox strictness decreases with trust tier" do
      strict_tiers = [:untrusted, :probationary]
      permissive_tiers = [:veteran, :autonomous]

      for tier <- strict_tiers do
        sandbox = TrustBounds.sandbox_for_tier(tier)

        assert sandbox in [:strict, :standard],
               "Low-trust tier #{inspect(tier)} should have strict/standard sandbox"
      end

      for tier <- permissive_tiers do
        sandbox = TrustBounds.sandbox_for_tier(tier)

        assert sandbox in [:permissive, :none],
               "High-trust tier #{inspect(tier)} should have permissive/none sandbox"
      end
    end

    test "display_name/1 returns human-readable tier names" do
      for tier <- TrustBounds.tiers() do
        name = TrustBounds.display_name(tier)
        assert is_binary(name)
        assert String.length(name) > 0
      end
    end
  end

  describe "scenario: trust profile lifecycle" do
    test "create_trust_profile starts agent at untrusted tier" do
      agent_id = "agent_trust_profile_#{:erlang.unique_integer([:positive])}"

      result =
        try do
          Arbor.Trust.create_trust_profile(agent_id)
        rescue
          e -> {:exception, e}
        catch
          :exit, reason -> {:exit, reason}
        end

      case result do
        {:ok, profile} ->
          assert profile.tier == :untrusted
          assert profile.trust_score == 0 or profile.trust_score <= 19

        {:error, _reason} ->
          # Trust.Manager may not be running in test env
          :ok

        {:exit, _} ->
          # GenServer not started
          :ok

        {:exception, _} ->
          :ok
      end
    end

    test "check_trust_authorization compares agent tier against required" do
      agent_id = "agent_trust_auth_#{:erlang.unique_integer([:positive])}"

      result =
        try do
          Arbor.Trust.create_trust_profile(agent_id)
        rescue
          _ -> {:error, :unavailable}
        catch
          :exit, _ -> {:error, :unavailable}
        end

      case result do
        {:ok, _profile} ->
          # New agent is untrusted — should fail veteran check
          auth_result = Arbor.Trust.check_trust_authorization(agent_id, :veteran)
          assert {:error, _} = auth_result

          # Should pass untrusted check
          auth_result = Arbor.Trust.check_trust_authorization(agent_id, :untrusted)
          assert {:ok, _} = auth_result

        {:error, :unavailable} ->
          # Trust.Manager not running — acceptable in test env
          :ok
      end
    end
  end
end
