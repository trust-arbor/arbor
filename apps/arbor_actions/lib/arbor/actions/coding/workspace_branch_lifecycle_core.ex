defmodule Arbor.Actions.Coding.WorkspaceBranchLifecycleCore do
  @moduledoc """
  Pure branch/discard decision reducer for workspace settlement.

  Centralizes marker phase transitions, branch action selection from provenance
  plus a structured exact-ref observation, and dormancy/retry decisions. The
  reducer returns plain decisions/effects; it performs no filesystem, clock,
  process, or git operations. `Arbor.Actions.Coding.WorkspaceLeaseRegistry` is
  the imperative shell that interprets these decisions.

  Closure rules this reducer owns:

  * Retained expiry advances through `archive -> worktree -> branch`; archive
    completion resets the worktree-cleanup retry budget but preserves the exact
    captured tip and worktree identity.
  * Path ownership is not branch ownership. Branch retirement is gated solely
    by `provenance == :created` plus equality with the exact persisted deletion
    authority.
  * Reused/unknown provenance never deletes a branch: settlement preserves the
    pre-existing ref and reports residue.
  * Created branches with a divergent tip or a CAS mismatch are not retryable
    to convergence: the reducer selects a dormant branch-phase marker that
    preserves the ref and never claims settlement.
  * Checked-out branches and operational errors are retryable up to the
    configured limit; exhaustion selects a dormant branch-phase marker.
  * A dormant marker must stay dormant across restart, so hydration derives
    dormancy from `retry_count >= limit`.
  """

  alias Arbor.Contracts.Coding.BranchLifecycleDescriptor

  @type provenance :: :created | :reused | :unknown
  @type phase :: :archive | :worktree | :branch
  @type ref_observation :: :absent | {:present, String.t()} | {:error, term()}

  @failure_categories %{
    branch_checked_out: "branch_checked_out",
    branch_checked_out_race: "branch_checked_out_race",
    branch_ref_oid_mismatch: "branch_ref_oid_mismatch",
    branch_tip_diverged: "branch_tip_diverged",
    branch_provenance_not_created: "branch_provenance_not_created",
    discard_identity_unavailable: "discard_identity_unavailable",
    cleanup_retries_exhausted: "cleanup_retries_exhausted",
    marker_delete_failed: "marker_delete_failed",
    worktree_remove_failed: "worktree_remove_failed",
    retention_identity_unavailable: "retention_identity_unavailable",
    branch_observation_failed: "branch_observation_failed",
    branch_retire_failed: "branch_retire_failed",
    candidate_archive_failed: "candidate_archive_failed",
    unknown: "cleanup_failed"
  }

  @doc """
  Categorize a release result into closed branch lifecycle evidence.

  The input may contain internal terms while it is still inside the Actions
  boundary. The returned map is normalized JSON-clean evidence; arbitrary
  terms are reduced to a category and are never inspected into the receipt.
  """
  @spec release_receipt(map(), non_neg_integer()) :: {:ok, map()} | :error
  def release_receipt(result, retry_limit) when is_map(result) and is_integer(retry_limit) do
    status = string_value(result, :status)

    count =
      bounded_count(Map.get(result, :cleanup_retry_count, Map.get(result, "cleanup_retry_count")))

    limit =
      bounded_limit(
        Map.get(result, :cleanup_retry_limit, Map.get(result, "cleanup_retry_limit")),
        retry_limit
      )

    dormant? = Map.get(result, :cleanup_dormant, Map.get(result, "cleanup_dormant")) == true

    descriptor =
      case status do
        "discarded" ->
          %{
            branch_status:
              if(boolean_value(result, :branch_retired), do: "retired", else: "preserved"),
            cleanup_status: "complete",
            branch_preserved_reason: preserve_reason(result),
            evidence_ref: string_or_nil(result, :evidence_ref),
            published_commit: string_or_nil(result, :published_commit)
          }

        "discard_pending" ->
          %{
            branch_status: "pending",
            cleanup_status: if(dormant? or count >= limit, do: "dormant", else: "retrying"),
            branch_preserved_reason: preserve_reason(result),
            cleanup_retry_count: count,
            cleanup_retry_limit: limit,
            cleanup_failure_category:
              failure_category(
                Map.get(
                  result,
                  :cleanup_failure_category,
                  Map.get(result, "cleanup_failure_category")
                ) ||
                  Map.get(result, :cleanup_failure, Map.get(result, "cleanup_failure")) ||
                  Map.get(result, :pending_reason, Map.get(result, "pending_reason"))
              ),
            discard_phase:
              normalize_phase_string(
                Map.get(result, :discard_phase, Map.get(result, "discard_phase"))
              ),
            evidence_ref: string_or_nil(result, :evidence_ref),
            published_commit: string_or_nil(result, :published_commit)
          }

        status when status in ["retained", "removed"] ->
          %{
            branch_status:
              if(boolean_value(result, :branch_retired), do: "retired", else: "preserved"),
            cleanup_status: "complete",
            branch_preserved_reason: preserve_reason(result),
            evidence_ref: string_or_nil(result, :evidence_ref),
            published_commit: string_or_nil(result, :published_commit)
          }

        _ ->
          nil
      end

    case descriptor && BranchLifecycleDescriptor.normalize(descriptor) do
      {:ok, normalized} -> {:ok, normalized}
      _ -> :error
    end
  end

  def release_receipt(_result, _retry_limit), do: :error

  @doc "Return a bounded categorical failure reason without exposing its term."
  @spec failure_category(term()) :: String.t()
  def failure_category(reason), do: failure_category_for(reason)

  @doc "Return a bounded branch-preservation category without exposing a term."
  @spec preservation_reason(term()) :: String.t()
  def preservation_reason(reason) when is_binary(reason) do
    if String.valid?(reason) and byte_size(reason) in 1..128 and
         String.trim(reason) != "" and not String.contains?(reason, <<0>>) and
         not String.match?(reason, ~r/[\x00-\x1F\x7F]/),
       do: reason,
       else: "branch_preserved"
  end

  def preservation_reason(:reused_worktree), do: "reused_worktree"
  def preservation_reason(:branch_provenance_not_created), do: "branch_provenance_not_created"
  def preservation_reason(:branch_tip_diverged), do: "branch_tip_diverged"
  def preservation_reason(:branch_ref_oid_mismatch), do: "branch_ref_oid_mismatch"
  def preservation_reason(:unknown_branch_provenance), do: "unknown_branch_provenance"
  def preservation_reason(_), do: "branch_preserved"

  # Branch is settled; marker may be dropped. `branch_retired` records
  # whether this invocation retired the ref.
  @type branch_decision ::
          {:settle_complete, [branch_retired: boolean(), branch_preserved_reason: nil | atom()]}
          # Reused/unknown provenance: settle while preserving the pre-existing
          # branch. Marker may be dropped; the branch is not ours to delete.
          | {:settle_preserve_branch, atom()}
          # Non-retryable (divergent tip / CAS mismatch): keep a dormant
          # branch-phase discarding marker, preserve the branch, and do NOT
          # claim settlement. The marker remains as durable evidence.
          | {:dormant_preserve_branch, atom()}
          # Created branch at the expected OID: a destructive delete attempt is
          # authorized. The shell reserves retry budget before executing.
          | {:attempt_delete, String.t()}
          # Retryable observation/delete error: the shell resolves this against
          # the reserved retry budget to either schedule a retry or go dormant.
          | {:retry_branch_phase, term()}

  @doc "Normalize provenance from atom/string/nil to the closed set."
  @spec normalize_provenance(term()) :: provenance()
  def normalize_provenance(:created), do: :created
  def normalize_provenance("created"), do: :created
  def normalize_provenance(:reused), do: :reused
  def normalize_provenance("reused"), do: :reused
  def normalize_provenance(:unknown), do: :unknown
  def normalize_provenance("unknown"), do: :unknown
  def normalize_provenance(nil), do: :unknown
  def normalize_provenance(_), do: :unknown

  @doc "Normalize a discard phase from atom/string/nil."
  @spec normalize_phase(term()) :: {:ok, phase()} | :invalid
  def normalize_phase(phase) when phase in [:archive, :worktree, :branch], do: {:ok, phase}

  def normalize_phase(phase) when phase in ["archive", "worktree", "branch"],
    do: {:ok, String.to_existing_atom(phase)}

  def normalize_phase(_), do: :invalid

  @doc """
  Decide the branch-phase action from provenance and the structured exact-ref
  observation. Pure: the shell performs the git observation and passes it in.

  `expected_tip` is the exact persisted OID the invocation expects the branch
  to still point at before retirement is authorized. It is the acquisition base
  for direct discard and the separately captured settlement tip for expiry.
  """
  @spec branch_phase_decision(provenance(), ref_observation(), String.t()) :: branch_decision()
  def branch_phase_decision(provenance, observation, expected_tip) do
    expected = normalize_oid(expected_tip)

    cond do
      provenance in [:reused, :unknown] ->
        # Never delete a branch this invocation did not create. Settling here is
        # correct: the branch is pre-existing evidence, not pending work.
        {:settle_preserve_branch, :branch_provenance_not_created}

      observation == :absent ->
        {:settle_complete, branch_retired: true, branch_preserved_reason: nil}

      match?({:present, ^expected}, observation) ->
        {:attempt_delete, expected}

      match?({:present, _other}, observation) ->
        # Tip moved off the recorded base; retrying cannot converge.
        {:dormant_preserve_branch, :branch_tip_diverged}

      match?({:error, _reason}, observation) ->
        # Read failure: retryable until the budget is exhausted.
        {:retry_branch_phase, observation_error(observation)}
    end
  end

  @doc """
  Classify a `delete_branch_ref/3` outcome into a branch decision. Used by the
  shell after the destructive attempt has executed.
  """
  @spec classify_delete_outcome(:ok | {:error, term()}) :: branch_decision()
  def classify_delete_outcome(:ok),
    do: {:settle_complete, branch_retired: true, branch_preserved_reason: nil}

  def classify_delete_outcome({:error, :branch_ref_oid_mismatch}),
    do: {:dormant_preserve_branch, :branch_ref_oid_mismatch}

  def classify_delete_outcome({:error, :branch_checked_out}),
    do: {:retry_branch_phase, :branch_checked_out}

  def classify_delete_outcome({:error, :branch_checked_out_race}),
    do: {:retry_branch_phase, :branch_checked_out_race}

  def classify_delete_outcome({:error, reason}),
    do: {:retry_branch_phase, {:branch_retire_failed, reason}}

  @doc """
  Resolve a retryable branch decision against the reserved retry budget.

  `retry_count` is the count AFTER the reservation for the current cycle. When
  attempts remain, returns `{:retry, reason}` so the shell schedules a retry
  without reserving again. When the budget is exhausted, returns
  `{:dormant, reason}` so the shell keeps a dormant branch-phase marker.

  Non-retryable decisions pass through unchanged.
  """
  @spec resolve_retry(branch_decision(), non_neg_integer(), non_neg_integer()) ::
          {:retry, term()} | {:dormant, term()} | {:terminal, branch_decision()}
  def resolve_retry({:retry_branch_phase, reason}, retry_count, limit)
      when is_integer(retry_count) and is_integer(limit) do
    if retry_count >= limit do
      {:dormant, reason}
    else
      {:retry, reason}
    end
  end

  def resolve_retry(decision, _retry_count, _limit),
    do: {:terminal, decision}

  @doc """
  Pure hydration dormancy check for a discarding marker. A marker must stay
  dormant after restart when its retry budget is exhausted so a restart cannot
  regain destructive attempts. Branch-phase markers that exhausted retries or
  settled into a non-retryable preserve reason stay dormant; worktree-phase
  markers resume cleanup while budget remains.
  """
  @spec dormant_on_hydrate?(phase(), non_neg_integer(), non_neg_integer()) :: boolean()
  def dormant_on_hydrate?(:branch, retry_count, limit)
      when is_integer(retry_count) and is_integer(limit),
      do: retry_count >= limit

  def dormant_on_hydrate?(:archive, retry_count, limit)
      when is_integer(retry_count) and is_integer(limit),
      do: retry_count >= limit

  def dormant_on_hydrate?(:worktree, retry_count, limit)
      when is_integer(retry_count) and is_integer(limit),
      do: retry_count >= limit

  def dormant_on_hydrate?(_phase, _retry_count, _limit), do: true

  @doc """
  Force the durable retry count to the configured limit when settling a marker
  into a non-retryable dormant preserve state. This keeps hydration's
  `retry_count >= limit` check truthful (no further attempts are authorized)
  without adding a new durable schema field. The branch itself is preserved.
  """
  @spec force_exhausted(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def force_exhausted(retry_count, limit)
      when is_integer(retry_count) and is_integer(limit) and limit >= 0 do
    max(retry_count, limit)
  end

  @doc """
  Bind retained expiry to an exact observed tip before any archive or cleanup
  effect runs. The immutable acquisition base and worktree identity are carried
  forward unchanged; the shell persists this marker before interpreting it.
  """
  @spec begin_archive_phase(map(), String.t(), String.t()) :: map()
  def begin_archive_phase(retained, settlement_tip, runtime_id) when is_map(retained) do
    Map.merge(retained, %{
      settlement_tip: settlement_tip,
      lifecycle: :discarding,
      discard_phase: :archive,
      runtime_id: runtime_id,
      durable_lifecycle: "discarding",
      cleanup_failure: nil,
      dormant: false
    })
  end

  @doc """
  Advance an expiry settlement after its hidden evidence ref is confirmed.

  The exact captured tip and worktree identity remain bound while the shell
  moves into worktree cleanup. The shell persists this transition before it
  removes the worktree.
  """
  @spec advance_archive_to_worktree_phase(map()) :: map()
  def advance_archive_to_worktree_phase(retained) when is_map(retained) do
    retained
    |> Map.put(:lifecycle, :discarding)
    |> Map.put(:discard_phase, :worktree)
    |> Map.put(:retry_count, 0)
    |> Map.put(:cleanup_failure, nil)
    |> Map.put(:dormant, false)
  end

  @doc """
  Select the next discard phase marker from the current one after the worktree
  phase completes. Pure data transform — the shell owns persistence.
  """
  @spec advance_to_branch_phase(map()) :: map()
  def advance_to_branch_phase(retained) when is_map(retained) do
    retained
    |> Map.put(:lifecycle, :discarding)
    |> Map.put(:discard_phase, :branch)
    |> Map.put(:lstat_identity, nil)
    |> Map.put(:worktree_registration, nil)
    |> Map.put(:cleanup_failure, nil)
    |> Map.put(:dormant, false)
  end

  @doc """
  True when a durable/hot marker is mid-discard and must not be downgraded by a
  retain/remove/settle path. The shell routes such markers through the discard
  continuation so settlement always reports the in-flight discard.
  """
  @spec discarding?(map()) :: boolean()
  def discarding?(retained) when is_map(retained) do
    case Map.get(retained, :lifecycle) do
      :discarding -> true
      "discarding" -> true
      _ -> false
    end
  end

  defp normalize_oid(nil), do: nil
  defp normalize_oid(oid) when is_binary(oid), do: oid |> String.trim() |> String.downcase()

  defp observation_error({:error, reason}), do: {:observation_failed, reason}
  defp observation_error(other), do: {:observation_failed, other}

  defp string_value(map, key), do: map |> Map.get(key) || Map.get(map, Atom.to_string(key))

  defp string_or_nil(map, key),
    do: if(is_binary(value = string_value(map, key)), do: value, else: nil)

  defp boolean_value(map, key), do: string_value(map, key) == true
  defp bounded_count(value) when is_integer(value) and value >= 0 and value <= 32, do: value
  defp bounded_count(_), do: 0

  defp bounded_limit(value, _fallback) when is_integer(value) and value > 0 and value <= 32,
    do: value

  defp bounded_limit(fallback, fallback), do: max(fallback, 1)
  defp bounded_limit(_, fallback), do: max(fallback, 1)

  defp preserve_reason(map) do
    case string_value(map, :branch_preserved_reason) do
      nil -> nil
      value -> preservation_reason(value)
    end
  end

  defp normalize_phase_string(value) when value in ["archive", "worktree", "branch"], do: value

  defp normalize_phase_string(value) when value in [:archive, :worktree, :branch],
    do: Atom.to_string(value)

  defp normalize_phase_string(_), do: nil

  defp failure_category_for(reason) when is_atom(reason),
    do: Map.get(@failure_categories, reason, @failure_categories.unknown)

  defp failure_category_for(reason) when is_binary(reason) do
    if String.match?(reason, ~r/\A[a-z][a-z0-9_]{0,63}\z/),
      do: reason,
      else: @failure_categories.unknown
  end

  defp failure_category_for({tag, detail}) do
    tag_category = failure_category_for(tag)
    detail_category = failure_category_for(detail)
    if detail_category == @failure_categories.unknown, do: tag_category, else: detail_category
  end

  defp failure_category_for({tag, first, second}) do
    failure_category_for({tag, {first, second}})
  end

  defp failure_category_for(_), do: @failure_categories.unknown
end
