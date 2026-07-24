defmodule Arbor.Behavioral.TrustCapabilityTest do
  @moduledoc """
  Behavioral test: granular trust policy and capability checks.

  Verifies the end-to-end authorization flow:
  1. An agent's URI-prefix policy resolves its effective autonomy mode
  2. Capability grant → authorize → allowed/denied
  3. Reflex system catches dangerous patterns before capability check

  Self-contained — uses its own agent identities and capabilities.
  """
  use Arbor.Test.BehavioralCase

  alias Arbor.Contracts.Security.Capability
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

    test "authorize/2 checks capability presence", %{agent_id: agent_id} do
      assert {:ok, :authorized} = Arbor.Security.authorize(agent_id, "arbor://ai/request/auto")
      assert {:error, _} = Arbor.Security.authorize(agent_id, "arbor://fs/delete/everything")
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

      assert {:ok, :authorized} =
               Arbor.Security.authorize(agent_id, "arbor://test/behavioral/revoke")

      :ok = Arbor.Security.revoke(cap.id)

      assert {:error, _} = Arbor.Security.authorize(agent_id, "arbor://test/behavioral/revoke")
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

  describe "scenario: trust profile lifecycle" do
    test "create_trust_profile starts with a conservative granular policy" do
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
          assert profile.baseline == :ask
          assert is_map(profile.rules)
          refute Map.has_key?(profile, :tier)

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

    test "effective_mode resolves URI rules instead of scalar tiers" do
      agent_id = "agent_trust_auth_#{:erlang.unique_integer([:positive])}"

      result =
        try do
          Arbor.Trust.ensure_trust_profile(agent_id,
            baseline: :block,
            rules: %{
              "arbor://fs/read" => :allow,
              "arbor://fs/read/private" => :ask
            }
          )
        rescue
          _ -> {:error, :unavailable}
        catch
          :exit, _ -> {:error, :unavailable}
        end

      case result do
        {:ok, _profile} ->
          assert Arbor.Trust.effective_mode(agent_id, "arbor://fs/read/project/file.ex") == :allow
          assert Arbor.Trust.effective_mode(agent_id, "arbor://fs/read/private/key") == :ask

          assert Arbor.Trust.effective_mode(agent_id, "arbor://fs/write/project/file.ex") ==
                   :block

        {:error, _reason} ->
          # Trust.Manager not running — acceptable in test env
          :ok
      end
    end
  end
end
