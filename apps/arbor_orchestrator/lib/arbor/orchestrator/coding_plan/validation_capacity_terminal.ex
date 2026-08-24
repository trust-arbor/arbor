defmodule Arbor.Orchestrator.CodingPlan.ValidationCapacityTerminal do
  @moduledoc """
  Shared terminal/finalize admission for coding validation capacity and containment.

  Accepts three distinct capacity shapes without conflating them:
    * default Mix.Compile termination envelope (any Shell capacity flag)
    * security_regression termination envelope (requires timed_out == true)
    * CrossApp or ContractChange batch capacity handoff (schema-v3 live)

  Also admits containment terminals:
    * default Mix.Compile five-key envelope on a validation_failed result
    * ContractChange exclusive preflight XOR test five-key envelope

  Live write/finalize/normalize paths accept schema-v3 handoffs only.
  Callers that already hold historical evidence may verify any known
  generation explicitly via `verify_archived_capacity_handoff/1`; no live
  path calls it for admission. This module does not weaken
  `ValidationCapacityHandoff`.
  """

  alias Arbor.Contracts.Coding.ValidationCapacityHandoff

  @termination_fields ~w(timed_out killed output_limit_exceeded cancelled)
  # Distinct from capacity: five keys, requires containment_failure == true.
  @containment_termination_fields ~w(
    timed_out killed output_limit_exceeded cancelled containment_failure
  )
  @max_validation_entries 1

  @type normalize_error ::
          {:invalid_finalize_result, :capacity_handoff}
          | {:invalid_finalize_result, :capacity_evidence_mismatch}
          | {:invalid_finalize_result, :containment_status_mismatch}
          | {:invalid_finalize_result, :containment_evidence_mismatch}
          | {:invalid_terminal_result, :capacity_handoff}
          | {:invalid_terminal_result, :capacity_evidence_mismatch}
          | {:invalid_terminal_result, :containment_status_mismatch}
          | {:invalid_terminal_result, :containment_evidence_mismatch}

  @type consistency_error ::
          {:invalid_finalize_result, :capacity_status_mismatch}
          | {:invalid_finalize_result, :capacity_evidence_mismatch}
          | {:invalid_finalize_result, :capacity_handoff}
          | {:invalid_finalize_result, :containment_status_mismatch}
          | {:invalid_finalize_result, :containment_evidence_mismatch}
          | {:invalid_terminal_result, :capacity_status_mismatch}
          | {:invalid_terminal_result, :capacity_evidence_mismatch}
          | {:invalid_terminal_result, :capacity_handoff}
          | {:invalid_terminal_result, :containment_status_mismatch}
          | {:invalid_terminal_result, :containment_evidence_mismatch}

  @doc """
  Normalize capacity or containment evidence inside a terminal/finalize coding result.

  Non-capacity, non-containment results pass through unchanged. Capacity results
  keep either the default termination envelope or the CrossApp/ContractChange
  batch handoff, never both. Containment requires status validation_failed and
  exactly one exact five-key envelope.
  """
  @spec normalize_result(map(), :finalize | :terminal) ::
          {:ok, map()} | {:error, normalize_error()}
  def normalize_result(result, kind) when is_map(result) and kind in [:finalize, :terminal] do
    validation = Map.get(result, "validation")
    status = Map.get(result, "status")

    cond do
      status == "validation_capacity_exceeded" ->
        if capacity_passed_contradiction?(result) do
          {:error, terminal_error(kind, :capacity_handoff)}
        else
          case normalize_capacity_validation(validation) do
            {:ok, normalized} ->
              {:ok, Map.put(result, "validation", normalized)}

            :error ->
              {:error, terminal_error(kind, :capacity_handoff)}
          end
        end

      containment_claimed_validation?(validation) ->
        cond do
          status != "validation_failed" ->
            {:error, terminal_error(kind, :containment_status_mismatch)}

          containment_passed_contradiction?(result) ->
            {:error, terminal_error(kind, :containment_evidence_mismatch)}

          true ->
            case normalize_containment_validation(validation) do
              {:ok, normalized} ->
                {:ok, Map.put(result, "validation", normalized)}

              :error ->
                {:error, terminal_error(kind, :containment_evidence_mismatch)}
            end
        end

      containment_marker?(validation) ->
        {:error, terminal_error(kind, :containment_evidence_mismatch)}

      capacity_marker?(validation) ->
        {:error, terminal_error(kind, :capacity_evidence_mismatch)}

      true ->
        {:ok, result}
    end
  rescue
    _ -> {:error, terminal_error(kind, :capacity_handoff)}
  end

  def normalize_result(_result, kind), do: {:error, terminal_error(kind, :capacity_handoff)}

  @doc """
  Validate capacity/containment status and evidence consistency for terminal or finalize results.
  """
  @spec validate_consistency(map(), :finalize | :terminal) ::
          :ok | {:error, consistency_error()}
  def validate_consistency(result, kind) when is_map(result) and kind in [:finalize, :terminal] do
    status = Map.get(result, "status")
    canonical_status = Map.get(result, "canonical_status")
    validation = Map.get(result, "validation")

    capacity_status? =
      status == "validation_capacity_exceeded" or
        canonical_status == "validation_capacity_exceeded"

    cond do
      capacity_status? and
        status == "validation_capacity_exceeded" and
          canonical_status == "validation_capacity_exceeded" ->
        if not capacity_passed_contradiction?(result) and valid_capacity_validation?(validation),
          do: :ok,
          else: {:error, terminal_error(kind, :capacity_handoff)}

      capacity_status? ->
        {:error, terminal_error(kind, :capacity_status_mismatch)}

      containment_claimed_validation?(validation) ->
        cond do
          status != "validation_failed" or canonical_status != "validation_failed" ->
            {:error, terminal_error(kind, :containment_status_mismatch)}

          containment_passed_contradiction?(result) ->
            {:error, terminal_error(kind, :containment_evidence_mismatch)}

          match?({:ok, _}, normalize_containment_validation(validation)) ->
            :ok

          true ->
            {:error, terminal_error(kind, :containment_evidence_mismatch)}
        end

      containment_marker?(validation) ->
        {:error, terminal_error(kind, :containment_evidence_mismatch)}

      capacity_marker?(validation) ->
        {:error, terminal_error(kind, :capacity_evidence_mismatch)}

      true ->
        :ok
    end
  end

  def validate_consistency(_result, kind),
    do: {:error, terminal_error(kind, :capacity_handoff)}

  @doc """
  True when a live schema-v3 ContractChange capacity handoff belongs on `stage`.

  Preflight is index 1 of 2 (completed 0). Tests is index 2 of 2 (completed 1).
  Stage identity is batch index/position, never a label string.
  """
  @spec contract_handoff_matches_stage?(term(), term()) :: boolean()
  def contract_handoff_matches_stage?(:preflight, handoff) when is_map(handoff) do
    handoff["total_batch_count"] == 2 and
      case handoff["interrupted_batch"] do
        nil ->
          handoff["completed_batch_count"] == 0 and hd_index(handoff["unstarted_batches"]) == 1

        batch when is_map(batch) ->
          batch["index"] == 1 and batch["total"] == 2 and handoff["completed_batch_count"] == 0

        _other ->
          false
      end
  end

  def contract_handoff_matches_stage?(:test, handoff) when is_map(handoff) do
    handoff["total_batch_count"] == 2 and
      case handoff["interrupted_batch"] do
        nil ->
          handoff["completed_batch_count"] == 1 and hd_index(handoff["unstarted_batches"]) == 2

        batch when is_map(batch) ->
          batch["index"] == 2 and batch["total"] == 2 and handoff["completed_batch_count"] == 1

        _other ->
          false
      end
  end

  def contract_handoff_matches_stage?(_stage, _handoff), do: false

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
  Normalize a closed containment-only termination envelope.

  Exact five-key schema distinct from capacity's four-key envelope. Requires
  `containment_failure == true` so capacity evidence cannot be smuggled here.
  """
  @spec normalize_containment_termination(term()) :: {:ok, map()} | :error
  def normalize_containment_termination(termination)
      when is_map(termination) and not is_struct(termination) do
    with true <- map_size(termination) == length(@containment_termination_fields),
         true <-
           MapSet.new(Map.keys(termination)) == MapSet.new(@containment_termination_fields),
         true <- Enum.all?(@containment_termination_fields, &is_boolean(termination[&1])),
         true <- termination["containment_failure"] == true do
      {:ok, Map.new(@containment_termination_fields, fn field -> {field, termination[field]} end)}
    else
      _other -> :error
    end
  end

  def normalize_containment_termination(_termination), do: :error

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

      contract_change_capacity_report?(report) ->
        normalize_contract_change_capacity(report)

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

  defp contract_change_capacity_report?(report) when is_map(report) and not is_struct(report) do
    preflight = Map.get(report, "preflight")
    test = Map.get(report, "test")
    preflight_handoff? = has_key?(preflight, "capacity_handoff")
    test_handoff? = has_key?(test, "capacity_handoff")

    Map.get(report, "reason") == "validation_capacity_exceeded" and
      Map.get(report, "passed") == false and
      is_map(preflight) and is_map(test) and
      not Map.has_key?(report, "compile") and
      not Map.has_key?(report, "termination") and
      not Map.has_key?(report, "capacity_handoff") and
      not has_key?(preflight, "termination") and
      not has_key?(test, "termination") and
      xor_key?(preflight, test, "capacity_handoff") and
      valid_contract_capacity_sequence?(preflight, test, preflight_handoff?, test_handoff?)
  end

  defp contract_change_capacity_report?(_report), do: false

  defp valid_contract_capacity_sequence?(preflight, test, true, false) do
    Map.get(preflight, "status") == "completed" and
      Map.get(preflight, "passed") == false and
      Map.get(preflight, "reason") == "validation_capacity_exceeded" and
      valid_contract_capacity_exit?(preflight, Map.get(preflight, "capacity_handoff")) and
      Map.get(test, "status") == "skipped" and
      Map.get(test, "passed") == false and
      Map.get(test, "exit_code") == nil and
      Map.get(test, "reason") == "validation_capacity_exceeded"
  end

  defp valid_contract_capacity_sequence?(preflight, test, false, true) do
    Map.get(preflight, "status") == "completed" and
      Map.get(preflight, "passed") == true and
      Map.get(preflight, "exit_code") == 0 and
      is_nil(Map.get(preflight, "reason")) and
      Map.get(test, "status") == "completed" and
      Map.get(test, "passed") == false and
      Map.get(test, "reason") == "validation_capacity_exceeded" and
      valid_contract_capacity_exit?(test, Map.get(test, "capacity_handoff"))
  end

  defp valid_contract_capacity_sequence?(_preflight, _test, _preflight_handoff?, _test_handoff?),
    do: false

  defp containment_claimed_validation?(validation) do
    contract_change_containment_claimed_validation?(validation) or
      default_containment_claimed_validation?(validation)
  end

  defp contract_change_containment_claimed_validation?([report])
       when is_map(report) and not is_struct(report) do
    Map.get(report, "reason") == "validation_containment_failure" and
      is_map(Map.get(report, "preflight")) and is_map(Map.get(report, "test"))
  end

  defp contract_change_containment_claimed_validation?(_validation), do: false

  defp default_containment_claimed_validation?([report])
       when is_map(report) and not is_struct(report) do
    default_containment_claim_shape?(report)
  end

  defp default_containment_claimed_validation?(_validation), do: false

  defp normalize_containment_validation(validation) do
    cond do
      contract_change_containment_claimed_validation?(validation) ->
        normalize_contract_change_containment_validation(validation)

      default_containment_claimed_validation?(validation) ->
        normalize_default_containment_validation(validation)

      true ->
        :error
    end
  end

  defp normalize_contract_change_containment_validation(validation) do
    with [report] when is_map(report) and not is_struct(report) <- validation,
         true <- unique_containment_envelope?(report),
         true <- contract_change_containment_report?(report),
         {:ok, normalized} <- normalize_contract_change_containment(report) do
      {:ok, [normalized]}
    else
      _other -> :error
    end
  end

  defp normalize_default_containment_validation(validation) do
    with [report] when is_map(report) and not is_struct(report) <- validation,
         true <- unique_containment_envelope?(report),
         true <- default_containment_report?(report),
         {:ok, termination} <-
           normalize_containment_termination(Map.get(report, "termination")) do
      {:ok, [Map.put(report, "termination", termination)]}
    else
      _other -> :error
    end
  end

  defp unique_containment_envelope?(value), do: containment_envelope_count(value) == 1

  defp containment_envelope_count(value) when is_map(value) and not is_struct(value) do
    self_count =
      case normalize_containment_termination(value) do
        {:ok, _} -> 1
        :error -> 0
      end

    Enum.reduce(Map.values(value), self_count, fn nested, acc ->
      acc + containment_envelope_count(nested)
    end)
  end

  defp containment_envelope_count(value) when is_list(value) do
    Enum.reduce(value, 0, fn nested, acc -> acc + containment_envelope_count(nested) end)
  end

  defp containment_envelope_count(_value), do: 0

  defp default_containment_claim_shape?(report) when is_map(report) and not is_struct(report) do
    Map.get(report, "reason") == "validation_containment_failure" and
      Map.has_key?(report, "termination") and
      not security_evidence_shape?(report) and
      not Map.has_key?(report, "preflight") and
      not Map.has_key?(report, "test") and
      not Map.has_key?(report, "compile") and
      not Map.has_key?(report, "capacity_handoff")
  end

  defp default_containment_claim_shape?(_report), do: false

  defp default_containment_report?(report) when is_map(report) and not is_struct(report) do
    default_containment_claim_shape?(report) and Map.get(report, "passed") == false
  end

  defp default_containment_report?(_report), do: false

  defp contract_change_containment_report?(report)
       when is_map(report) and not is_struct(report) do
    preflight = Map.get(report, "preflight")
    test = Map.get(report, "test")
    preflight_term? = has_key?(preflight, "termination")
    test_term? = has_key?(test, "termination")

    Map.get(report, "reason") == "validation_containment_failure" and
      Map.get(report, "passed") == false and
      is_map(preflight) and is_map(test) and
      not Map.has_key?(report, "compile") and
      not Map.has_key?(report, "termination") and
      not has_key?(preflight, "capacity_handoff") and
      not has_key?(test, "capacity_handoff") and
      xor_key?(preflight, test, "termination") and
      valid_contract_containment_sequence?(preflight, test, preflight_term?, test_term?)
  end

  defp contract_change_containment_report?(_report), do: false

  defp valid_contract_containment_sequence?(preflight, test, true, false) do
    Map.get(preflight, "status") == "completed" and
      Map.get(preflight, "passed") == false and
      Map.get(preflight, "reason") == "validation_containment_failure" and
      is_integer(Map.get(preflight, "exit_code")) and
      Map.get(test, "status") == "skipped" and
      Map.get(test, "passed") == false and
      Map.get(test, "exit_code") == nil and
      Map.get(test, "reason") == "validation_containment_failure"
  end

  defp valid_contract_containment_sequence?(preflight, test, false, true) do
    Map.get(preflight, "status") == "completed" and
      Map.get(preflight, "passed") == true and
      Map.get(preflight, "exit_code") == 0 and
      is_nil(Map.get(preflight, "reason")) and
      Map.get(test, "status") == "completed" and
      Map.get(test, "passed") == false and
      Map.get(test, "reason") == "validation_containment_failure" and
      is_integer(Map.get(test, "exit_code"))
  end

  defp valid_contract_containment_sequence?(_preflight, _test, _preflight_term?, _test_term?),
    do: false

  defp normalize_contract_change_containment(report) do
    key =
      cond do
        has_key?(Map.get(report, "preflight"), "termination") -> "preflight"
        has_key?(Map.get(report, "test"), "termination") -> "test"
        true -> nil
      end

    check = is_binary(key) && Map.get(report, key)

    if is_map(check) do
      with {:ok, termination} <-
             normalize_containment_termination(Map.fetch!(check, "termination")) do
        {:ok, Map.put(report, key, Map.put(check, "termination", termination))}
      else
        _other -> :error
      end
    else
      :error
    end
  end

  defp normalize_contract_change_capacity(report) do
    key =
      cond do
        has_key?(Map.get(report, "preflight"), "capacity_handoff") -> "preflight"
        has_key?(Map.get(report, "test"), "capacity_handoff") -> "test"
        true -> nil
      end

    check = is_binary(key) && Map.get(report, key)

    stage =
      case key do
        "preflight" -> :preflight
        "test" -> :test
        _other -> nil
      end

    if is_map(check) and stage in [:preflight, :test] do
      with {:ok, handoff} <-
             ValidationCapacityHandoff.normalize(Map.fetch!(check, "capacity_handoff")),
           true <- contract_handoff_matches_stage?(stage, handoff),
           true <- valid_contract_capacity_exit?(check, handoff) do
        {:ok, Map.put(report, key, Map.put(check, "capacity_handoff", handoff))}
      else
        _other -> :error
      end
    else
      :error
    end
  end

  defp valid_contract_capacity_exit?(check, handoff) when is_map(check) and is_map(handoff) do
    exit_code = Map.get(check, "exit_code")

    case Map.get(handoff, "interrupted_batch") do
      nil -> exit_code == nil
      _interrupted -> is_nil(exit_code) or is_integer(exit_code)
    end
  end

  defp valid_contract_capacity_exit?(_check, _handoff), do: false

  defp capacity_passed_contradiction?(result) when is_map(result) do
    Map.get(result, "passed") == true or report_passed_true?(Map.get(result, "validation"))
  end

  defp capacity_passed_contradiction?(_result), do: false

  defp containment_passed_contradiction?(result) when is_map(result) do
    Map.get(result, "passed") == true or report_passed_true?(Map.get(result, "validation"))
  end

  defp containment_passed_contradiction?(_result), do: false

  defp report_passed_true?([report | _rest]) when is_map(report) and not is_struct(report),
    do: Map.get(report, "passed") == true

  defp report_passed_true?(_validation), do: false

  defp cross_app_capacity_report?(report) when is_map(report) and not is_struct(report) do
    test = Map.get(report, "test")

    Map.get(report, "reason") == "validation_capacity_exceeded" and
      is_map(test) and not is_struct(test) and
      Map.get(test, "reason") == "validation_capacity_exceeded" and
      is_map(Map.get(test, "capacity_handoff")) and
      not Map.has_key?(report, "termination") and
      not Map.has_key?(report, "preflight")
  end

  defp cross_app_capacity_report?(_report), do: false

  defp has_key?(check, key) when is_map(check) and not is_struct(check),
    do: Map.has_key?(check, key)

  defp has_key?(_check, _key), do: false

  defp xor_key?(a, b, key),
    do: has_key?(a, key) != has_key?(b, key) and (has_key?(a, key) or has_key?(b, key))

  defp hd_index([%{"index" => index} | _rest]) when is_integer(index), do: index
  defp hd_index(_batches), do: nil

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

  defp containment_marker?(value) when is_map(value) and not is_struct(value) do
    Enum.any?(value, fn {key, nested} ->
      (key == "termination" and containment_termination_shape?(nested)) or
        (key in ~w(reason status canonical_status outcome) and
           nested == "validation_containment_failure") or
        containment_marker?(nested)
    end)
  end

  defp containment_marker?(value) when is_list(value),
    do: Enum.any?(value, &containment_marker?/1)

  defp containment_marker?(_value), do: false

  defp containment_termination_shape?(nested)
       when is_map(nested) and not is_struct(nested) do
    MapSet.new(Map.keys(nested)) == MapSet.new(@containment_termination_fields)
  end

  defp containment_termination_shape?(_nested), do: false

  defp terminal_error(:finalize, tag), do: {:invalid_finalize_result, tag}
  defp terminal_error(:terminal, tag), do: {:invalid_terminal_result, tag}
end
