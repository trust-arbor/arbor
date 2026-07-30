defmodule Arbor.Orchestrator.CodingPlan.ValidationCapacityTerminal do
  @moduledoc false

  # Shared terminal capacity normalization/validation for coding results.
  # Accepts three distinct shapes without conflating them:
  #   * default Mix.Compile termination envelope (any Shell capacity flag)
  #   * security_regression termination envelope (requires timed_out == true)
  #   * CrossApp batch capacity handoff (schema-v3 live)
  #
  # Live write/finalize/normalize paths accept schema-v3 handoffs only.
  # Callers that already hold historical evidence may verify any known
  # generation explicitly via `verify_archived_capacity_handoff/1`; no live
  # path calls it for admission.

  alias Arbor.Contracts.Coding.ValidationCapacityHandoff

  @termination_fields ~w(timed_out killed output_limit_exceeded cancelled)
  @max_validation_entries 1

  @type normalize_error ::
          {:invalid_finalize_result, :capacity_handoff}
          | {:invalid_terminal_result, :capacity_handoff}

  @type consistency_error ::
          {:invalid_finalize_result, :capacity_status_mismatch}
          | {:invalid_finalize_result, :capacity_evidence_mismatch}
          | {:invalid_finalize_result, :capacity_handoff}
          | {:invalid_terminal_result, :capacity_status_mismatch}
          | {:invalid_terminal_result, :capacity_evidence_mismatch}
          | {:invalid_terminal_result, :capacity_handoff}

  @doc """
  Normalize capacity evidence inside a terminal/finalize coding result.

  Non-capacity results pass through unchanged. Capacity results keep either the
  default termination envelope or the CrossApp batch handoff, never both.
  """
  @spec normalize_result(map(), :finalize | :terminal) ::
          {:ok, map()} | {:error, normalize_error()}
  def normalize_result(result, kind) when is_map(result) and kind in [:finalize, :terminal] do
    if Map.get(result, "status") == "validation_capacity_exceeded" do
      case normalize_capacity_validation(Map.get(result, "validation")) do
        {:ok, validation} ->
          {:ok, Map.put(result, "validation", validation)}

        :error ->
          {:error, capacity_error(kind, :capacity_handoff)}
      end
    else
      {:ok, result}
    end
  rescue
    _ -> {:error, capacity_error(kind, :capacity_handoff)}
  end

  def normalize_result(_result, kind), do: {:error, capacity_error(kind, :capacity_handoff)}

  @doc """
  Validate capacity status/evidence consistency for terminal or finalize results.
  """
  @spec validate_consistency(map(), :finalize | :terminal) ::
          :ok | {:error, consistency_error()}
  def validate_consistency(result, kind) when is_map(result) and kind in [:finalize, :terminal] do
    status = Map.get(result, "status")
    canonical_status = Map.get(result, "canonical_status")

    capacity_status? =
      status == "validation_capacity_exceeded" or
        canonical_status == "validation_capacity_exceeded"

    cond do
      capacity_status? and
        status == "validation_capacity_exceeded" and
          canonical_status == "validation_capacity_exceeded" ->
        if valid_capacity_validation?(Map.get(result, "validation")),
          do: :ok,
          else: {:error, capacity_error(kind, :capacity_handoff)}

      capacity_status? ->
        {:error, capacity_error(kind, :capacity_status_mismatch)}

      capacity_marker?(Map.get(result, "validation")) ->
        {:error, capacity_error(kind, :capacity_evidence_mismatch)}

      true ->
        :ok
    end
  end

  def validate_consistency(_result, kind),
    do: {:error, capacity_error(kind, :capacity_handoff)}

  @doc "Normalize a closed default-profile Shell termination envelope."
  @spec normalize_termination(term()) :: {:ok, map()} | :error
  def normalize_termination(termination)
      when is_map(termination) and not is_struct(termination) do
    with true <- map_size(termination) == length(@termination_fields),
         true <- MapSet.new(Map.keys(termination)) == MapSet.new(@termination_fields),
         true <- Enum.all?(@termination_fields, &is_boolean(termination[&1])),
         true <- Enum.any?(@termination_fields, &(termination[&1] == true)) do
      {:ok, Map.new(@termination_fields, fn field -> {field, termination[field]} end)}
    else
      _other -> :error
    end
  end

  def normalize_termination(_termination), do: :error

  @doc "Return true only for a closed, capacity-bearing default termination envelope."
  @spec valid_termination?(term()) :: boolean()
  def valid_termination?(termination), do: match?({:ok, _}, normalize_termination(termination))

  @doc """
  Explicit verification of a capacity handoff read from historical storage.

  Dispatches every known schema generation: v3 via live normalize, v2 via
  `normalize_archived_v2/1`, v1 via `normalize_archived_v1/1`. Unknown versions
  fail closed. This helper does not read storage itself and is not used by live
  write, finalize, or candidate verification paths (those admit v3 only).
  """
  @spec verify_archived_capacity_handoff(term()) :: {:ok, map()} | :error
  def verify_archived_capacity_handoff(handoff) when is_map(handoff) and not is_struct(handoff) do
    case Map.get(handoff, "schema_version") || Map.get(handoff, :schema_version) do
      3 ->
        case ValidationCapacityHandoff.normalize(handoff) do
          {:ok, normalized} -> {:ok, normalized}
          {:error, _} -> :error
        end

      2 ->
        case ValidationCapacityHandoff.normalize_archived_v2(handoff) do
          {:ok, normalized} -> {:ok, normalized}
          {:error, _} -> :error
        end

      1 ->
        case ValidationCapacityHandoff.normalize_archived_v1(handoff) do
          {:ok, normalized} -> {:ok, normalized}
          {:error, _} -> :error
        end

      _other ->
        :error
    end
  rescue
    _ -> :error
  end

  def verify_archived_capacity_handoff(_handoff), do: :error

  defp normalize_capacity_validation(validation) do
    with [report] when is_map(report) and not is_struct(report) <- validation,
         {:ok, normalized} <- normalize_capacity_report(report) do
      {:ok, [normalized]}
    else
      _other -> :error
    end
  end

  defp normalize_capacity_report(report) do
    cond do
      security_capacity_report?(report) ->
        # Security capacity requires exact timed_out evidence — killed-only is rejected.
        with {:ok, termination} <- normalize_termination(Map.get(report, "termination")),
             true <- termination["timed_out"] == true do
          {:ok, Map.put(report, "termination", termination)}
        else
          _other -> :error
        end

      default_profile_capacity_report?(report) ->
        # Default Mix.Compile admits any closed Shell capacity flag (including killed-only).
        with {:ok, termination} <- normalize_termination(Map.get(report, "termination")) do
          {:ok, Map.put(report, "termination", termination)}
        end

      cross_app_capacity_report?(report) ->
        test = Map.fetch!(report, "test")

        with {:ok, handoff} <-
               ValidationCapacityHandoff.normalize(Map.fetch!(test, "capacity_handoff")) do
          {:ok, Map.put(report, "test", Map.put(test, "capacity_handoff", handoff))}
        else
          _other -> :error
        end

      true ->
        :error
    end
  end

  defp valid_capacity_validation?(validation) do
    match?({:ok, _}, normalize_capacity_validation(validation)) and
      match?([_], validation) and length(validation) <= @max_validation_entries
  end

  # Security two-revision evidence carries candidate/base (and often attestation)
  # fields alongside reason + termination. Exact evidence_type alone is also
  # security capacity so an evidence-type-only killed report cannot fall through
  # the default killed-only path.
  defp security_capacity_report?(report) when is_map(report) and not is_struct(report) do
    Map.get(report, "reason") == "validation_capacity_exceeded" and
      Map.has_key?(report, "termination") and
      security_evidence_shape?(report) and
      not Map.has_key?(report, "test") and
      not Map.has_key?(report, "capacity_handoff")
  end

  defp security_capacity_report?(_report), do: false

  defp security_evidence_shape?(report) do
    (Map.has_key?(report, "candidate") and Map.has_key?(report, "base")) or
      Map.get(report, "adapter") == "security_regression_v1" or
      Map.get(report, "evidence_type") == "reviewed_regression_evidence" or
      Map.has_key?(report, "attested_candidate_tree_oid") or
      Map.has_key?(report, "candidate_fingerprint")
  end

  # Default Mix.Compile capacity: closed termination envelope without security
  # two-revision shape. Any trusted Shell capacity flag is admitted.
  defp default_profile_capacity_report?(report) when is_map(report) and not is_struct(report) do
    Map.get(report, "reason") == "validation_capacity_exceeded" and
      Map.has_key?(report, "termination") and
      not security_evidence_shape?(report) and
      not Map.has_key?(report, "test") and
      not Map.has_key?(report, "capacity_handoff")
  end

  defp default_profile_capacity_report?(_report), do: false

  defp cross_app_capacity_report?(report) when is_map(report) and not is_struct(report) do
    test = Map.get(report, "test")

    Map.get(report, "reason") == "validation_capacity_exceeded" and
      is_map(test) and not is_struct(test) and
      Map.get(test, "reason") == "validation_capacity_exceeded" and
      is_map(Map.get(test, "capacity_handoff")) and
      not Map.has_key?(report, "termination")
  end

  defp cross_app_capacity_report?(_report), do: false

  defp capacity_marker?(value) when is_map(value) and not is_struct(value) do
    Enum.any?(value, fn {key, nested} ->
      (key == "capacity_handoff" and is_map(nested)) or
        (key == "termination" and is_map(nested)) or
        (key in ~w(reason status canonical_status outcome) and
           nested in ~w(capacity_exceeded validation_capacity_exceeded)) or
        capacity_marker?(nested)
    end)
  end

  defp capacity_marker?(value) when is_list(value), do: Enum.any?(value, &capacity_marker?/1)
  defp capacity_marker?(_value), do: false

  defp capacity_error(:finalize, tag), do: {:invalid_finalize_result, tag}
  defp capacity_error(:terminal, tag), do: {:invalid_terminal_result, tag}
end
