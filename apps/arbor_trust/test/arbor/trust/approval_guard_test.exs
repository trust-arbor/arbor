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

  # Gated policy that can also explain itself, like the real Arbor.Trust.Policy.
  defmodule ExplainingGatedPolicy do
    def confirmation_mode(_principal, _uri), do: :gated

    def explain(_principal, uri, _opts) do
      %{
        resource_uri: uri,
        user_mode: :ask,
        user_match: {"arbor://fs/write", :ask},
        baseline: :ask,
        security_ceiling: :ask,
        ceiling_match: {"arbor://fs/write", :ask},
        effective_mode: :ask
      }
    end
  end

  # Minimal InteractionRouter so the escalation lands somewhere inspectable.
  defmodule CapturingRouter do
    @behaviour Arbor.Security.Contracts.InteractionRouter

    @impl true
    def request(attrs, _opts \\ []) do
      request_id = "irq_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      send(self(), {:escalated, request_id, attrs})
      {:ok, request_id}
    end
  end

  defmodule MockConsensus do
    def submit(%{} = _proposal, _opts \\ []), do: {:ok, "proposal_test"}
    def healthy?, do: true
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

    test "security regression: exact approved invocation bypasses an auto-policy capability constraint once" do
      Application.put_env(:arbor_trust, :approval_guard_enabled, true)
      Application.put_env(:arbor_trust, :policy_module, AutoPolicy)

      resource = "arbor://code/read/file.ex"
      cap = make_capability(resource, %{requires_approval: true})

      approval = %{
        request_id: "irq_approved_once",
        principal_id: "agent_test",
        resource_uri: resource,
        decision: :approved
      }

      assert :ok =
               ApprovalGuard.check(cap, "agent_test", resource, approved_invocation: approval)

      assert {:error, :escalation_disabled} =
               ApprovalGuard.check(cap, "agent_test", resource)
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

    test "approved invocation bypasses gated policy only for exact request principal and resource" do
      Application.put_env(:arbor_trust, :approval_guard_enabled, true)
      Application.put_env(:arbor_trust, :policy_module, GatedPolicy)

      cap = make_capability("arbor://shell/exec/grep")

      approval = %{
        request_id: "irq_approved",
        principal_id: "agent_test",
        resource_uri: "arbor://shell/exec/grep",
        decision: :approved
      }

      assert :ok =
               ApprovalGuard.check(cap, "agent_test", "arbor://shell/exec/grep",
                 approved_invocation: approval
               )

      wrong_resource = %{approval | resource_uri: "arbor://shell/exec/git"}

      assert {:error, :escalation_disabled} =
               ApprovalGuard.check(cap, "agent_test", "arbor://shell/exec/grep",
                 approved_invocation: wrong_resource
               )

      wrong_principal = %{approval | principal_id: "agent_other"}

      assert {:error, :escalation_disabled} =
               ApprovalGuard.check(cap, "agent_test", "arbor://shell/exec/grep",
                 approved_invocation: wrong_principal
               )
    end

    test "gated escalation carries the trust explanation and capability risk profile" do
      Application.put_env(:arbor_trust, :approval_guard_enabled, true)
      Application.put_env(:arbor_trust, :policy_module, ExplainingGatedPolicy)
      enable_capturing_router()

      assert {:ok, :pending_approval, request_id} =
               ApprovalGuard.check(
                 make_capability("arbor://fs/write/report.md"),
                 "agent_test",
                 "arbor://fs/write/report.md",
                 file_path: "/workspace/report.md"
               )

      assert_received {:escalated, ^request_id, attrs}
      metadata = attrs.metadata

      assert metadata.gate == :trust_policy
      assert metadata.reason == :policy_gated
      assert metadata.trust.effective_mode == :ask
      assert metadata.trust.matched_rule == %{prefix: "arbor://fs/write", mode: :ask}
      assert metadata.trust.profile.reversibility == :reversible
      assert metadata.trust.profile.blast_radius == :high
      assert metadata.trust.profile.uri_prefix == "arbor://fs/write"
    end

    test "capability-constraint escalation also carries the trust context" do
      Application.put_env(:arbor_trust, :approval_guard_enabled, true)
      Application.put_env(:arbor_trust, :policy_module, AutoPolicy)
      enable_capturing_router()

      cap = make_capability("arbor://shell/exec/rm", %{requires_approval: true})

      assert {:ok, :pending_approval, request_id} =
               ApprovalGuard.check(cap, "agent_test", "arbor://shell/exec/rm")

      assert_received {:escalated, ^request_id, attrs}
      assert attrs.metadata.gate == :capability_constraint
      assert attrs.metadata.trust.profile.reversibility == :irreversible
      assert attrs.metadata.trust.profile.graduation_threshold == :never
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

  # Route escalations to CapturingRouter for the duration of one test.
  defp enable_capturing_router do
    keys = [:consensus_module, :use_interaction_router_for_approval, :interaction_router]
    previous = Map.new(keys, &{&1, Application.get_env(:arbor_security, &1)})

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> restore(:arbor_security, key, value) end)
    end)

    Application.put_env(:arbor_security, :consensus_escalation_enabled, true)
    Application.put_env(:arbor_security, :consensus_module, MockConsensus)
    Application.put_env(:arbor_security, :use_interaction_router_for_approval, true)
    Application.put_env(:arbor_security, :interaction_router, CapturingRouter)
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
