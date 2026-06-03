defmodule Arbor.Security.ConstraintEnforcementAdversarialTest do
  @moduledoc """
  Adversarial battery for capability constraint enforcement.

  Hypothesis going in: constraints (`max_uses`, `rate_limit`,
  `time_window`, `allowed_paths`, etc.) are the third instance of the
  session's pattern — "verification code plumbed but unused at
  production call sites." If that's right, an operator who grants
  `max_uses: 3` actually has unlimited uses; an operator who grants
  `rate_limit: 10` actually has no rate limit. That would make the
  capability constraint system theater.

  The tests answer: are constraints actually enforced when set?

  Constraint surfaces under test:

    1. `max_uses` — enforced by `Security.maybe_check_max_uses/1`
       (auto-revokes when count >= max_uses)
    2. `rate_limit` — enforced by `Constraint.evaluate_rate_limit/3`
       via the per-process token bucket
    3. `allowed_paths` — enforced by `Constraint.evaluate_allowed_paths/2`
    4. `time_window` — enforced by `Constraint.evaluate_time_window/1`
    5. `requires_approval` — recognized but documented as a Phase 5
       placeholder; pin the no-op

  Footgun surfaces:

    6. String keys (`"rate_limit"` vs `:rate_limit`) — the enforcer
       reads atom keys; string keys would be silently ignored.
    7. Unknown constraint keys — documented as silently-ignored for
       forward compat; pin behavior so a future strict-mode change
       is visible.

  Each test grants a cap, exercises the constraint, and asserts the
  enforce-or-deny behavior. Rate limits use unique principal+resource
  pairs to avoid bucket cross-contamination between tests.
  """

  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Security
  alias Arbor.Security.Constraint
  alias Arbor.Security.Constraint.RateLimiter

  setup do
    agent_id = "agent_cstr_#{:erlang.unique_integer([:positive])}"
    {:ok, agent_id: agent_id}
  end

  # ── max_uses ─────────────────────────────────────────────────────

  describe "max_uses enforcement" do
    test "cap with max_uses=3 authorizes exactly 3 times, denies the 4th",
         %{agent_id: agent} do
      {:ok, _cap} =
        Security.grant(
          principal: agent,
          resource: "arbor://shell/exec/ls",
          max_uses: 3
        )

      assert {:ok, :authorized} = Security.authorize(agent, "arbor://shell/exec/ls")
      assert {:ok, :authorized} = Security.authorize(agent, "arbor://shell/exec/ls")
      assert {:ok, :authorized} = Security.authorize(agent, "arbor://shell/exec/ls")
      # 4th call: cap was auto-revoked after the 3rd increment.
      assert {:error, _} = Security.authorize(agent, "arbor://shell/exec/ls")
    end

    test "cap with max_uses=1 (one-shot token)", %{agent_id: agent} do
      {:ok, _cap} =
        Security.grant(
          principal: agent,
          resource: "arbor://fs/read/secret_oneshot",
          max_uses: 1
        )

      assert {:ok, :authorized} = Security.authorize(agent, "arbor://fs/read/secret_oneshot")
      assert {:error, _} = Security.authorize(agent, "arbor://fs/read/secret_oneshot")
    end

    test "max_uses: nil means unlimited", %{agent_id: agent} do
      {:ok, _cap} =
        Security.grant(
          principal: agent,
          resource: "arbor://shell/exec/echo"
        )

      # Hammer it; should keep authorizing.
      for _ <- 1..50 do
        assert {:ok, :authorized} = Security.authorize(agent, "arbor://shell/exec/echo")
      end
    end
  end

  # ── rate_limit ───────────────────────────────────────────────────

  describe "rate_limit enforcement (token bucket)" do
    test "rate_limit: 3 allows 3 then denies the 4th in the same burst",
         %{agent_id: agent} do
      resource = "arbor://shell/exec/rate_test_#{:erlang.unique_integer([:positive])}"

      # Reset the bucket explicitly in case a prior test left state.
      RateLimiter.reset(agent, resource)

      {:ok, _cap} =
        Security.grant(
          principal: agent,
          resource: resource,
          constraints: %{rate_limit: 3}
        )

      assert {:ok, :authorized} = Security.authorize(agent, resource)
      assert {:ok, :authorized} = Security.authorize(agent, resource)
      assert {:ok, :authorized} = Security.authorize(agent, resource)
      # 4th call drained the bucket; refill hasn't happened in <1ms.
      assert {:error, _} = Security.authorize(agent, resource)
    end

    test "rate_limit per-resource buckets don't bleed", %{agent_id: agent} do
      r1 = "arbor://shell/exec/sep1_#{:erlang.unique_integer([:positive])}"
      r2 = "arbor://shell/exec/sep2_#{:erlang.unique_integer([:positive])}"

      RateLimiter.reset(agent, r1)
      RateLimiter.reset(agent, r2)

      {:ok, _} = Security.grant(principal: agent, resource: r1, constraints: %{rate_limit: 1})
      {:ok, _} = Security.grant(principal: agent, resource: r2, constraints: %{rate_limit: 1})

      assert {:ok, :authorized} = Security.authorize(agent, r1)
      assert {:error, _} = Security.authorize(agent, r1)

      # r2 has its own bucket — should still have a token.
      assert {:ok, :authorized} = Security.authorize(agent, r2)
      assert {:error, _} = Security.authorize(agent, r2)
    end
  end

  # ── allowed_paths ────────────────────────────────────────────────

  describe "allowed_paths enforcement" do
    test "allowed_paths denies non-matching resource", %{agent_id: agent} do
      # Allow only specific shell commands within the granted shell scope.
      # The cap's resource_uri matcher grants /shell/**; the constraint
      # narrows to specific subpaths.
      {:ok, _} =
        Security.grant(
          principal: agent,
          resource: "arbor://shell/**",
          constraints: %{
            allowed_paths: ["arbor://shell/exec/ls", "arbor://shell/exec/cat"]
          }
        )

      assert {:ok, :authorized} = Security.authorize(agent, "arbor://shell/exec/ls")
      assert {:ok, :authorized} = Security.authorize(agent, "arbor://shell/exec/cat")

      # Not in the allowed list — must deny even though resource_uri
      # matcher would otherwise grant.
      assert {:error, _} = Security.authorize(agent, "arbor://shell/exec/rm")
      assert {:error, _} = Security.authorize(agent, "arbor://shell/exec/curl")
    end

    test "allowed_paths uses path-boundary match (no prefix-fooling)",
         %{agent_id: agent} do
      {:ok, _} =
        Security.grant(
          principal: agent,
          resource: "arbor://shell/**",
          constraints: %{allowed_paths: ["arbor://shell/exec/git"]}
        )

      # Subpath: granted via constraint's path_matches? check.
      assert {:ok, :authorized} = Security.authorize(agent, "arbor://shell/exec/git/status")

      # Sibling with shared prefix: must deny (constraint's path_matches?
      # uses `resource == path or starts_with(resource, path <> "/")` —
      # same boundary check as the cap URI matcher).
      assert {:error, _} = Security.authorize(agent, "arbor://shell/exec/gitleaks")
    end
  end

  # ── time_window ──────────────────────────────────────────────────

  describe "time_window enforcement" do
    test "deny when current hour is outside the window", %{agent_id: agent} do
      # Construct a window that explicitly EXCLUDES the current hour.
      current_hour = DateTime.utc_now().hour
      excluded_start = rem(current_hour + 2, 24)
      excluded_end = rem(current_hour + 3, 24)

      {:ok, _} =
        Security.grant(
          principal: agent,
          resource: "arbor://fs/read/business_hours_only",
          constraints: %{
            time_window: %{start_hour: excluded_start, end_hour: excluded_end}
          }
        )

      assert {:error, _} =
               Security.authorize(agent, "arbor://fs/read/business_hours_only")
    end

    test "allow when current hour is inside the window", %{agent_id: agent} do
      # Construct a window that EXPLICITLY INCLUDES now.
      current_hour = DateTime.utc_now().hour
      window_start = current_hour
      window_end = rem(current_hour + 1, 24)

      {:ok, _} =
        Security.grant(
          principal: agent,
          resource: "arbor://fs/read/in_window",
          constraints: %{
            time_window: %{start_hour: window_start, end_hour: window_end}
          }
        )

      assert {:ok, :authorized} =
               Security.authorize(agent, "arbor://fs/read/in_window")
    end

    test "midnight-wrap window (22 → 6) is handled — current hour either in or out",
         _ctx do
      # We can't fake the wall clock, so just confirm the evaluator
      # returns either :ok or {:error, ...} for a midnight-wrapping
      # window. The midnight-wrap logic in the evaluator must not crash.
      result = Constraint.evaluate_time_window(%{start_hour: 22, end_hour: 6})

      assert match?(:ok, result) or
               match?({:error, {:constraint_violated, :time_window, _}}, result)
    end
  end

  # ── requires_approval (Phase 5 placeholder) ──────────────────────

  describe "requires_approval is a Phase 5 placeholder at the constraint layer" do
    test "requires_approval: true does NOT deny at the constraint layer",
         %{agent_id: agent} do
      # Per the Constraint moduledoc and code: requires_approval is
      # recognized but ALWAYS returns :ok. The actual approval check
      # runs in ApprovalGuard/Escalation, not the constraint enforcer.
      # Pin this so a future flip-to-strict surfaces here.
      {:ok, _} =
        Security.grant(
          principal: agent,
          resource: "arbor://fs/write/needs_review",
          constraints: %{requires_approval: true}
        )

      # No approval system stub set up — constraint-layer accepts.
      # The result may be :authorized OR :pending_approval depending on
      # whether ApprovalGuard fires elsewhere; either way it is NOT
      # the constraint enforcer rejecting it.
      result = Security.authorize(agent, "arbor://fs/write/needs_review")

      refute match?({:error, {:constraint_violated, :requires_approval, _}}, result),
             "Constraint layer rejected requires_approval — its docstring " <>
               "says it's a no-op placeholder. Either the docstring or the " <>
               "code changed."
    end
  end

  # ── String-keyed constraints (the silent-skip footgun) ────────────

  describe "constraint key types" do
    test "STRING-keyed constraints are atomized at Capability.new — enforcement fires",
         %{agent_id: agent} do
      # Regression: Capability.new/1 atomizes known constraint keys
      # (:rate_limit, :time_window, :allowed_paths, :requires_approval,
      # :taint_policy) so that a cap granted with string keys (e.g.
      # decoded from JSON, emitted by an LLM, bridged through a gateway)
      # gets the same enforcement as one granted with atom keys.
      #
      # Before the fix: the enforcer read `constraints[:rate_limit]`
      # (atom), the lookup returned nil on string-keyed maps, and the
      # rate limit was silently disabled.
      resource = "arbor://shell/exec/str_key_#{:erlang.unique_integer([:positive])}"
      RateLimiter.reset(agent, resource)

      {:ok, _cap} =
        Security.grant(
          principal: agent,
          resource: resource,
          constraints: %{"rate_limit" => 1}
        )

      # String-keyed `"rate_limit" => 1` is now equivalent to atom-keyed
      # `rate_limit: 1` — first call succeeds, second is rate-limited.
      assert {:ok, :authorized} = Security.authorize(agent, resource)
      assert {:error, _} = Security.authorize(agent, resource)
    end

    test "ATOM-keyed constraints ARE enforced (sanity check)", %{agent_id: agent} do
      resource = "arbor://shell/exec/atom_key_#{:erlang.unique_integer([:positive])}"
      RateLimiter.reset(agent, resource)

      {:ok, _} =
        Security.grant(
          principal: agent,
          resource: resource,
          constraints: %{rate_limit: 1}
        )

      assert {:ok, :authorized} = Security.authorize(agent, resource)
      assert {:error, _} = Security.authorize(agent, resource)
    end

    test "unknown constraint keys silently pass (documented forward-compat)",
         %{agent_id: agent} do
      # The moduledoc states "Unknown constraint keys are ignored for
      # forward compatibility." Pin that behavior so a future change to
      # strict-mode (which would be a defensible call) is visible here.
      {:ok, _} =
        Security.grant(
          principal: agent,
          resource: "arbor://fs/read/unknown_constraint",
          constraints: %{
            future_constraint_we_havent_built_yet: %{some: "spec"},
            rate_limit: 100
          }
        )

      assert {:ok, :authorized} =
               Security.authorize(agent, "arbor://fs/read/unknown_constraint")
    end
  end
end
