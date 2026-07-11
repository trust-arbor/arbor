defmodule Arbor.Actions.Council.BlastRadiusTest do
  use ExUnit.Case, async: true

  alias Arbor.Actions.Council.BlastRadius
  alias Arbor.Contracts.Judge.Verdict
  alias Arbor.Contracts.Security.CapabilityProfile

  @moduletag :fast

  describe "blast_radius/2" do
    test "classifies security, trust, contracts, engine, manifest, and migrations as high risk" do
      high_risk_paths = [
        "apps/arbor_security/lib/arbor/security.ex",
        "apps/arbor_trust/lib/arbor/trust.ex",
        "apps/arbor_contracts/lib/arbor/contracts/security/capability.ex",
        "apps/arbor_orchestrator/lib/arbor/orchestrator/engine.ex",
        "apps/arbor_orchestrator/lib/arbor/orchestrator/engine/checkpoint.ex",
        "apps/arbor_agent/priv/templates/coding_agent.md",
        "apps/arbor_persistence/priv/repo/migrations/20260707000000_add_eval_runs.exs"
      ]

      for path <- high_risk_paths do
        assert BlastRadius.blast_radius([path]) == :high
      end
    end

    test "classifies docs-only changes as low risk" do
      assert BlastRadius.blast_radius(["docs/arbor/DOT_PIPELINE_GUIDE.md"]) == :low
    end

    test "uses an injected capability profile lookup for path-specific risk" do
      lookup = fn
        "priv/runtime_policy.exs" -> profile(blast_radius: :high, reversibility: :reversible)
        _path -> nil
      end

      assert BlastRadius.blast_radius(["priv/runtime_policy.exs"],
               capability_profile_for_path: lookup
             ) == :high
    end

    test "treats irreversible capability profiles as high risk" do
      lookup = fn _path ->
        profile(blast_radius: :low, reversibility: :irreversible)
      end

      assert BlastRadius.blast_radius(["config/reversible-looking.exs"],
               capability_profile_for_path: lookup
             ) == :high
    end
  end

  describe "route/3" do
    test "routes low-risk keep verdicts to auto proceed" do
      route = BlastRadius.route(verdict(:keep), ["docs/README.md"])

      assert route.action == :auto_proceed
      assert route.blast_radius == :low
      refute route.human_required
    end

    test "routes high-risk keep verdicts to human review" do
      route = BlastRadius.route(verdict(:keep), ["apps/arbor_security/lib/arbor/security.ex"])

      assert route.action == :human_review
      assert route.blast_radius == :high
      assert route.human_required
      assert :security_app in route.reasons
    end

    test "routes revise verdicts back to the agent" do
      route = BlastRadius.route(verdict(:revise), ["docs/README.md"])

      assert route.action == :rework
      refute route.human_required
    end

    test "routes reject verdicts to stop" do
      route = BlastRadius.route(verdict(:reject), ["docs/README.md"])

      assert route.action == :stop
      refute route.human_required
    end

    test "carve-out: self-authority surfaces always route to human review" do
      route =
        BlastRadius.route(verdict(:keep), [
          "apps/arbor_actions/priv/pipelines/code-review-council.dot"
        ])

      assert route.action == :human_review
      assert route.authority_widening
      assert :code_review_council_dot in route.reasons
    end

    test "carve-out: explicit authority widening always routes to human review" do
      route = BlastRadius.route(verdict(:keep), ["docs/README.md"], authority_widening?: true)

      assert route.action == :human_review
      assert route.authority_widening
      assert route.blast_radius == :low
    end

    test "carve-out: security veto always routes to human review" do
      route = BlastRadius.route(verdict(:keep), ["docs/README.md"], security_veto?: true)

      assert route.action == :human_review
      assert route.security_veto
      assert :security_veto in route.reasons
    end

    test "configured high-risk paths do not imply self-authority widening" do
      route =
        BlastRadius.route(verdict(:reject), ["ops/release.exs"],
          policy: %{high_risk_paths: [{"ops/release.exs", :release_script}]}
        )

      assert route.action == :stop
      assert route.blast_radius == :high
      refute route.authority_widening
      assert :release_script in route.reasons
    end
  end

  defp verdict(recommendation) do
    {:ok, verdict} =
      Verdict.new(%{
        overall_score: 0.9,
        recommendation: recommendation,
        mode: :verification
      })

    verdict
  end

  defp profile(attrs) do
    defaults = %{
      uri_prefix: "arbor://configured/high-risk",
      owner: :arbor_actions,
      blast_radius: :high,
      reversibility: :reversible,
      effect_class: :local_write,
      data_class: :internal,
      arg_dependent: true,
      default_approval: :require_human,
      delegable: false,
      cost_class: :cheap,
      graduation_eligible: false
    }

    defaults
    |> Map.merge(Map.new(attrs))
    |> CapabilityProfile.new!()
  end
end
