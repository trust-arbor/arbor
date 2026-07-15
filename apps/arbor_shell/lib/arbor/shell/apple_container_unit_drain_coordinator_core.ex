defmodule Arbor.Shell.AppleContainerUnitDrainCoordinatorCore do
  @moduledoc """
  Pure CRC matching primitive for durable Apple Container unit drain
  reconstruction.

  A restarted named `AppleContainerUnitDrainCoordinator` must re-associate
  surviving `AppleContainerUnitWorker` processes with authoritative journal
  recovery records in O(n). Journal records are keyed by `execution_id`, while
  `Worker.ownership_info/3` requires the full exact record. This core consumes
  non-authoritative worker hints (`execution_id` only) to *propose* candidate
  pairings — it never adopts, monitors, drains, or mutates durable state.

  All functions are pure: no File/IO, GenServer, Process, Port, System,
  randomness, Application config, Logger, or cross-library facades beyond the
  pure `AppleContainerUnitJournalCore` record schema. Opaque PIDs may flow
  through as data; the core never creates or inspects live processes.

  ## Reconstruction plan is not authority

  `reconstruction_plan/2` returns a proposed partition only:

  - **verification_candidates** — each pair still requires
    `Worker.ownership_info(worker_pid, journal_record)` with the exact full
    record before monitor/adoption. A hint alone is never sufficient.
  - **orphan_records** — journal actives with no matching live worker hint;
    these require Reconciler recovery, not silent drop.
  - **unmatched_workers** — live workers whose hinted `execution_id` is absent
    from the journal snapshot; these require drain/containment handling.

  Callers must supply an actual worker/supervisor snapshot. Never treat a
  missing worker inventory or journal read failure as an empty list inside
  this core — empty inputs are valid only when the caller positively observed
  zero records or zero hints.
  """

  alias Arbor.Shell.AppleContainerUnitJournalCore, as: JournalCore

  @max_hints 1_024
  @max_records 1_024

  @allowed_hint_keys MapSet.new([:worker_pid, :execution_id])

  @type journal_record :: JournalCore.record()

  @type worker_hint :: %{
          worker_pid: pid(),
          execution_id: String.t()
        }

  @type verification_candidate :: %{
          worker_pid: pid(),
          journal_record: journal_record()
        }

  @type reconstruction_plan :: %{
          verification_candidates: [verification_candidate()],
          orphan_records: [journal_record()],
          unmatched_workers: [worker_hint()]
        }

  @doc """
  Partition authoritative journal recovery records against worker hints.

  Matches one-to-one by exact `execution_id`. Returns a deterministic plan
  sorted by journal `unit_name` (candidates and orphans) and by
  `execution_id` (unmatched workers). Fails closed with no partial plan on
  malformed, duplicate, or schema-invalid inputs.
  """
  @spec reconstruction_plan(term(), term()) ::
          {:ok, reconstruction_plan()} | {:error, term()}
  def reconstruction_plan(records, worker_hints) do
    with {:ok, normalized_records} <- normalize_records(records),
         {:ok, normalized_hints} <- normalize_hints(worker_hints) do
      {:ok, partition(normalized_records, normalized_hints)}
    end
  end

  # ---------------------------------------------------------------------------
  # Record normalization via JournalCore
  # ---------------------------------------------------------------------------

  defp normalize_records(records) when is_list(records) do
    if length(records) > @max_records do
      {:error, :too_many_records}
    else
      snapshot = %{
        schema_version: 1,
        generation: length(records),
        active: records
      }

      case JournalCore.new(snapshot) do
        {:ok, journal} -> {:ok, JournalCore.recovery_entries(journal)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp normalize_records(_), do: {:error, :invalid_records}

  # ---------------------------------------------------------------------------
  # Worker hint normalization
  # ---------------------------------------------------------------------------

  defp normalize_hints(hints) when is_list(hints) do
    if length(hints) > @max_hints do
      {:error, :too_many_worker_hints}
    else
      reduce_hints(hints, [], MapSet.new(), MapSet.new())
    end
  end

  defp normalize_hints(_), do: {:error, :invalid_worker_hints}

  defp reduce_hints([], acc, _pids, _execs) do
    {:ok, Enum.reverse(acc)}
  end

  defp reduce_hints([hint | rest], acc, seen_pids, seen_execs) do
    with {:ok, normalized} <- normalize_hint(hint),
         :ok <- reject_duplicate_pid(seen_pids, normalized.worker_pid),
         :ok <- reject_duplicate_exec(seen_execs, normalized.execution_id) do
      reduce_hints(
        rest,
        [normalized | acc],
        MapSet.put(seen_pids, normalized.worker_pid),
        MapSet.put(seen_execs, normalized.execution_id)
      )
    end
  end

  defp normalize_hint(hint) when is_map(hint) do
    with :ok <- validate_closed_hint_keys(hint),
         {:ok, pid} <- fetch_hint_pid(hint),
         {:ok, execution_id} <- fetch_hint_execution_id(hint) do
      {:ok, %{worker_pid: pid, execution_id: execution_id}}
    end
  end

  defp normalize_hint(_), do: {:error, :invalid_worker_hint}

  defp validate_closed_hint_keys(hint) when is_map(hint) do
    keys = Map.keys(hint)

    cond do
      length(keys) != 2 ->
        {:error, :invalid_worker_hint}

      not Enum.all?(keys, &(&1 in @allowed_hint_keys)) ->
        {:error, :invalid_worker_hint}

      true ->
        :ok
    end
  end

  defp fetch_hint_pid(%{worker_pid: pid}) when is_pid(pid), do: {:ok, pid}
  defp fetch_hint_pid(_), do: {:error, :invalid_worker_hint}

  defp fetch_hint_execution_id(%{execution_id: id}) when is_binary(id) do
    validate_hint_execution_id(id)
  end

  defp fetch_hint_execution_id(_), do: {:error, :invalid_worker_hint}

  defp validate_hint_execution_id(id) when is_binary(id) do
    size = byte_size(id)

    cond do
      not String.valid?(id) ->
        {:error, :invalid_execution_id}

      size < 1 or size > 256 ->
        {:error, :invalid_execution_id}

      String.contains?(id, ["/", "\\", <<0>>]) ->
        {:error, :invalid_execution_id}

      has_control_char?(id) or has_whitespace?(id) ->
        {:error, :invalid_execution_id}

      true ->
        {:ok, id}
    end
  end

  defp reject_duplicate_pid(seen, pid) do
    if MapSet.member?(seen, pid) do
      {:error, :duplicate_worker_pid}
    else
      :ok
    end
  end

  defp reject_duplicate_exec(seen, exec_id) do
    if MapSet.member?(seen, exec_id) do
      {:error, :duplicate_hint_execution_id}
    else
      :ok
    end
  end

  defp has_control_char?(value), do: has_control_char_bytes?(value)

  defp has_control_char_bytes?(<<>>), do: false
  defp has_control_char_bytes?(<<c, _rest::binary>>) when c < 32 or c == 127, do: true
  defp has_control_char_bytes?(<<_c, rest::binary>>), do: has_control_char_bytes?(rest)

  defp has_whitespace?(value) do
    :binary.match(value, [" ", "\t", "\n", "\r", "\f", "\v"]) != :nomatch or
      String.match?(value, ~r/[[:space:]]/)
  end

  # ---------------------------------------------------------------------------
  # Partition
  # ---------------------------------------------------------------------------

  defp partition(records, hints) do
    by_execution =
      Map.new(records, fn record ->
        {record.execution_id, record}
      end)

    {candidates, unmatched, matched_execs} =
      Enum.reduce(hints, {[], [], MapSet.new()}, fn hint, {cands, unm, matched} ->
        case Map.fetch(by_execution, hint.execution_id) do
          {:ok, record} ->
            candidate = %{worker_pid: hint.worker_pid, journal_record: record}

            {[candidate | cands], unm, MapSet.put(matched, hint.execution_id)}

          :error ->
            {cands, [hint | unm], matched}
        end
      end)

    orphans =
      Enum.reject(records, fn record ->
        MapSet.member?(matched_execs, record.execution_id)
      end)

    %{
      verification_candidates: sort_candidates(candidates),
      orphan_records: sort_records(orphans),
      unmatched_workers: sort_unmatched(unmatched)
    }
  end

  defp sort_candidates(candidates) do
    Enum.sort_by(candidates, fn %{journal_record: record} -> record.unit_name end, &<=/2)
  end

  defp sort_records(records) do
    Enum.sort_by(records, & &1.unit_name, &<=/2)
  end

  defp sort_unmatched(workers) do
    Enum.sort_by(workers, & &1.execution_id, &<=/2)
  end
end
