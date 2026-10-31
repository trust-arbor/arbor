defmodule Arbor.Trust.GraduationCore do
  @moduledoc """
  Pure graduation eligibility, revision and explicit decision rules.

  Human authority and current profile/policy inputs are gathered by the owners.
  A suggestion identifier is a comparison value, never authority to accept it.
  """

  alias Arbor.Contracts.Security.CapabilityUri
  alias Arbor.Trust.Authority

  def invalidate(entry) do
    Map.merge(entry, %{
      revision: Map.get(entry, :revision, 0) + 1,
      suggestion_id: nil,
      suggestion_profile_updated_at: nil,
      graduated: false,
      graduated_at: nil
    })
  end

  def eligibility(entry, prefix, profile, policy, threshold, capability_threshold, capability) do
    opts = [
      security_ceilings: policy.security_ceilings,
      allow_permissive_baseline: policy.allow_permissive_baseline,
      effect_class: capability.effect_class
    ]

    current_mode = Authority.effective_mode(profile, prefix, opts)
    ceiling = Authority.explain(profile, prefix, opts).ceiling_mode
    candidate = %{profile | rules: Map.put(profile.rules, prefix, :auto)}
    proposed_mode = Authority.effective_mode(candidate, prefix, opts)

    reason =
      cond do
        never_graduate?(capability) or capability_threshold == :never or threshold == :never ->
          :never_graduate

        not exact_prefix?(prefix) ->
          :unsafe_prefix

        not is_integer(threshold) or threshold < 0 ->
          :invalid_threshold

        profile.frozen ->
          :profile_frozen

        entry.locked ->
          :locked

        current_mode == :block ->
          :policy_blocked

        current_mode == :auto ->
          :already_automatic

        ceiling != :auto or proposed_mode != :auto ->
          :ceiling_restricted

        entry.human_streak < max(threshold, 1) ->
          :insufficient_human_evidence

        true ->
          nil
      end

    %{
      eligible: is_nil(reason),
      reason: reason,
      current_mode: current_mode,
      profile_updated_at: profile.updated_at,
      security_ceiling: ceiling,
      suggested_mode: :auto,
      threshold: threshold
    }
  end

  def unavailable(reason, threshold) do
    %{
      eligible: false,
      reason: reason,
      current_mode: :block,
      security_ceiling: :block,
      suggested_mode: :auto,
      threshold: threshold
    }
  end

  def suggest(entry, %{eligible: true}, profile, id, now) do
    %{
      entry
      | suggestion_id: id,
        suggestion_profile_updated_at: profile.updated_at,
        graduated: true,
        graduated_at: now
    }
  end

  def suggest(entry, _eligibility, _profile, _id, _now), do: entry

  def decide(entry, id, %{eligible: true}, profile, operation)
      when operation in [:accept, :decline] do
    if is_binary(id) and entry.suggestion_id == id and
         entry.suggestion_profile_updated_at == profile.updated_at do
      updated = entry |> invalidate() |> Map.put(:locked, operation == :decline)
      effects = if operation == :accept, do: [:persist_auto_rule], else: []
      {:ok, updated, effects}
    else
      {:error, :stale_graduation_suggestion}
    end
  end

  def decide(_entry, _id, eligibility, _profile, _operation), do: {:error, eligibility.reason}

  def show(agent_id, prefix, entry, eligibility) do
    current? = entry.suggestion_profile_updated_at == Map.get(eligibility, :profile_updated_at)

    eligibility =
      if eligibility.eligible and is_binary(entry.suggestion_id) and not current?,
        do: %{eligibility | eligible: false, reason: :profile_changed},
        else: eligibility

    Map.merge(entry, eligibility)
    |> Map.drop([:suggestion_profile_updated_at, :profile_updated_at])
    |> Map.merge(%{
      agent_id: agent_id,
      uri_prefix: prefix,
      pending: eligibility.eligible and current? and is_binary(entry.suggestion_id)
    })
  end

  def valid_options(opts, operation) do
    expected =
      if operation == :read,
        do: [:caller_id, :session_token],
        else: [:caller_id, :session_token, :suggestion_id]

    if is_list(opts) and Keyword.keyword?(opts) and
         Enum.sort(Keyword.keys(opts)) == Enum.sort(expected) do
      {:ok, Map.new(opts)}
    else
      {:error, :invalid_graduation_options}
    end
  end

  def valid_prefix?(prefix),
    do:
      is_binary(prefix) and byte_size(prefix) in 1..4096 and String.valid?(prefix) and
        canonical_prefix?(prefix, 1)

  defp never_graduate?(capability) do
    not capability.graduation_eligible or capability.default_approval == :forbid or
      capability.effect_class in [:governance, :trust_mutating, :identity_mutating, :financial] or
      capability.reversibility == :irreversible or capability.blast_radius == :critical
  end

  defp exact_prefix?(prefix), do: canonical_prefix?(prefix, 2)

  defp canonical_prefix?(prefix, minimum_segments) do
    case CapabilityUri.parse(prefix) do
      {:ok, parsed} ->
        parsed.wildcard == :none and length(parsed.segments) >= minimum_segments and
          not Enum.any?(parsed.segments, &(&1 in [".", "..", "*", "**"]))

      _ ->
        false
    end
  end
end
