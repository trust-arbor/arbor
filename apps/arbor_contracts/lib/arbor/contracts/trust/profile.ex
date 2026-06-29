defmodule Arbor.Contracts.Trust.Profile do
  @moduledoc """
  Trust profile data structure for self-improving agents.

  A trust profile carries an agent's frozen state and URI-prefix authorization
  rules (`baseline` + `rules`).

  ## Frozen State

  When `frozen` is true, the agent's modifiable capabilities are revoked.
  This is used by circuit breakers when anomalous behavior is detected.

  ## Authorization

  Authorization reads `baseline` + `rules` (URI-prefix trust rules). There is no
  trust-tier band — granular baseline/rules + capability checks govern access.

  @version "1.0.0"
  """

  use TypedStruct

  @derive Jason.Encoder
  typedstruct enforce: true do
    @typedoc "Trust profile for a self-improving agent"

    # Identity
    field(:agent_id, String.t())

    # Frozen state (circuit breaker)
    field(:frozen, boolean(), default: false)
    field(:frozen_reason, atom(), enforce: false)
    field(:frozen_at, DateTime.t(), enforce: false)

    # Component scores (0.0 to 100.0 each)
    field(:success_rate_score, float(), default: 0.0)
    field(:uptime_score, float(), default: 0.0)
    field(:security_score, float(), default: 100.0)
    field(:test_pass_score, float(), default: 0.0)
    field(:rollback_score, float(), default: 100.0)

    # Raw counters for success rate
    field(:total_actions, non_neg_integer(), default: 0)
    field(:successful_actions, non_neg_integer(), default: 0)

    # Security counters
    field(:security_violations, non_neg_integer(), default: 0)

    # Test counters
    field(:total_tests, non_neg_integer(), default: 0)
    field(:tests_passed, non_neg_integer(), default: 0)

    # Rollback/improvement counters
    field(:rollback_count, non_neg_integer(), default: 0)
    field(:improvement_count, non_neg_integer(), default: 0)

    # Council activity counters
    field(:proposals_submitted, non_neg_integer(), default: 0)
    field(:proposals_approved, non_neg_integer(), default: 0)
    field(:installations_successful, non_neg_integer(), default: 0)
    field(:installations_rolled_back, non_neg_integer(), default: 0)

    # URI-prefix trust rules (Trust Profiles Redesign)
    # baseline: default mode when no rule matches (:block | :ask | :allow | :auto)
    field(:baseline, atom(), default: :ask)
    # rules: %{"arbor://shell" => :block, "arbor://shell/exec/git" => :ask, ...}
    field(:rules, map(), default: %{})
    # model_constraints: %{{:frontier_cloud, "arbor://shell"} => :ask, ...}
    field(:model_constraints, map(), default: %{})

    # Egress standing (2026-06-14 URI-addressing-vs-classification decision).
    # Per-tier egress mode, keyed by Arbor.Contracts.Security.Classification
    # egress_tier (NOT by URI — the whole point of that decision). Explicit per
    # profile. Unset tiers fall back to a conservative default in
    # Arbor.Trust.Policy. e.g. %{external_provider: :allow, external_peer: :ask}
    field(:egress_modes, map(), default: %{})

    # Timestamps
    field(:created_at, DateTime.t())
    field(:updated_at, DateTime.t())
    field(:last_activity_at, DateTime.t(), enforce: false)
  end

  @doc """
  Create a new trust profile for an agent.

  Security and rollback scores start at 100.0 (no violations/rollbacks).

  ## Example

      {:ok, profile} = Profile.new("agent_123")
      profile.frozen
      #=> false
  """
  @spec new(String.t()) :: {:ok, t()} | {:error, term()}
  def new(agent_id) when is_binary(agent_id) and byte_size(agent_id) > 0 do
    now = DateTime.utc_now()

    profile = %__MODULE__{
      agent_id: agent_id,
      frozen: false,
      success_rate_score: 0.0,
      uptime_score: 0.0,
      security_score: 100.0,
      test_pass_score: 0.0,
      rollback_score: 100.0,
      total_actions: 0,
      successful_actions: 0,
      security_violations: 0,
      total_tests: 0,
      tests_passed: 0,
      rollback_count: 0,
      improvement_count: 0,
      proposals_submitted: 0,
      proposals_approved: 0,
      installations_successful: 0,
      installations_rolled_back: 0,
      created_at: now,
      updated_at: now,
      last_activity_at: nil
    }

    {:ok, profile}
  end

  def new(_), do: {:error, :invalid_agent_id}

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
  Convert profile to a map suitable for persistence.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = profile) do
    Map.from_struct(profile)
  end
end
