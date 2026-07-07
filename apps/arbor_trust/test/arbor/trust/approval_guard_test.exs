defmodule Arbor.Trust.ApprovalGuardTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Trust.ApprovalGuard

  defmodule AutoPolicy do
    def confirmation_mode(_principal, _uri), do: :auto
  end

  defmodule GatedPolicy do
    def confirmation_mode(_principal, _uri), do: :gated
  end

  defmodule DenyPolicy do
    def confirmation_mode(_principal, _uri), do: :deny
  end

  defmodule RaisingPolicy do
    def confirmation_mode(_principal, _uri), do: raise("trust subsystem down")
  end

  defmodule ExitingPolicy do
    def confirmation_mode(_principal, _uri), do: exit(:trust_down)
  end

  setup do
    prev_trust_guard = Application.get_env(:arbor_trust, :approval_guard_enabled)
    prev_security_guard = Application.get_env(:arbor_security, :approval_guard_enabled)
    prev_policy = Application.get_env(:arbor_trust, :policy_module)
    prev_escalation = Application.get_env(:arbor_security, :consensus_escalation_enabled)

    on_exit(fn ->
      restore(:arbor_trust, :approval_guard_enabled, prev_trust_guard)
      restore(:arbor_security, :approval_guard_enabled, prev_security_guard)
      restore(:arbor_trust, :policy_module, prev_policy)
      restore(:arbor_security, :consensus_escalation_enabled, prev_escalation)
    end)

    Application.put_env(:arbor_security, :consensus_escalation_enabled, false)

    :ok
  end

  describe "enabled?/0" do
    test "uses compatibility fallback from security config" do
      Application.delete_env(:arbor_trust, :approval_guard_enabled)
      Application.put_env(:arbor_security, :approval_guard_enabled, false)
      refute ApprovalGuard.enabled?()

      Application.put_env(:arbor_security, :approval_guard_enabled, true)
      assert ApprovalGuard.enabled?()
    end

    test "trust config overrides compatibility fallback" do
      Application.put_env(:arbor_security, :approval_guard_enabled, true)
      Application.put_env(:arbor_trust, :approval_guard_enabled, false)

      refute ApprovalGuard.enabled?()
    end
  end

  describe "check/3" do
    test "falls through to cap constraints when disabled" do
      Application.put_env(:arbor_trust, :approval_guard_enabled, false)
      Application.put_env(:arbor_trust, :policy_module, DenyPolicy)

      assert :ok =
               ApprovalGuard.check(
                 make_capability("arbor://code/read/file.ex"),
                 "agent_test",
                 "arbor://code/read/file.ex"
               )
    end

    test "auto policy approves a normal capability" do
      Application.put_env(:arbor_trust, :approval_guard_enabled, true)
      Application.put_env(:arbor_trust, :policy_module, AutoPolicy)

      assert :ok =
               ApprovalGuard.check(
                 make_capability("arbor://code/read/file.ex"),
                 "agent_test",
                 "arbor://code/read/file.ex"
               )
    end

    test "security regression: auto policy does not bypass per-cap requires_approval" do
      Application.put_env(:arbor_trust, :approval_guard_enabled, true)
      Application.put_env(:arbor_trust, :policy_module, AutoPolicy)

      cap = make_capability("arbor://code/read/file.ex", %{requires_approval: true})

      assert {:error, :escalation_disabled} =
               ApprovalGuard.check(cap, "agent_test", "arbor://code/read/file.ex")
    end

    test "gated policy escalates" do
      Application.put_env(:arbor_trust, :approval_guard_enabled, true)
      Application.put_env(:arbor_trust, :policy_module, GatedPolicy)

      assert {:error, :escalation_disabled} =
               ApprovalGuard.check(
                 make_capability("arbor://code/write/file.ex"),
                 "agent_test",
                 "arbor://code/write/file.ex"
               )
    end

    test "deny policy blocks" do
      Application.put_env(:arbor_trust, :approval_guard_enabled, true)
      Application.put_env(:arbor_trust, :policy_module, DenyPolicy)

      assert {:error, :policy_denied} =
               ApprovalGuard.check(
                 make_capability("arbor://code/write/file.ex"),
                 "agent_test",
                 "arbor://code/write/file.ex"
               )
    end

    test "security regression: a raising trust policy fails closed, never auto-approves" do
      Application.put_env(:arbor_trust, :approval_guard_enabled, true)
      Application.put_env(:arbor_trust, :policy_module, RaisingPolicy)

      refute ApprovalGuard.check(
               make_capability("arbor://code/write/file.ex"),
               "agent_test",
               "arbor://code/write/file.ex"
             ) == :ok
    end

    test "security regression: an exiting trust policy fails closed, never auto-approves" do
      Application.put_env(:arbor_trust, :approval_guard_enabled, true)
      Application.put_env(:arbor_trust, :policy_module, ExitingPolicy)

      refute ApprovalGuard.check(
               make_capability("arbor://code/write/file.ex"),
               "agent_test",
               "arbor://code/write/file.ex"
             ) == :ok
    end
  end

  defp make_capability(resource_uri, constraints \\ %{}) do
    %{
      id: "cap_test_#{System.unique_integer([:positive])}",
      resource_uri: resource_uri,
      principal_id: "agent_test",
      constraints: constraints,
      metadata: %{}
    }
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
