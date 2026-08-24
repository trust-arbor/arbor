defmodule Arbor.Orchestrator.CodingPlan.ValidatorFailureProjection do
  @moduledoc """
  Bounded, allowlisted projection of nested validator rejections.

  Arbitrary terms, maps, credentials, and inspect dumps collapse to
  `:validator_execution_failed` without copying the original value.
  """

  alias Arbor.Common.SafeAtom

  @allowlist [
    :attestation_already_claimed,
    :attestation_lease_mismatch,
    :attestation_not_claimed,
    :attestation_revoked,
    :capacity_retry_denied,
    :invalid_capacity_retry_proof,
    :invalid_review_attestation_id,
    :not_authorized,
    :not_found,
    :retry_budget_exhausted,
    :reviewed_material_changed,
    :successor_lineage_mismatch
  ]

  @action_failed_pattern ~r/\AAction [A-Za-z0-9_.]+ failed: :([a-z0-9_]+)\z/

  @doc "Project an executor error into a stable operator-visible reason."
  @spec project(term()) ::
          {:error, {:validator_rejected, atom()}} | {:error, :validator_execution_failed}
  def project(reason) when is_atom(reason) do
    case SafeAtom.to_allowed(reason, @allowlist) do
      {:ok, code} -> {:error, {:validator_rejected, code}}
      _ -> {:error, :validator_execution_failed}
    end
  end

  def project(reason) when is_binary(reason) do
    cond do
      match_allowlisted_binary?(reason) ->
        {:ok, code} = SafeAtom.to_allowed(reason, @allowlist)
        {:error, {:validator_rejected, code}}

      captured = Regex.run(@action_failed_pattern, reason, capture: :all_but_first) ->
        [name] = captured

        case SafeAtom.to_allowed(name, @allowlist) do
          {:ok, code} -> {:error, {:validator_rejected, code}}
          _ -> {:error, :validator_execution_failed}
        end

      true ->
        {:error, :validator_execution_failed}
    end
  end

  def project(_reason), do: {:error, :validator_execution_failed}

  defp match_allowlisted_binary?(reason) do
    match?({:ok, _code}, SafeAtom.to_allowed(reason, @allowlist))
  end
end
