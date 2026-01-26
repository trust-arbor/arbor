defmodule Arbor.Contracts.Security.TrustProfile do
  @moduledoc """
  Trust profile data structure for self-improving agents.

  A trust profile tracks all metrics that contribute to an agent's
  trust score, which determines what self-modification capabilities
  the agent has earned.

  ## Trust Tiers

  | Tier | Score Range | Capabilities |
  |------|-------------|--------------|
  | :untrusted | 0-19 | Read own code |
  | :probationary | 20-49 | Sandbox modifications |
  | :trusted | 50-74 | Self-modify with approval |
  | :veteran | 75-89 | Self-modify auto-approved |
  | :autonomous | 90-100 | Modify own capabilities |

  ## Frozen State

  When `frozen` is true, the agent cannot earn additional trust.
  This is used by circuit breakers when anomalous behavior is detected.
  """

  use TypedStruct

  @derive Jason.Encoder
  typedstruct enforce: true do
    @typedoc "Trust profile for a self-improving agent"

    # Identity
    field(:agent_id, String.t())

    # Computed trust values
    field(:trust_score, non_neg_integer(), default: 0)
    field(:tier, atom(), default: :untrusted)

    # Frozen state (circuit breaker)
    field(:frozen, boolean(), default: false)
    field(:frozen_reason, atom(), enforce: false)
    field(:frozen_at, DateTime.t(), enforce: false)

    # Component scores (0.0 to 100.0 each)
    field(:success_rate_score, float(), default: 0.0)
    field(:security_score, float(), default: 100.0)
    field(:test_pass_score, float(), default: 0.0)

    # Raw counters
    field(:total_actions, non_neg_integer(), default: 0)
    field(:successful_actions, non_neg_integer(), default: 0)
    field(:security_violations, non_neg_integer(), default: 0)
    field(:total_tests, non_neg_integer(), default: 0)
    field(:tests_passed, non_neg_integer(), default: 0)

    # Timestamps
    field(:created_at, DateTime.t())
    field(:updated_at, DateTime.t())
    field(:last_activity_at, DateTime.t(), enforce: false)
  end

  @doc """
  Create a new trust profile for an agent.
  """
  @spec new(String.t()) :: {:ok, t()} | {:error, term()}
  def new(agent_id) when is_binary(agent_id) and byte_size(agent_id) > 0 do
    now = DateTime.utc_now()

    profile = %__MODULE__{
      agent_id: agent_id,
      trust_score: 0,
      tier: :untrusted,
      frozen: false,
      success_rate_score: 0.0,
      security_score: 100.0,
      test_pass_score: 0.0,
      total_actions: 0,
      successful_actions: 0,
      security_violations: 0,
      total_tests: 0,
      tests_passed: 0,
      created_at: now,
      updated_at: now,
      last_activity_at: nil
    }

    {:ok, profile}
  end

  def new(_), do: {:error, :invalid_agent_id}

  @doc """
  Update the trust score and tier based on current component scores.
  """
  @spec recalculate(t()) :: t()
  def recalculate(%__MODULE__{} = profile) do
    score = calculate_score(profile)
    tier = score_to_tier(score)

    %{profile | trust_score: score, tier: tier, updated_at: DateTime.utc_now()}
  end

  @doc """
  Record a successful action.
  """
  @spec record_action_success(t()) :: t()
  def record_action_success(%__MODULE__{} = profile) do
    profile
    |> Map.update!(:total_actions, &(&1 + 1))
    |> Map.update!(:successful_actions, &(&1 + 1))
    |> update_success_rate_score()
    |> touch_activity()
  end

  @doc """
  Record a failed action.
  """
  @spec record_action_failure(t()) :: t()
  def record_action_failure(%__MODULE__{} = profile) do
    profile
    |> Map.update!(:total_actions, &(&1 + 1))
    |> update_success_rate_score()
    |> touch_activity()
  end

  @doc """
  Record a security violation.
  """
  @spec record_security_violation(t()) :: t()
  def record_security_violation(%__MODULE__{} = profile) do
    profile
    |> Map.update!(:security_violations, &(&1 + 1))
    |> update_security_score()
    |> touch_activity()
  end

  @doc """
  Freeze the trust profile.
  """
  @spec freeze(t(), atom()) :: t()
  def freeze(%__MODULE__{} = profile, reason) do
    %{profile | frozen: true, frozen_reason: reason, frozen_at: DateTime.utc_now()}
  end

  @doc """
  Unfreeze the trust profile.
  """
  @spec unfreeze(t()) :: t()
  def unfreeze(%__MODULE__{} = profile) do
    %{profile | frozen: false, frozen_reason: nil, frozen_at: nil}
  end

  @doc """
  Convert profile to a map.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = profile) do
    Map.from_struct(profile)
  end

  # Private functions

  defp calculate_score(%__MODULE__{} = profile) do
    # Simplified scoring: success rate + security compliance + test pass rate
    score =
      profile.success_rate_score * 0.40 +
        profile.security_score * 0.35 +
        profile.test_pass_score * 0.25

    round(score)
  end

  defp score_to_tier(score) when score < 20, do: :untrusted
  defp score_to_tier(score) when score < 50, do: :probationary
  defp score_to_tier(score) when score < 75, do: :trusted
  defp score_to_tier(score) when score < 90, do: :veteran
  defp score_to_tier(_score), do: :autonomous

  defp update_success_rate_score(%__MODULE__{total_actions: 0} = profile) do
    %{profile | success_rate_score: 0.0}
  end

  defp update_success_rate_score(%__MODULE__{} = profile) do
    rate = profile.successful_actions / profile.total_actions * 100.0
    %{profile | success_rate_score: Float.round(rate, 2)}
  end

  defp update_security_score(%__MODULE__{} = profile) do
    score = max(0.0, 100.0 - profile.security_violations * 20.0)
    %{profile | security_score: score}
  end

  defp touch_activity(%__MODULE__{} = profile) do
    %{profile | last_activity_at: DateTime.utc_now()}
  end
end
