defmodule Arbor.Security.ShellExecTrustGateRegressionTest do
  @moduledoc """
  Security regression test for the 2026-04-07 shell auto-execution regression (K2,
  capability-kernel-review). Committed per CLAUDE.md's security-regression rule —
  the original fix was verified live via tidewave but never committed as a test, so
  the next auth-pipeline refactor could silently re-open the hole.

  The bug: `AuthDecision.check_approval` consulted ONLY the capability's own
  `requires_approval` constraint, never the trust profile. A signed
  `arbor://shell/exec` capability that didn't carry the flag was AUTHORIZED, so
  shell ran without approval for an unknown number of weeks. The fix
  (`auth_decision.ex`, `trust_demands_approval = trust_profile_gates?(...)`) makes
  the decision consult trust as well.

  Isolated at `AuthDecision.evaluate/3` (the pure decision) rather than the Shell
  facade on purpose: the facade's requires-approval path runs through
  `ApprovalGuard`, whose own fail-open (K1, a SEPARATE finding) could mask this one.
  At the decision layer, with trust gating shell/exec and NO per-cap flag, the
  result MUST be `:requires_approval` — never `:authorized`.

  Fails on the pre-fix code (check_approval ignoring trust → `:authorized`).
  """
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Security.AuthContext
  alias Arbor.Contracts.Security.Capability
  alias Arbor.Security.AuthDecision
  alias Arbor.Security.CapabilityStore

  # Stub trust profile: shell/exec is gated (mirrors the real `:ask` ceiling);
  # everything else auto, so the test can't accidentally gate on an unrelated URI.
  defmodule GatedShellPolicy do
    def confirmation_mode(_principal, "arbor://shell/exec" <> _), do: :gated
    def confirmation_mode(_principal, _uri), do: :auto
  end

  # Config keys we override so an unsigned test cap reaches check_approval (mirrors
  # the arbor_shell authorization_e2e_test setup). We do NOT touch approval-guard:
  # this test asserts on AuthDecision.evaluate directly, upstream of ApprovalGuard.
  @overrides [
    trust_policy_module: GatedShellPolicy,
    reflex_checking_enabled: false,
    capability_signing_required: false,
    strict_identity_mode: false
  ]

  setup do
    prev = Map.new(@overrides, fn {k, _} -> {k, Application.get_env(:arbor_security, k)} end)
    Enum.each(@overrides, fn {k, v} -> Application.put_env(:arbor_security, k, v) end)

    on_exit(fn ->
      Enum.each(prev, fn
        {k, nil} -> Application.delete_env(:arbor_security, k)
        {k, v} -> Application.put_env(:arbor_security, k, v)
      end)
    end)

    :ok
  end

  test "security regression (2026-04-07): a signed shell/exec cap with NO requires_approval flag is still gated by the trust profile" do
    agent_id = "agent_k2_#{:erlang.unique_integer([:positive])}"

    # A REAL store capability (find_matching_capability reads the CapabilityStore, not
    # pre-loaded context caps). It carries NO `requires_approval` constraint — the whole
    # point: pre-fix, `cap_demands_approval = false` and trust was never consulted, so
    # the decision was `:authorized` and shell auto-ran.
    cap = %Capability{
      id: "cap_shell_k2_#{:erlang.unique_integer([:positive])}",
      resource_uri: "arbor://shell/exec",
      principal_id: agent_id,
      granted_at: DateTime.utc_now(),
      expires_at: nil,
      constraints: %{},
      delegation_depth: 0,
      delegation_chain: [],
      metadata: %{test: true}
    }

    {:ok, :stored} = CapabilityStore.put(cap)

    auth = AuthContext.mark_verified(AuthContext.new(agent_id))

    # Trust gates shell/exec (`:gated`) and the cap carries no flag, so the ONLY
    # thing that can produce `:requires_approval` here is check_approval consulting
    # trust (the 2026-04-07 fix). Pre-fix this returned `{:ok, :authorized, ...}`.
    assert {:ok, :requires_approval, _cap, _auth} =
             AuthDecision.evaluate(auth, "arbor://shell/exec", :execute)
  end
end
