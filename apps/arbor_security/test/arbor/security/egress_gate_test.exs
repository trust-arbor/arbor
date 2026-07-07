defmodule Arbor.Security.EgressGateTest do
  @moduledoc """
  Security regression tests for the egress gate (2026-06-14
  URI-addressing-vs-classification decision).

  The gate keys off the *resolved classification* threaded in via opts
  (`:egress_tier`, `:egress_taint`), NOT off parsing the URI. It asserts, via
  the public `AuthDecision.check/4` API (the real authorization path that
  `Arbor.Security.authorize/4` → `authorize_and_execute/4` reach):

  - **Dark by default**: with enforcement off, external egress is NOT gated, so
    flipping the gate on can never silently break the running agents (whose
    heartbeats make routine LLM egress).
  - **Enforcing**: external-provider egress escalates to `:requires_approval`;
    untrusted/hostile data flowing OUT to an external destination is hard-blocked;
    on-host (local LLM) egress is never gated; on-premises is gated only under
    the operator opt-in flag; external-peer is advisory-only (ACP deferral).

  These fail on a build without the egress gate (external egress would authorize
  unconditionally) and pass with it.
  """
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Security.Capability
  alias Arbor.Security.{AuthDecision, CapabilityStore}

  @resource "arbor://ai/generate"

  # Trust-policy stub for egress. Missing egress_mode/2 exercises the
  # fail-closed :ask fallback for external tiers.
  defmodule UngatedTrustPolicy do
  end

  # A profile that grants standing to egress to external providers (a trusted
  # agent), but still asks for peers.
  defmodule ProviderAllowedPolicy do
    def egress_mode(_principal, :external_provider), do: :allow
    def egress_mode(_principal, :on_premises), do: :allow
    def egress_mode(_principal, _tier), do: :ask
  end

  # A profile that hard-blocks external-provider egress.
  defmodule ProviderBlockedPolicy do
    def egress_mode(_principal, :external_provider), do: :block
    def egress_mode(_principal, _tier), do: :allow
  end

  setup do
    prev_policy = Application.get_env(:arbor_security, :trust_policy_module)
    prev_enforce = Application.get_env(:arbor_security, :egress_gate_enforcing)
    prev_onprem = Application.get_env(:arbor_security, :gate_on_premises_egress)

    Application.put_env(:arbor_security, :trust_policy_module, UngatedTrustPolicy)

    on_exit(fn ->
      restore(:trust_policy_module, prev_policy)
      restore(:egress_gate_enforcing, prev_enforce)
      restore(:gate_on_premises_egress, prev_onprem)
    end)

    agent_id = "agent_egress_#{System.unique_integer([:positive])}"

    {:ok, cap} =
      Capability.new(
        resource_uri: @resource,
        principal_id: agent_id,
        delegation_depth: 0,
        constraints: %{},
        metadata: %{test: true}
      )

    CapabilityStore.put(cap)

    %{agent_id: agent_id}
  end

  defp restore(key, nil), do: Application.delete_env(:arbor_security, key)
  defp restore(key, val), do: Application.put_env(:arbor_security, key, val)

  defp enforce!, do: Application.put_env(:arbor_security, :egress_gate_enforcing, true)

  describe "dark by default (enforcement off)" do
    test "external-provider egress is NOT gated — baseline authorized", %{agent_id: agent} do
      # enforcing flag unset → default false
      assert AuthDecision.check(agent, @resource, :execute, egress_tier: :external_provider) ==
               :authorized
    end

    test "untrusted data to external egress is NOT blocked while dark", %{agent_id: agent} do
      assert AuthDecision.check(agent, @resource, :execute,
               egress_tier: :external_provider,
               egress_taint: :untrusted
             ) == :authorized
    end
  end

  describe "enforcing: provider egress escalates to approval" do
    test "external_provider → requires_approval", %{agent_id: agent} do
      enforce!()

      assert {:requires_approval, _cap} =
               AuthDecision.check(agent, @resource, :execute, egress_tier: :external_provider)
    end

    test "on_host (local LLM) is NOT gated", %{agent_id: agent} do
      enforce!()
      assert AuthDecision.check(agent, @resource, :execute, egress_tier: :on_host) == :authorized
    end

    test "no egress tier supplied → not gated", %{agent_id: agent} do
      enforce!()
      assert AuthDecision.check(agent, @resource, :execute) == :authorized
    end
  end

  describe "enforcing: taint conjunct hard-blocks exfiltration" do
    test "untrusted data → external egress is blocked", %{agent_id: agent} do
      enforce!()

      assert {:error, {:egress_blocked, :external_provider, :untrusted}} =
               AuthDecision.check(agent, @resource, :execute,
                 egress_tier: :external_provider,
                 egress_taint: :untrusted
               )
    end

    test "hostile data → external egress is blocked", %{agent_id: agent} do
      enforce!()

      assert {:error, {:egress_blocked, :external_peer, :hostile}} =
               AuthDecision.check(agent, @resource, :execute,
                 egress_tier: :external_peer,
                 egress_taint: :hostile
               )
    end

    test "trusted data → external egress is NOT blocked (still asks for provider)",
         %{agent_id: agent} do
      enforce!()

      assert {:requires_approval, _} =
               AuthDecision.check(agent, @resource, :execute,
                 egress_tier: :external_provider,
                 egress_taint: :trusted
               )
    end

    test "untrusted data → on_host egress is NOT blocked (stays local)", %{agent_id: agent} do
      enforce!()

      assert AuthDecision.check(agent, @resource, :execute,
               egress_tier: :on_host,
               egress_taint: :untrusted
             ) == :authorized
    end
  end

  describe "enforcing: on-premises is operator-configurable" do
    test "on_premises is NOT gated by default (homelab/data-sovereignty)", %{agent_id: agent} do
      enforce!()

      assert AuthDecision.check(agent, @resource, :execute, egress_tier: :on_premises) ==
               :authorized
    end

    test "on_premises IS gated when operator opts in", %{agent_id: agent} do
      enforce!()
      Application.put_env(:arbor_security, :gate_on_premises_egress, true)

      assert {:requires_approval, _} =
               AuthDecision.check(agent, @resource, :execute, egress_tier: :on_premises)
    end
  end

  describe "enforcing: external_peer is advisory-only in 1.0 (ACP deferral)" do
    test "external_peer egress is NOT escalated to approval", %{agent_id: agent} do
      enforce!()

      assert AuthDecision.check(agent, @resource, :execute, egress_tier: :external_peer) ==
               :authorized
    end
  end

  describe "enforcing: trust-ceiling by egress tier (layer 1)" do
    test "a profile granting external_provider :allow egresses freely (the heartbeat case)",
         %{agent_id: agent} do
      enforce!()
      Application.put_env(:arbor_security, :trust_policy_module, ProviderAllowedPolicy)

      assert AuthDecision.check(agent, @resource, :execute, egress_tier: :external_provider) ==
               :authorized
    end

    test "a profile hard-blocking external_provider denies", %{agent_id: agent} do
      enforce!()
      Application.put_env(:arbor_security, :trust_policy_module, ProviderBlockedPolicy)

      assert {:error, {:egress_blocked, :external_provider, :policy}} =
               AuthDecision.check(agent, @resource, :execute, egress_tier: :external_provider)
    end

    test "default profile (no egress standing) still asks", %{agent_id: agent} do
      enforce!()
      # setup's UngatedTrustPolicy has no egress_mode/2 -> fail-closed :ask
      assert {:requires_approval, _} =
               AuthDecision.check(agent, @resource, :execute, egress_tier: :external_provider)
    end
  end

  describe "authorize_egress/3 — standalone compute-node path (no operation cap)" do
    test "dark by default → :allow", %{agent_id: agent} do
      assert Arbor.Security.authorize_egress(agent, :external_provider) == :allow
    end

    test "enforcing + no egress standing → requires_approval", %{agent_id: agent} do
      enforce!()

      assert Arbor.Security.authorize_egress(agent, :external_provider) ==
               {:requires_approval, :egress}
    end

    test "enforcing + profile grants standing → :allow (the heartbeat case)", %{agent_id: agent} do
      enforce!()
      Application.put_env(:arbor_security, :trust_policy_module, ProviderAllowedPolicy)
      assert Arbor.Security.authorize_egress(agent, :external_provider) == :allow
    end

    test "enforcing + on_host (local LLM) → :allow", %{agent_id: agent} do
      enforce!()
      assert Arbor.Security.authorize_egress(agent, :on_host) == :allow
    end

    test "enforcing + untrusted data → external → blocked", %{agent_id: agent} do
      enforce!()

      assert {:error, {:egress_blocked, :external_provider, :untrusted}} =
               Arbor.Security.authorize_egress(agent, :external_provider,
                 egress_taint: :untrusted
               )
    end

    test "enforcing + agent holds a covering egress cap → :allow", %{agent_id: agent} do
      enforce!()

      {:ok, cap} =
        Capability.new(
          resource_uri: @resource,
          principal_id: agent,
          delegation_depth: 0,
          constraints: %{egress: %{max_tier: :external_provider}},
          metadata: %{test: true}
        )

      CapabilityStore.put(cap)

      assert Arbor.Security.authorize_egress(agent, :external_provider) == :allow
    end
  end

  describe "enforcing: capability refinement (layer 2)" do
    setup do
      # A fresh agent whose ONLY cap carries an egress constraint, so it is the
      # cap AuthDecision matches for the resource.
      agent_id = "agent_egresscap_#{System.unique_integer([:positive])}"
      %{agent_id: agent_id}
    end

    defp grant_egress_cap(agent_id, egress_constraint) do
      {:ok, cap} =
        Capability.new(
          resource_uri: @resource,
          principal_id: agent_id,
          delegation_depth: 0,
          constraints: %{egress: egress_constraint},
          metadata: %{test: true}
        )

      CapabilityStore.put(cap)
    end

    test "a cap with max_tier covering the request bypasses :ask", %{agent_id: agent} do
      enforce!()
      grant_egress_cap(agent, %{max_tier: :external_provider})

      assert AuthDecision.check(agent, @resource, :execute, egress_tier: :external_provider) ==
               :authorized
    end

    test "a cap whose max_tier is below the request does NOT cover it (still asks)",
         %{agent_id: agent} do
      enforce!()
      grant_egress_cap(agent, %{max_tier: :on_premises})

      assert {:requires_approval, _} =
               AuthDecision.check(agent, @resource, :execute, egress_tier: :external_provider)
    end

    test "a destination-scoped cap covers a matching destination", %{agent_id: agent} do
      enforce!()

      grant_egress_cap(agent, %{max_tier: :external_provider, destinations: ["api.anthropic.com"]})

      assert AuthDecision.check(agent, @resource, :execute,
               egress_tier: :external_provider,
               egress_destination: "api.anthropic.com"
             ) == :authorized
    end

    test "a destination-scoped cap does NOT cover a different destination", %{agent_id: agent} do
      enforce!()

      grant_egress_cap(agent, %{max_tier: :external_provider, destinations: ["api.anthropic.com"]})

      assert {:requires_approval, _} =
               AuthDecision.check(agent, @resource, :execute,
                 egress_tier: :external_provider,
                 egress_destination: "evil.example.com"
               )
    end

    test "the taint hard-block is NOT bypassable by a covering cap", %{agent_id: agent} do
      enforce!()
      grant_egress_cap(agent, %{max_tier: :external_provider})

      assert {:error, {:egress_blocked, :external_provider, :untrusted}} =
               AuthDecision.check(agent, @resource, :execute,
                 egress_tier: :external_provider,
                 egress_taint: :untrusted
               )
    end
  end
end
