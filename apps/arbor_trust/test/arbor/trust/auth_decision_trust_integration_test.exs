defmodule Arbor.Trust.AuthDecisionTrustIntegrationTest do
  @moduledoc """
  **Security regression guard.**

  Asserts that `Arbor.Security.AuthDecision.check_approval` consults
  `Arbor.Trust.Policy.confirmation_mode/2` for capabilities that do NOT
  carry an explicit `requires_approval` constraint flag. Without this
  integration, a Trust-gated URI (e.g. shell.execute) authorizes silently
  whenever the capability lacks the constraint flag — which is exactly
  what happened on 2026-04-07: shell.execute auto-ran without approval
  for an unknown duration because AuthDecision only looked at the
  capability's constraint and never asked the trust profile.

  See `f17a4054`. Do **not** delete this test as "redundant" — it is the
  canary that catches a future refactor silently re-opening the hole.
  """

  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Contracts.Security.{AuthContext, Capability}
  alias Arbor.Security.AuthDecision
  alias Arbor.Security.CapabilityStore
  alias Arbor.Trust
  alias Arbor.Trust.Policy

  setup do
    ensure_security_started()
    ensure_trust_started()

    # Save & restore relevant config so this test doesn't poison others
    prev_reflex = Application.get_env(:arbor_security, :reflex_checking_enabled)
    prev_signing = Application.get_env(:arbor_security, :capability_signing_required)
    prev_identity = Application.get_env(:arbor_security, :strict_identity_mode)
    prev_approval = Application.get_env(:arbor_security, :approval_guard_enabled)
    prev_receipts = Application.get_env(:arbor_security, :invocation_receipts_enabled)
    prev_delegation = Application.get_env(:arbor_security, :delegation_chain_verification_enabled)
    prev_uri = Application.get_env(:arbor_security, :uri_registry_enforcement)

    Application.put_env(:arbor_security, :reflex_checking_enabled, false)
    Application.put_env(:arbor_security, :capability_signing_required, false)
    Application.put_env(:arbor_security, :strict_identity_mode, false)
    Application.put_env(:arbor_security, :invocation_receipts_enabled, false)
    Application.put_env(:arbor_security, :delegation_chain_verification_enabled, false)
    # Don't let URI registry reject our test URIs
    Application.put_env(:arbor_security, :uri_registry_enforcement, false)

    on_exit(fn ->
      restore(:reflex_checking_enabled, prev_reflex)
      restore(:capability_signing_required, prev_signing)
      restore(:strict_identity_mode, prev_identity)
      restore(:approval_guard_enabled, prev_approval)
      restore(:invocation_receipts_enabled, prev_receipts)
      restore(:delegation_chain_verification_enabled, prev_delegation)
      restore(:uri_registry_enforcement, prev_uri)
    end)

    agent_id = "agent_authdec_trust_#{:erlang.unique_integer([:positive])}"

    # Create a trust profile so Trust.Policy.confirmation_mode/2 has
    # something to read. Default presets gate shell at :ask.
    {:ok, _profile} = Trust.create_trust_profile(agent_id)

    {:ok, agent_id: agent_id}
  end

  describe "AuthDecision.check_approval (security regression guard for f17a4054)" do
    test "Trust-gated URI with non-approval capability returns :requires_approval",
         %{agent_id: agent_id} do
      # Sanity: trust says shell is gated for a fresh agent
      assert Policy.confirmation_mode(agent_id, "arbor://shell/exec/echo") == :gated

      # Capability without `requires_approval` constraint flag — exactly the
      # shape that previously slipped through.
      cap = grant_unconstrained_capability(agent_id, "arbor://shell/exec/echo")
      auth = AuthContext.new(agent_id, capabilities: [cap]) |> AuthContext.mark_verified()

      assert {:ok, :requires_approval, ^cap, _updated_auth} =
               AuthDecision.evaluate(auth, "arbor://shell/exec/echo", :execute)
    end

    test "Trust-gated canonical action URI also requires approval",
         %{agent_id: agent_id} do
      uri = "arbor://actions/execute/shell.execute"

      assert Policy.confirmation_mode(agent_id, uri) == :gated

      cap = grant_unconstrained_capability(agent_id, uri)
      auth = AuthContext.new(agent_id, capabilities: [cap]) |> AuthContext.mark_verified()

      assert {:ok, :requires_approval, ^cap, _} = AuthDecision.evaluate(auth, uri, :execute)
    end

    test "Trust-auto URI with non-approval capability authorizes without approval",
         %{agent_id: agent_id} do
      # historian/query is :auto in default presets — should pass without prompt
      uri = "arbor://historian/query"
      cap = grant_unconstrained_capability(agent_id, uri)
      auth = AuthContext.new(agent_id, capabilities: [cap]) |> AuthContext.mark_verified()

      # Either authorized (preferred) or, if the trust resolver thinks otherwise,
      # at least NOT silently approved when it should be gated. Use a sanity
      # branch so the test fails loudly on misconfiguration but doesn't false-fail
      # on harmless preset evolution.
      case AuthDecision.evaluate(auth, uri, :query) do
        {:ok, :authorized, _, _} ->
          :ok

        {:ok, :requires_approval, _, _} ->
          flunk("historian/query should not require approval — preset drift?")

        other ->
          flunk("unexpected AuthDecision result for historian/query: #{inspect(other)}")
      end
    end

    test "constraint-flag capability still requires approval (preserves prior behavior)",
         %{agent_id: agent_id} do
      # The OLD code path: capability with explicit requires_approval=true.
      # This must continue to work — the new trust check is additive.
      uri = "arbor://test/explicit_approval_required"

      cap = %Capability{
        id: "cap_explicit_#{:erlang.unique_integer([:positive])}",
        resource_uri: uri,
        principal_id: agent_id,
        granted_at: DateTime.utc_now(),
        expires_at: nil,
        constraints: %{requires_approval: true},
        delegation_depth: 0,
        delegation_chain: [],
        metadata: %{}
      }

      {:ok, :stored} = CapabilityStore.put(cap)

      auth = AuthContext.new(agent_id, capabilities: [cap]) |> AuthContext.mark_verified()

      assert {:ok, :requires_approval, ^cap, _} = AuthDecision.evaluate(auth, uri, :execute)
    end

    test "no capability at all yields :error (not :authorized)",
         %{agent_id: agent_id} do
      auth = AuthContext.new(agent_id) |> AuthContext.mark_verified()

      assert {:error, _reason, _} =
               AuthDecision.evaluate(auth, "arbor://shell/exec/echo", :execute)
    end
  end

  describe "security ceilings — defense in depth (regression guard)" do
    # These ceilings live in ProfileResolver.default_security_ceilings/0 and
    # apply to ALL profiles regardless of baseline/preset. Even the most
    # trusting profile (:hands_off / :veteran) must still confirm code and
    # filesystem writes. Without these ceilings, a veteran agent can write
    # arbitrary code and files without prompting — defeating the purpose of
    # any reflective oversight.
    test "code/write requires approval even for permissive profiles",
         %{agent_id: agent_id} do
      promote_to_hands_off(agent_id)
      uri = "arbor://code/write/foo.ex"
      cap = grant_unconstrained_capability(agent_id, uri)
      auth = AuthContext.new(agent_id, capabilities: [cap]) |> AuthContext.mark_verified()
      assert {:ok, :requires_approval, ^cap, _} = AuthDecision.evaluate(auth, uri, :execute)
    end

    test "fs/write requires approval even for permissive profiles",
         %{agent_id: agent_id} do
      promote_to_hands_off(agent_id)
      uri = "arbor://fs/write/tmp/x.txt"
      cap = grant_unconstrained_capability(agent_id, uri)
      auth = AuthContext.new(agent_id, capabilities: [cap]) |> AuthContext.mark_verified()
      assert {:ok, :requires_approval, ^cap, _} = AuthDecision.evaluate(auth, uri, :execute)
    end

    test "file.write canonical action URI requires approval", %{agent_id: agent_id} do
      promote_to_hands_off(agent_id)
      uri = "arbor://actions/execute/file.write"
      cap = grant_unconstrained_capability(agent_id, uri)
      auth = AuthContext.new(agent_id, capabilities: [cap]) |> AuthContext.mark_verified()
      assert {:ok, :requires_approval, ^cap, _} = AuthDecision.evaluate(auth, uri, :execute)
    end

    test "file.edit canonical action URI requires approval", %{agent_id: agent_id} do
      promote_to_hands_off(agent_id)
      uri = "arbor://actions/execute/file.edit"
      cap = grant_unconstrained_capability(agent_id, uri)
      auth = AuthContext.new(agent_id, capabilities: [cap]) |> AuthContext.mark_verified()
      assert {:ok, :requires_approval, ^cap, _} = AuthDecision.evaluate(auth, uri, :execute)
    end

    test "file.read remains auto even after the new ceilings", %{agent_id: agent_id} do
      promote_to_hands_off(agent_id)
      uri = "arbor://actions/execute/file.read"
      cap = grant_unconstrained_capability(agent_id, uri)
      auth = AuthContext.new(agent_id, capabilities: [cap]) |> AuthContext.mark_verified()

      case AuthDecision.evaluate(auth, uri, :execute) do
        {:ok, :authorized, _, _} ->
          :ok

        {:ok, :requires_approval, _, _} ->
          flunk("file.read should NOT require approval — ceiling too broad?")

        other ->
          flunk("unexpected: #{inspect(other)}")
      end
    end
  end

  describe "pre-approved cap bypass (signed caps file exemption)" do
    # Pre-approved bypass: a cap minted from a verified signed `.caps.json`
    # carries `metadata.provenance` (set by RunIdentity.grant_run_caps).
    # AuthDecision.check_approval bypasses the ceiling :ask gate when the
    # cap's URI is parameter-bounded AND the requested URI is NOT in the
    # always-locked list (shell/governance/hot_load).
    #
    # The morning-reports pipelines hit this in 2026-06-06: caps file
    # signed by operator pre-approved fs/write to a specific reports
    # subtree, but the ceiling forced :ask and the ephemeral identity had
    # no human-presence channel, so writes timed out.

    test "pre-approved bounded fs/write cap bypasses the ceiling", %{agent_id: agent_id} do
      cap_uri = "arbor://fs/write/Users/azmaveth/.arbor/reports/morning-digest-synthesis/**"

      requested =
        "arbor://fs/write/Users/azmaveth/.arbor/reports/morning-digest-synthesis/2026-06-06.md"

      cap = grant_preapproved_capability(agent_id, cap_uri)
      auth = AuthContext.new(agent_id, capabilities: [cap]) |> AuthContext.mark_verified()

      assert {:ok, :authorized, ^cap, _} = AuthDecision.evaluate(auth, requested, :execute)
    end

    test "pre-approved bounded code/write cap bypasses the ceiling", %{agent_id: agent_id} do
      cap_uri = "arbor://code/write/lib/foo/bar.ex"
      cap = grant_preapproved_capability(agent_id, cap_uri)
      auth = AuthContext.new(agent_id, capabilities: [cap]) |> AuthContext.mark_verified()

      assert {:ok, :authorized, ^cap, _} = AuthDecision.evaluate(auth, cap_uri, :execute)
    end

    test "pre-approved bounded file.write action cap bypasses the ceiling",
         %{agent_id: agent_id} do
      cap_uri = "arbor://actions/execute/file.write"
      cap = grant_preapproved_capability(agent_id, cap_uri)
      auth = AuthContext.new(agent_id, capabilities: [cap]) |> AuthContext.mark_verified()

      assert {:ok, :authorized, ^cap, _} = AuthDecision.evaluate(auth, cap_uri, :execute)
    end

    test "pre-approved shell cap STILL requires approval (always-locked)",
         %{agent_id: agent_id} do
      cap_uri = "arbor://shell/exec/git"
      cap = grant_preapproved_capability(agent_id, cap_uri)
      auth = AuthContext.new(agent_id, capabilities: [cap]) |> AuthContext.mark_verified()

      # Shell parameter space (command args) can't be bound by URI prefix —
      # an issuer signing "arbor://shell/exec/git" doesn't constrain
      # `git push --force` vs `git status`. Bypass must NOT apply.
      assert {:ok, :requires_approval, ^cap, _} =
               AuthDecision.evaluate(auth, cap_uri, :execute)
    end

    test "pre-approved governance cap STILL requires approval (always-locked)",
         %{agent_id: agent_id} do
      cap_uri = "arbor://governance/update/policy"
      cap = grant_preapproved_capability(agent_id, cap_uri)
      auth = AuthContext.new(agent_id, capabilities: [cap]) |> AuthContext.mark_verified()

      # Governance changes are self-modifying — an agent that can change
      # governance can grant itself anything next cycle. No pre-approval
      # bypass.
      assert {:ok, :requires_approval, ^cap, _} =
               AuthDecision.evaluate(auth, cap_uri, :execute)
    end

    test "pre-approved canonical shell action URI STILL requires approval",
         %{agent_id: agent_id} do
      cap_uri = "arbor://actions/execute/shell.execute"
      cap = grant_preapproved_capability(agent_id, cap_uri)
      auth = AuthContext.new(agent_id, capabilities: [cap]) |> AuthContext.mark_verified()

      assert {:ok, :requires_approval, ^cap, _} =
               AuthDecision.evaluate(auth, cap_uri, :execute)
    end

    test "pre-approved code.hot_load STILL requires approval (always-locked)",
         %{agent_id: agent_id} do
      cap_uri = "arbor://actions/execute/code.hot_load"
      cap = grant_preapproved_capability(agent_id, cap_uri)
      auth = AuthContext.new(agent_id, capabilities: [cap]) |> AuthContext.mark_verified()

      # Runtime code injection can backdoor any subsequent cap check.
      # Pre-approval must never unlock this.
      assert {:ok, :requires_approval, ^cap, _} =
               AuthDecision.evaluate(auth, cap_uri, :execute)
    end

    test "pre-approved cap with parameter-unbounded URI requires approval",
         %{agent_id: agent_id} do
      # URI ends in /** right at the action level — operator essentially
      # said "any fs/write." That's broader than the bypass design accepts:
      # the cap URI must have a concrete leaf past <domain>/<operation>.
      cap_uri = "arbor://fs/write/**"
      cap = grant_preapproved_capability(agent_id, cap_uri)
      auth = AuthContext.new(agent_id, capabilities: [cap]) |> AuthContext.mark_verified()

      assert {:ok, :requires_approval, ^cap, _} =
               AuthDecision.evaluate(auth, "arbor://fs/write/some/path", :execute)
    end

    test "non-pre-approved bounded fs/write cap still requires approval",
         %{agent_id: agent_id} do
      # Same bounded URI as the bypass-success test, but no provenance ->
      # falls back to the ceiling :ask gate. Proves provenance is the
      # actual discriminator (not the URI shape).
      cap_uri = "arbor://fs/write/Users/azmaveth/.arbor/reports/x.md"
      cap = grant_unconstrained_capability(agent_id, cap_uri)
      auth = AuthContext.new(agent_id, capabilities: [cap]) |> AuthContext.mark_verified()

      assert {:ok, :requires_approval, ^cap, _} =
               AuthDecision.evaluate(auth, cap_uri, :execute)
    end

    test "pre-approved cap with explicit requires_approval constraint STILL gates",
         %{agent_id: agent_id} do
      # Per-cap requires_approval=true is a stronger statement than ceiling:
      # the issuer attested to the cap but ALSO opted into runtime
      # confirmation. The bypass must respect that.
      cap_uri = "arbor://fs/write/Users/azmaveth/code/critical.ex"

      cap = %Capability{
        id: "cap_pp_constrained_#{:erlang.unique_integer([:positive])}",
        resource_uri: cap_uri,
        principal_id: agent_id,
        granted_at: DateTime.utc_now(),
        expires_at: nil,
        constraints: %{requires_approval: true},
        delegation_depth: 0,
        delegation_chain: [],
        metadata: %{provenance: %{source: :caps_file, issuer_id: "agent_test_issuer"}}
      }

      {:ok, :stored} = CapabilityStore.put(cap)
      auth = AuthContext.new(agent_id, capabilities: [cap]) |> AuthContext.mark_verified()

      assert {:ok, :requires_approval, ^cap, _} =
               AuthDecision.evaluate(auth, cap_uri, :execute)
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  # Promote a profile to the most permissive (`:hands_off`) preset, which is
  # what happens to system agents like the diagnostician via tier mapping.
  # The point of this test family is to prove the security ceilings still
  # gate writes even at maximum trust.
  defp promote_to_hands_off(agent_id) do
    {baseline, rules} = Arbor.Trust.Authority.preset_rules(:hands_off)

    Arbor.Trust.Store.update_profile(agent_id, fn profile ->
      %{profile | baseline: baseline, rules: rules}
    end)
  end

  # Grants a capability with no `requires_approval` constraint flag — the
  # exact shape that produced the 2026-04-07 regression.
  defp grant_unconstrained_capability(agent_id, resource_uri) do
    cap = %Capability{
      id: "cap_unconstrained_#{:erlang.unique_integer([:positive])}",
      resource_uri: resource_uri,
      principal_id: agent_id,
      granted_at: DateTime.utc_now(),
      expires_at: nil,
      constraints: %{},
      delegation_depth: 0,
      delegation_chain: [],
      metadata: %{regression_test: true}
    }

    {:ok, :stored} = CapabilityStore.put(cap)
    cap
  end

  # Grants a capability with `metadata.provenance` set — mirrors what
  # `Arbor.Scheduler.RunIdentity.grant_run_caps/2` produces after a
  # successful `CapsFile.load`. AuthDecision treats this as the pre-
  # approval marker that lets bounded askable URIs bypass the ceiling.
  defp grant_preapproved_capability(agent_id, resource_uri) do
    cap = %Capability{
      id: "cap_preapproved_#{:erlang.unique_integer([:positive])}",
      resource_uri: resource_uri,
      principal_id: agent_id,
      granted_at: DateTime.utc_now(),
      expires_at: nil,
      constraints: %{},
      delegation_depth: 0,
      delegation_chain: [],
      metadata: %{
        provenance: %{
          source: :caps_file,
          issuer_id: "agent_test_issuer_#{:erlang.unique_integer([:positive])}"
        }
      }
    }

    {:ok, :stored} = CapabilityStore.put(cap)
    cap
  end

  defp ensure_trust_started do
    if Process.whereis(Arbor.Trust.EventStore) == nil do
      ExUnit.Callbacks.start_supervised!({Arbor.Trust.EventStore, []})
    end

    if Process.whereis(Arbor.Trust.Store) == nil do
      ExUnit.Callbacks.start_supervised!({Arbor.Trust.Store, []})
    end

    if Process.whereis(Arbor.Trust.Manager) == nil do
      ExUnit.Callbacks.start_supervised!(
        {Arbor.Trust.Manager, [circuit_breaker: false, decay: false, event_store: true]}
      )
    end
  end

  defp ensure_security_started do
    children = [
      {Arbor.Security.Identity.Registry, []},
      {Arbor.Security.Identity.NonceCache, []},
      {Arbor.Security.SystemAuthority, []},
      {Arbor.Security.CapabilityStore, []},
      {Arbor.Security.Reflex.Registry, []}
    ]

    if Process.whereis(Arbor.Security.Supervisor) do
      for child <- children do
        try do
          case Supervisor.start_child(Arbor.Security.Supervisor, child) do
            {:ok, _} -> :ok
            {:error, {:already_started, _}} -> :ok
            {:error, :already_present} -> :ok
            _ -> :ok
          end
        catch
          :exit, _ -> :ok
        end
      end
    end
  end

  defp restore(key, nil), do: Application.delete_env(:arbor_security, key)
  defp restore(key, value), do: Application.put_env(:arbor_security, key, value)
end
