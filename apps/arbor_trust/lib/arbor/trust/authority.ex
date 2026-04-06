defmodule Arbor.Trust.Authority do
  @moduledoc """
  Pure CRC module for trust authority operations.

  Centralizes all pure trust logic: score calculation, tier resolution,
  profile rule evaluation, and profile mutations. GenServer wrappers
  (Manager, Store) call these functions for the actual logic.

  ## CRC Pattern

  - **Construct**: `new_profile/2` — create a trust profile with preset rules
  - **Reduce**: `record_*/1-2`, `apply_decay/2`, `graduate/2` — pure state transitions
  - **Convert**: `effective_mode/3`, `explain/3`, `show_summary/1` — formatted output

  All functions are pure — no ETS, no GenServer calls, no side effects.
  """

  alias Arbor.Contracts.Trust.Profile

  # ===========================================================================
  # Construct
  # ===========================================================================

  @doc """
  Create a new trust profile with the correct preset for the given tier.

  This is the single entry point for profile creation — resolves the preset
  (baseline + rules) from the tier, avoiding the bug where tier was set but
  preset rules weren't applied.
  """
  @spec new_profile(String.t(), atom()) :: Profile.t()
  def new_profile(agent_id, tier \\ :untrusted) do
    {:ok, profile} = Profile.new(agent_id)
    {baseline, rules} = preset_rules_for_tier(tier)

    %{profile |
      tier: tier,
      baseline: baseline,
      rules: rules,
      trust_score: 0,
      trust_points: 0,
      created_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }
  end

  # ===========================================================================
  # Reduce — Score & Tier
  # ===========================================================================

  @doc "Record a successful action and recalculate scores."
  @spec record_action_success(Profile.t()) :: Profile.t()
  def record_action_success(%Profile{} = profile) do
    profile
    |> Map.update!(:successful_actions, &(&1 + 1))
    |> Map.update!(:total_actions, &(&1 + 1))
    |> recalculate_scores()
    |> touch()
  end

  @doc "Record a failed action and recalculate scores."
  @spec record_action_failure(Profile.t()) :: Profile.t()
  def record_action_failure(%Profile{} = profile) do
    profile
    |> Map.update!(:total_actions, &(&1 + 1))
    |> recalculate_scores()
    |> touch()
  end

  @doc "Record a security violation (deducts 20 points from security score)."
  @spec record_security_violation(Profile.t()) :: Profile.t()
  def record_security_violation(%Profile{} = profile) do
    profile
    |> Map.update!(:security_violations, &(&1 + 1))
    |> recalculate_scores()
    |> touch()
  end

  @doc "Record a test result."
  @spec record_test_result(Profile.t(), :passed | :failed) :: Profile.t()
  def record_test_result(%Profile{} = profile, :passed) do
    profile
    |> Map.update!(:tests_passed, &(&1 + 1))
    |> Map.update!(:total_tests, &(&1 + 1))
    |> recalculate_scores()
    |> touch()
  end

  def record_test_result(%Profile{} = profile, :failed) do
    profile
    |> Map.update!(:total_tests, &(&1 + 1))
    |> recalculate_scores()
    |> touch()
  end

  @doc "Record an approved proposal (awards trust points based on impact)."
  @spec record_proposal_approved(Profile.t(), atom()) :: Profile.t()
  def record_proposal_approved(%Profile{} = profile, impact \\ :medium) do
    points = points_for_impact(impact)

    profile
    |> Map.update!(:proposals_approved, &(&1 + 1))
    |> Map.update!(:trust_points, &(&1 + points))
    |> recalculate_scores()
    |> maybe_graduate()
    |> touch()
  end

  @doc "Apply trust decay for inactivity."
  @spec apply_decay(Profile.t(), non_neg_integer()) :: Profile.t()
  def apply_decay(%Profile{frozen: true} = profile, _days_inactive), do: profile

  def apply_decay(%Profile{} = profile, days_inactive) when days_inactive > 7 do
    # Lose 1 point per day after 7-day grace period, floor at 10
    points_to_lose = days_inactive - 7
    new_points = max(profile.trust_points - points_to_lose, 10)

    %{profile | trust_points: new_points}
    |> recalculate_scores()
  end

  def apply_decay(profile, _days_inactive), do: profile

  @doc "Freeze trust progression."
  @spec freeze(Profile.t(), atom() | String.t()) :: Profile.t()
  def freeze(%Profile{} = profile, reason) do
    %{profile | frozen: true, frozen_reason: reason, frozen_at: DateTime.utc_now()}
  end

  @doc "Unfreeze trust progression."
  @spec unfreeze(Profile.t()) :: Profile.t()
  def unfreeze(%Profile{} = profile) do
    %{profile | frozen: false, frozen_reason: nil, frozen_at: nil}
  end

  @doc "Update tier and apply the corresponding preset rules."
  @spec set_tier(Profile.t(), atom()) :: Profile.t()
  def set_tier(%Profile{} = profile, tier) do
    {baseline, rules} = preset_rules_for_tier(tier)

    %{profile |
      tier: tier,
      baseline: baseline,
      rules: Map.merge(profile.rules, rules)
    }
  end

  # ===========================================================================
  # Reduce — Profile Rules
  # ===========================================================================

  @doc "Set a specific URI rule on the profile."
  @spec set_rule(Profile.t(), String.t(), atom()) :: Profile.t()
  def set_rule(%Profile{} = profile, uri_prefix, mode)
      when mode in [:block, :ask, :allow, :auto] do
    %{profile | rules: Map.put(profile.rules, uri_prefix, mode)}
  end

  @doc "Remove a specific URI rule (falls back to baseline)."
  @spec remove_rule(Profile.t(), String.t()) :: Profile.t()
  def remove_rule(%Profile{} = profile, uri_prefix) do
    %{profile | rules: Map.delete(profile.rules, uri_prefix)}
  end

  # ===========================================================================
  # Convert — Mode Resolution
  # ===========================================================================

  @doc """
  Resolve effective mode for a resource URI.

  3-layer resolution (most restrictive wins):
  1. User preference (longest-prefix match in profile rules)
  2. Security ceiling (system-enforced maximums)
  3. Model constraint (optional per-model-class ceiling)
  """
  @spec effective_mode(Profile.t(), String.t(), keyword()) :: :block | :ask | :allow | :auto
  def effective_mode(%Profile{} = profile, resource_uri, opts \\ []) do
    # Layer 1: User preference
    user_mode = resolve_prefix(profile.rules, resource_uri, profile.baseline)

    # Layer 2: Security ceilings
    ceilings = Keyword.get(opts, :security_ceilings, default_security_ceilings())
    ceiling_mode = resolve_prefix(ceilings, resource_uri, :auto)

    # Layer 3: Model constraints
    model_constraints = profile.model_constraints || %{}
    model_class = Keyword.get(opts, :model_class)

    model_mode =
      if model_class do
        resolve_model_constraint(model_constraints, model_class, resource_uri)
      else
        :auto
      end

    # Most restrictive wins
    most_restrictive([user_mode, ceiling_mode, model_mode])
  end

  @doc "Explain the mode resolution chain for debugging."
  @spec explain(Profile.t(), String.t(), keyword()) :: map()
  def explain(%Profile{} = profile, resource_uri, opts \\ []) do
    ceilings = Keyword.get(opts, :security_ceilings, default_security_ceilings())
    model_class = Keyword.get(opts, :model_class)

    user_mode = resolve_prefix(profile.rules, resource_uri, profile.baseline)
    ceiling_mode = resolve_prefix(ceilings, resource_uri, :auto)

    model_mode =
      if model_class do
        resolve_model_constraint(profile.model_constraints || %{}, model_class, resource_uri)
      else
        :auto
      end

    %{
      resource_uri: resource_uri,
      effective_mode: most_restrictive([user_mode, ceiling_mode, model_mode]),
      user_mode: user_mode,
      ceiling_mode: ceiling_mode,
      model_mode: model_mode,
      baseline: profile.baseline,
      tier: profile.tier,
      matching_rule: find_matching_rule(profile.rules, resource_uri)
    }
  end

  # ===========================================================================
  # Convert — Display
  # ===========================================================================

  @doc "Format a trust summary for dashboard display."
  @spec show_summary(Profile.t()) :: map()
  def show_summary(%Profile{} = profile) do
    %{
      agent_id: profile.agent_id,
      tier: profile.tier,
      trust_score: profile.trust_score,
      trust_points: profile.trust_points,
      frozen: profile.frozen,
      baseline: profile.baseline,
      rule_count: map_size(profile.rules),
      stats: %{
        actions: "#{profile.successful_actions}/#{profile.total_actions}",
        violations: profile.security_violations,
        proposals: "#{profile.proposals_approved}/#{profile.proposals_submitted}",
        tests: "#{profile.tests_passed}/#{profile.total_tests}"
      }
    }
  end

  # ===========================================================================
  # Pure Helpers
  # ===========================================================================

  @doc "Resolve the tier for a trust score."
  @spec resolve_tier(non_neg_integer()) :: atom()
  def resolve_tier(score) when score >= 90, do: :autonomous
  def resolve_tier(score) when score >= 75, do: :veteran
  def resolve_tier(score) when score >= 50, do: :trusted
  def resolve_tier(score) when score >= 20, do: :probationary
  def resolve_tier(_), do: :untrusted

  @doc "Resolve tier from trust points."
  @spec resolve_tier_from_points(non_neg_integer()) :: atom()
  def resolve_tier_from_points(points) when points >= 2000, do: :autonomous
  def resolve_tier_from_points(points) when points >= 500, do: :veteran
  def resolve_tier_from_points(points) when points >= 100, do: :trusted
  def resolve_tier_from_points(points) when points >= 25, do: :probationary
  def resolve_tier_from_points(_), do: :untrusted

  @doc "Map tier to preset name."
  @spec tier_to_preset(atom()) :: atom()
  def tier_to_preset(tier) when tier in [:untrusted, :probationary], do: :cautious
  def tier_to_preset(:established), do: :cautious
  def tier_to_preset(:trusted), do: :balanced
  def tier_to_preset(:veteran), do: :hands_off
  def tier_to_preset(:autonomous), do: :full_trust
  def tier_to_preset(_), do: :cautious

  @doc "Get preset rules for a tier."
  @spec preset_rules_for_tier(atom()) :: {atom(), map()}
  def preset_rules_for_tier(tier) do
    preset = tier_to_preset(tier)
    preset_rules(preset)
  end

  @doc "Get baseline and rules for a preset name."
  @spec preset_rules(atom()) :: {atom(), map()}
  def preset_rules(:cautious) do
    {:ask,
     %{
       "arbor://code/read" => :auto,
       "arbor://code/write" => :block,
       "arbor://fs/read" => :auto,
       "arbor://historian/query" => :auto,
       "arbor://orchestrator" => :auto,
       "arbor://shell" => :block,
       "arbor://shell/exec" => :ask
     }}
  end

  def preset_rules(:balanced) do
    {:ask,
     %{
       "arbor://code/read" => :auto,
       "arbor://code/write" => :ask,
       "arbor://fs/read" => :auto,
       "arbor://fs/write" => :allow,
       "arbor://historian/query" => :auto,
       "arbor://orchestrator" => :auto,
       "arbor://shell" => :ask,
       "arbor://memory" => :auto
     }}
  end

  def preset_rules(:hands_off) do
    {:allow,
     %{
       "arbor://code/read" => :auto,
       "arbor://code/write" => :auto,
       "arbor://fs" => :auto,
       "arbor://historian" => :auto,
       "arbor://orchestrator" => :auto,
       "arbor://memory" => :auto,
       "arbor://shell" => :ask,
       "arbor://governance" => :ask
     }}
  end

  def preset_rules(:full_trust) do
    {:auto,
     %{
       "arbor://shell" => :ask,
       "arbor://governance" => :ask
     }}
  end

  def preset_rules(_), do: preset_rules(:cautious)

  @doc "Most restrictive mode from a list."
  @spec most_restrictive([atom()]) :: atom()
  def most_restrictive(modes) do
    modes
    |> Enum.min_by(&mode_index/1)
  end

  @doc "Trust points awarded for impact level."
  @spec points_for_impact(atom()) :: non_neg_integer()
  def points_for_impact(:low), do: 3
  def points_for_impact(:medium), do: 5
  def points_for_impact(:high), do: 10
  def points_for_impact(:critical), do: 20
  def points_for_impact(_), do: 5

  # ===========================================================================
  # Private
  # ===========================================================================

  @weights %{
    success_rate: 0.30,
    uptime: 0.15,
    security: 0.25,
    test_pass: 0.20,
    rollback: 0.10
  }

  defp recalculate_scores(%Profile{} = profile) do
    success_rate =
      if profile.total_actions > 0,
        do: profile.successful_actions / profile.total_actions * 100,
        else: 0.0

    security = max(100.0 - profile.security_violations * 20, 0.0)

    test_pass =
      if profile.total_tests > 0,
        do: profile.tests_passed / profile.total_tests * 100,
        else: 0.0

    rollback =
      if profile.improvement_count > 0,
        do: max(100.0 - profile.rollback_count / profile.improvement_count * 100, 0.0),
        else: 100.0

    score =
      round(
        success_rate * @weights.success_rate +
          profile.uptime_score * @weights.uptime +
          security * @weights.security +
          test_pass * @weights.test_pass +
          rollback * @weights.rollback
      )

    # Points-based tier can boost beyond score-based tier
    score_tier = resolve_tier(score)
    points_tier = resolve_tier_from_points(profile.trust_points)
    effective_tier = max_tier(score_tier, points_tier)

    %{profile |
      success_rate_score: success_rate,
      security_score: security,
      test_pass_score: test_pass,
      rollback_score: rollback,
      trust_score: score,
      tier: effective_tier,
      updated_at: DateTime.utc_now()
    }
  end

  defp maybe_graduate(%Profile{} = profile) do
    new_tier = resolve_tier_from_points(profile.trust_points)

    if tier_index(new_tier) > tier_index(profile.tier) do
      set_tier(profile, new_tier)
    else
      profile
    end
  end

  defp touch(%Profile{} = profile) do
    %{profile | last_activity_at: DateTime.utc_now(), updated_at: DateTime.utc_now()}
  end

  defp resolve_prefix(rules, uri, baseline) when is_map(rules) do
    # Longest prefix match
    matching =
      rules
      |> Enum.filter(fn {prefix, _mode} -> String.starts_with?(uri, prefix) end)
      |> Enum.sort_by(fn {prefix, _} -> -String.length(prefix) end)

    case matching do
      [{_prefix, mode} | _] -> mode
      [] -> baseline
    end
  end

  defp resolve_prefix(_, _, baseline), do: baseline

  defp resolve_model_constraint(constraints, model_class, uri) do
    matching =
      constraints
      |> Enum.filter(fn
        {{class, prefix}, _mode} ->
          class == model_class and String.starts_with?(uri, prefix)
        _ ->
          false
      end)
      |> Enum.sort_by(fn {{_, prefix}, _} -> -String.length(prefix) end)

    case matching do
      [{{_, _}, mode} | _] -> mode
      [] -> :auto
    end
  end

  defp find_matching_rule(rules, uri) do
    rules
    |> Enum.filter(fn {prefix, _} -> String.starts_with?(uri, prefix) end)
    |> Enum.sort_by(fn {prefix, _} -> -String.length(prefix) end)
    |> List.first()
  end

  defp mode_index(:block), do: 0
  defp mode_index(:ask), do: 1
  defp mode_index(:allow), do: 2
  defp mode_index(:auto), do: 3
  defp mode_index(_), do: 1

  defp tier_index(:untrusted), do: 0
  defp tier_index(:probationary), do: 1
  defp tier_index(:established), do: 1
  defp tier_index(:trusted), do: 2
  defp tier_index(:veteran), do: 3
  defp tier_index(:autonomous), do: 4
  defp tier_index(_), do: 0

  defp max_tier(a, b) do
    if tier_index(a) >= tier_index(b), do: a, else: b
  end

  defp default_security_ceilings do
    %{
      "arbor://shell" => :ask,
      "arbor://governance" => :ask
    }
  end
end
