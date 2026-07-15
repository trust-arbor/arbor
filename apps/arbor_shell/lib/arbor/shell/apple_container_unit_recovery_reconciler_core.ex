defmodule Arbor.Shell.AppleContainerUnitRecoveryReconcilerCore do
  @journal_retry_initial_ms 50
  @journal_retry_max_ms 2_000
  @worker_restart_initial_ms 50
  @worker_restart_max_ms 2_000
  # Finite exact-replay / conflict window for completed coordinator requests.
  @settled_request_ledger_limit 64

  @moduledoc """
  Pure CRC reducer for Apple Container unit-intent recovery reconciliation.

  Decides startup barrier readiness, worker admission/dedupe, receipt matching,
  journal verification follow-up, coordinator-request acceptance, and bounded
  retry timing. Returns effects as data only — the reconciler GenServer shell
  performs journal IO, starts workers, and sends completion messages.

  All functions are pure: no File/IO, GenServer, Process, Port, System time,
  randomness, Application config, Logger, or cross-library facades. Opaque
  PIDs and references may flow through as data; the core never creates them.

  Launch safety:
  - `{:start_worker, record}` is a *request* to attempt launch after the shell
    re-reads the journal and calls `authorize_launch/3`.
  - Only `{:launch_worker, record}` authorizes the impure launcher.
  - Retry/timer effects carry a generation token consumed via `consume_retry/3`.

  Settled-request ledger (finite idempotency window):
  - Before each settlement notification is emitted, the exact request kind,
    caller pid, receipt ref, and (for `recover_entry`) four-field entry
    identity are retained in a pure FIFO ledger of at most
    #{@settled_request_ledger_limit} completed requests.
  - Exact caller/ref(/identity) replay within that window returns `:ok` with
    zero effects — no journal reread, worker start, or duplicate notify.
  - Conflicting reuse of a retained receipt ref fails closed with
    `{:error, :conflicting_request_ref}`.
  - Pending requests stay in their own lists and are never ledger-evicted;
    only settled rows age out FIFO once the bound is exceeded.
  """

  alias Arbor.Shell.AppleContainerUnitJournalCore, as: JournalCore

  @logical_state_keys [
    :phase,
    :workers,
    :pending_entry_requests,
    :pending_all_requests,
    :settled_requests,
    :journal_retry_ms,
    :awaiting_journal,
    :awaiting_verify,
    :generation
  ]

  @type record :: JournalCore.record()

  @type phase :: :closed | :startup | :ready | :recovering

  @type worker :: %{
          unit_name: String.t(),
          execution_id: String.t(),
          token: String.t(),
          reserved_at_ms: non_neg_integer(),
          worker_pid: pid() | nil,
          receipt_ref: reference() | nil,
          restart_ms: pos_integer(),
          awaiting_verify: boolean()
        }

  @type entry_request :: %{
          unit_name: String.t(),
          execution_id: String.t(),
          token: String.t(),
          reserved_at_ms: non_neg_integer(),
          caller_pid: pid(),
          receipt_ref: reference()
        }

  @type all_request :: %{
          caller_pid: pid(),
          receipt_ref: reference()
        }

  @type settled_request ::
          %{
            kind: :entry,
            unit_name: String.t(),
            execution_id: String.t(),
            token: String.t(),
            reserved_at_ms: non_neg_integer(),
            caller_pid: pid(),
            receipt_ref: reference()
          }
          | %{
              kind: :all,
              caller_pid: pid(),
              receipt_ref: reference()
            }

  @type state :: %{
          phase: phase(),
          workers: %{optional(String.t()) => worker()},
          pending_entry_requests: [entry_request()],
          pending_all_requests: [all_request()],
          settled_requests: [settled_request()],
          journal_retry_ms: pos_integer(),
          awaiting_journal: boolean(),
          awaiting_verify: boolean(),
          generation: non_neg_integer()
        }

  @type retry_action ::
          :load_journal
          | :verify_settlements
          | {:start_worker, record()}

  @type effect ::
          {:load_journal}
          | {:retry_after, non_neg_integer(), retry_action(), non_neg_integer()}
          | {:start_worker, record()}
          | {:launch_worker, record()}
          | {:restart_worker_after, non_neg_integer(), record(), non_neg_integer()}
          | {:verify_settlements}
          | {:notify_entry_complete, pid(), String.t(), reference()}
          | {:notify_all_complete, pid(), reference()}

  # ---------------------------------------------------------------------------
  # Construct
  # ---------------------------------------------------------------------------

  @doc """
  Construct closed reconciler state and request the first authoritative journal load.
  """
  @spec new() :: {:ok, state(), [effect()]}
  def new do
    state = empty_state()
    {:ok, %{state | awaiting_journal: true}, [{:load_journal}]}
  end

  # ---------------------------------------------------------------------------
  # Journal load results
  # ---------------------------------------------------------------------------

  @doc """
  Apply an authoritative journal load success.

  Empty journal with no active workers reaches `:ready` (or settles pending
  coordinator requests). Non-empty entries admit unduplicated workers. A load
  error is not empty — use `apply_journal_error/2`.
  """
  @spec apply_journal_ok(state(), [term()]) ::
          {:ok, state(), [effect()]} | {:error, term()}
  def apply_journal_ok(state, entries) when is_map(state) and is_list(entries) do
    with :ok <- require_state(state),
         {:ok, records} <- normalize_entries(entries) do
      state = %{state | awaiting_journal: false, journal_retry_ms: @journal_retry_initial_ms}
      reduce_journal_snapshot(state, records)
    end
  rescue
    _ -> {:error, :invalid_journal_entries}
  end

  def apply_journal_ok(_state, _entries), do: {:error, :invalid_journal_entries}

  @doc """
  Apply journal unavailability (disabled/poisoned/transport/error).

  Never treats the journal as empty. Remains non-ready and schedules a bounded
  exponential retry of the journal load.
  """
  @spec apply_journal_error(state(), term()) ::
          {:ok, state(), [effect()]} | {:error, term()}
  def apply_journal_error(state, _reason) when is_map(state) do
    with :ok <- require_state(state) do
      delay = state.journal_retry_ms
      next_ms = next_backoff(delay, @journal_retry_max_ms)

      phase =
        case state.phase do
          p when p in [:ready, :recovering] -> p
          _ -> :closed
        end

      # Closed/startup retries reload for the startup barrier. After readiness,
      # retry verification so we never treat unavailability as an empty sweep
      # and never autonomously admit newly reserved live-unit rows.
      action =
        if phase in [:ready, :recovering] do
          :verify_settlements
        else
          :load_journal
        end

      next = %{
        state
        | phase: phase,
          awaiting_journal: action == :load_journal,
          awaiting_verify: action == :verify_settlements,
          journal_retry_ms: next_ms
      }

      {:ok, next, [{:retry_after, delay, action, state.generation}]}
    end
  end

  def apply_journal_error(_state, _reason), do: {:error, :invalid_reconciler_state}

  # ---------------------------------------------------------------------------
  # Retry consumption (timers)
  # ---------------------------------------------------------------------------

  @doc """
  Consume a generation-tagged retry/timer effect.

  Mismatched generation (including retries scheduled before a ready epoch) is
  ignored with zero effects — the shell must not poll the journal or launch.
  Matching generation re-emits the deferred work as ordinary effects so launch
  paths still pass through `authorize_launch/3`.
  """
  @spec consume_retry(state(), non_neg_integer(), retry_action()) ::
          {:ok, state(), [effect()]} | {:error, term()}
  def consume_retry(state, generation, action)
      when is_map(state) and is_integer(generation) and generation >= 0 do
    with :ok <- require_state(state) do
      if generation != state.generation do
        {:ok, state, []}
      else
        case normalize_retry_action(action) do
          {:ok, :load_journal} ->
            {:ok, %{state | awaiting_journal: true}, [{:load_journal}]}

          {:ok, :verify_settlements} ->
            {:ok, %{state | awaiting_verify: true}, [{:verify_settlements}]}

          {:ok, {:start_worker, record}} ->
            # Never launch from the timer path — re-authorize via start_worker.
            {:ok, state, [{:start_worker, record}]}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end

  def consume_retry(_state, _generation, _action), do: {:error, :invalid_retry}

  # ---------------------------------------------------------------------------
  # Launch authorization (immediately before impure start)
  # ---------------------------------------------------------------------------

  @doc """
  Authorize an imminent worker launch against a fresh authoritative journal snapshot.

  The shell must call this immediately before every launcher invocation, after
  re-reading the journal. Emits `{:launch_worker, record}` only when the exact
  identity (unit_name, token, execution_id, reserved_at_ms) is still present and
  admitted without a live worker pid. Absence or same-name replacement folds the
  snapshot through the verification transition (settle / restart / ready) and
  never authorizes launch of a stale identity.
  """
  @spec authorize_launch(state(), term(), [term()]) ::
          {:ok, state(), [effect()]} | {:error, term()}
  def authorize_launch(state, intended, entries)
      when is_map(state) and is_list(entries) do
    with :ok <- require_state(state),
         {:ok, intended_record} <- normalize_record(intended),
         {:ok, records} <- normalize_entries(entries) do
      case Map.fetch(state.workers, intended_record.unit_name) do
        :error ->
          # Not admitted — never launch, but fold the snapshot so ready/settle
          # invariants still advance from the authoritative view.
          reduce_verify_snapshot(state, records)

        {:ok, worker} ->
          if same_identity?(worker, intended_record) do
            exact_present? = Enum.any?(records, &same_identity?(&1, intended_record))

            cond do
              not exact_present? ->
                # Removed or replaced under the same unit name.
                reduce_verify_snapshot(%{state | awaiting_verify: false}, records)

              not is_nil(worker.worker_pid) ->
                # Already running for this exact identity.
                {:ok, state, []}

              true ->
                exact = Enum.find(records, &same_identity?(&1, intended_record))
                {:ok, state, [{:launch_worker, exact}]}
            end
          else
            # Intended identity does not match admitted tracking — fail closed
            # on launch, still fold journal for settlement of other work.
            reduce_verify_snapshot(state, records)
          end
      end
    end
  end

  def authorize_launch(_state, _intended, _entries), do: {:error, :invalid_launch_authorization}

  # ---------------------------------------------------------------------------
  # Worker lifecycle
  # ---------------------------------------------------------------------------

  @doc """
  Record that a recovery worker process started for an exact record identity.
  """
  @spec worker_started(state(), record(), pid(), reference()) ::
          {:ok, state(), [effect()]} | {:error, term()}
  def worker_started(state, record, worker_pid, receipt_ref)
      when is_map(state) and is_map(record) and is_pid(worker_pid) and is_reference(receipt_ref) do
    with :ok <- require_state(state),
         {:ok, normalized} <- normalize_record(record) do
      case Map.fetch(state.workers, normalized.unit_name) do
        {:ok, worker} ->
          if same_identity?(worker, normalized) do
            updated = %{
              worker
              | worker_pid: worker_pid,
                receipt_ref: receipt_ref,
                awaiting_verify: false
            }

            next = put_worker(state, updated)
            {:ok, maybe_phase(next), []}
          else
            {:error, :worker_identity_mismatch}
          end

        :error ->
          # Unexpected start without prior admission — fail closed.
          {:error, :unknown_worker_admission}
      end
    end
  end

  def worker_started(_state, _record, _worker_pid, _receipt_ref),
    do: {:error, :invalid_worker_start}

  @doc """
  Record that starting a recovery worker failed. Schedules a bounded restart.
  """
  @spec worker_start_failed(state(), record()) ::
          {:ok, state(), [effect()]} | {:error, term()}
  def worker_start_failed(state, record) when is_map(state) and is_map(record) do
    with :ok <- require_state(state),
         {:ok, normalized} <- normalize_record(record) do
      case Map.fetch(state.workers, normalized.unit_name) do
        {:ok, worker} ->
          if same_identity?(worker, normalized) do
            delay = worker.restart_ms
            next_ms = next_backoff(delay, @worker_restart_max_ms)
            updated = %{worker | worker_pid: nil, receipt_ref: nil, restart_ms: next_ms}
            next = put_worker(state, updated)

            {:ok, maybe_phase(next),
             [
               {:restart_worker_after, delay, record_from_worker(updated), state.generation}
             ]}
          else
            {:error, :worker_identity_mismatch}
          end

        :error ->
          {:error, :unknown_worker_admission}
      end
    end
  end

  def worker_start_failed(_state, _record), do: {:error, :invalid_worker_start}

  @doc """
  Match an exact worker recovery receipt.

  Forged, stale, or wrong pid/name/ref receipts are ignored (no effects).
  A match schedules authoritative journal verification before any notify.
  """
  @spec apply_worker_receipt(state(), pid(), String.t(), reference()) ::
          {:ok, state(), [effect()]} | {:error, term()}
  def apply_worker_receipt(state, worker_pid, unit_name, receipt_ref)
      when is_map(state) and is_pid(worker_pid) and is_binary(unit_name) and
             is_reference(receipt_ref) do
    with :ok <- require_state(state) do
      case find_worker_by_receipt(state, worker_pid, unit_name, receipt_ref) do
        {:ok, worker} ->
          updated = %{worker | awaiting_verify: true, worker_pid: worker_pid}
          next = put_worker(state, updated)
          next = %{next | awaiting_verify: true}
          {:ok, maybe_phase(next), [{:verify_settlements}]}

        :error ->
          # Forged/stale/wrong — never settle.
          {:ok, state, []}
      end
    end
  end

  def apply_worker_receipt(_state, _worker_pid, _unit_name, _receipt_ref),
    do: {:error, :invalid_worker_receipt}

  @doc """
  Handle worker process death before or after a receipt.

  Always schedules authoritative journal verification. Absence may settle
  (worker could complete the journal then die before the receipt was observed);
  presence restarts with bounded backoff via `apply_verify_result/2`.
  """
  @spec apply_worker_down(state(), pid()) ::
          {:ok, state(), [effect()]} | {:error, term()}
  def apply_worker_down(state, worker_pid) when is_map(state) and is_pid(worker_pid) do
    with :ok <- require_state(state) do
      case find_worker_by_pid(state, worker_pid) do
        {:ok, worker} ->
          updated = %{worker | worker_pid: nil, receipt_ref: nil, awaiting_verify: true}
          next = put_worker(state, updated)
          next = %{next | awaiting_verify: true}
          {:ok, maybe_phase(next), [{:verify_settlements}]}

        :error ->
          {:ok, state, []}
      end
    end
  end

  def apply_worker_down(_state, _worker_pid), do: {:error, :invalid_worker_down}

  # ---------------------------------------------------------------------------
  # Verification result
  # ---------------------------------------------------------------------------

  @doc """
  Apply an authoritative journal snapshot used for settlement verification.

  Entries still present keep or restart workers. Absent tracked identities
  settle entry requests only when their `worker_pid` is already `nil`
  (cleared by an exact worker DOWN). A live recovery worker retains tracking
  and pending requests so a same-name replacement cannot be admitted while
  cleanup continues. Empty journal with no workers reaches ready and
  settles all-requests. Verification unavailability is `apply_journal_error/2`.
  """
  @spec apply_verify_result(state(), [term()]) ::
          {:ok, state(), [effect()]} | {:error, term()}
  def apply_verify_result(state, entries) when is_map(state) and is_list(entries) do
    with :ok <- require_state(state),
         {:ok, records} <- normalize_entries(entries) do
      state = %{state | awaiting_verify: false, awaiting_journal: false}
      reduce_verify_snapshot(state, records)
    end
  end

  def apply_verify_result(_state, _entries), do: {:error, :invalid_journal_entries}

  # ---------------------------------------------------------------------------
  # Coordinator requests (caller already authorized by shell)
  # ---------------------------------------------------------------------------

  @doc """
  Accept a coordinator-only targeted recovery request after shell authorization.

  Requires `:ready` or `:recovering`. Validates the record, rejects identity
  mismatches against active workers, dedupes exact identities, and admits a
  start when needed. Exact caller/ref pairs are idempotent across both pending
  and settled ledger rows within the finite FIFO window; conflicting reuse of
  a receipt ref fails closed. Does not load the journal itself — for *new*
  admissions the shell must first prove the journal currently contains this
  exact record. Settled exact replay returns zero effects without journal IO.
  """
  @spec request_recover_entry(state(), term(), pid(), reference()) ::
          {:ok, state(), [effect()]} | {:error, term()}
  def request_recover_entry(state, record, caller_pid, receipt_ref)
      when is_map(state) and is_pid(caller_pid) and is_reference(receipt_ref) do
    with :ok <- require_state(state),
         :ok <- require_accepting_requests(state),
         {:ok, normalized} <- normalize_record(record) do
      case find_request_ref(state, receipt_ref) do
        {:pending_entry, existing} ->
          if existing.caller_pid == caller_pid and same_identity?(existing, normalized) do
            # Exact pending duplicate — idempotent, no duplicate work or notifies.
            {:ok, state, []}
          else
            {:error, :conflicting_request_ref}
          end

        {:settled_entry, existing} ->
          if existing.caller_pid == caller_pid and same_identity?(existing, normalized) do
            # Exact settled replay within the finite ledger window.
            {:ok, state, []}
          else
            {:error, :conflicting_request_ref}
          end

        {:pending_all, _existing} ->
          {:error, :conflicting_request_ref}

        {:settled_all, _existing} ->
          {:error, :conflicting_request_ref}

        :error ->
          admit_recover_entry(state, normalized, caller_pid, receipt_ref)
      end
    end
  end

  def request_recover_entry(_state, _record, _caller_pid, _receipt_ref),
    do: {:error, :invalid_recover_entry}

  @doc """
  Accept a coordinator-only full-journal recovery request after shell authorization.

  Requires `:ready` or `:recovering`. Emits a journal load so the shell sweeps
  the current authoritative entries; completion is deferred until a later
  empty verification with no active workers. Exact caller/ref pairs are
  idempotent across pending and settled ledger rows within the finite FIFO
  window; conflicting ref reuse fails closed.
  """
  @spec request_recover_all(state(), pid(), reference()) ::
          {:ok, state(), [effect()]} | {:error, term()}
  def request_recover_all(state, caller_pid, receipt_ref)
      when is_map(state) and is_pid(caller_pid) and is_reference(receipt_ref) do
    with :ok <- require_state(state),
         :ok <- require_accepting_requests(state) do
      case find_request_ref(state, receipt_ref) do
        {:pending_all, existing} ->
          if existing.caller_pid == caller_pid do
            {:ok, state, []}
          else
            {:error, :conflicting_request_ref}
          end

        {:settled_all, existing} ->
          if existing.caller_pid == caller_pid do
            {:ok, state, []}
          else
            {:error, :conflicting_request_ref}
          end

        {:pending_entry, _existing} ->
          {:error, :conflicting_request_ref}

        {:settled_entry, _existing} ->
          {:error, :conflicting_request_ref}

        :error ->
          request = %{caller_pid: caller_pid, receipt_ref: receipt_ref}

          next = %{
            state
            | pending_all_requests: state.pending_all_requests ++ [request],
              phase: :recovering,
              awaiting_journal: true
          }

          {:ok, next, [{:load_journal}]}
      end
    end
  end

  def request_recover_all(_state, _caller_pid, _receipt_ref),
    do: {:error, :invalid_recover_all}

  @doc """
  True when `receipt_ref` is retained in pending or settled request state.

  Used by the shell to skip journal presence proofs for exact settled/pending
  replay and conflicting ref reuse. Unknown refs still require a fresh journal
  proof before admission.
  """
  @spec known_request_ref?(state(), reference()) :: boolean()
  def known_request_ref?(state, receipt_ref)
      when is_map(state) and is_reference(receipt_ref) do
    case require_state(state) do
      :ok -> find_request_ref(state, receipt_ref) != :error
      _ -> false
    end
  end

  def known_request_ref?(_state, _receipt_ref), do: false

  @doc """
  Maximum number of completed requests retained for exact replay / conflict.
  """
  @spec settled_request_ledger_limit() :: pos_integer()
  def settled_request_ledger_limit, do: @settled_request_ledger_limit

  @doc """
  Decide whether the shell may treat the reconciler as ready for coordinator requests.
  """
  @spec ready?(state()) :: boolean()
  def ready?(state) when is_map(state) do
    case require_state(state) do
      :ok -> state.phase in [:ready, :recovering]
      _ -> false
    end
  end

  def ready?(_), do: false

  @doc """
  Bounded public status projection for the shell. Never includes records,
  tokens, execution IDs, refs, or PIDs.
  """
  @spec show(term()) :: map() | {:error, :invalid_reconciler_state}
  def show(state) do
    with :ok <- require_state(state) do
      %{
        "phase" => Atom.to_string(state.phase),
        "worker_count" => map_size(state.workers),
        "pending_entry_count" => length(state.pending_entry_requests),
        "pending_all_count" => length(state.pending_all_requests),
        "settled_request_count" => length(state.settled_requests),
        "awaiting_journal" => state.awaiting_journal == true,
        "awaiting_verify" => state.awaiting_verify == true
      }
    end
  end

  # ---------------------------------------------------------------------------
  # Journal snapshot reduction
  # ---------------------------------------------------------------------------

  defp reduce_journal_snapshot(state, records) do
    # Settle only identities whose recovery worker is already down. A live
    # worker retains the unit_name slot so same-name replacements cannot
    # race concurrent cleanup; after DOWN + still-absent, re-admit may run.
    {state, settle_effects} = settle_absent_workers(state, records)

    # Startup barrier and explicit recover_all may admit. After readiness,
    # ordinary journal reloads never sweep newly reserved live-unit rows.
    {state, start_effects} =
      if state.phase in [:closed, :startup] or state.pending_all_requests != [] do
        admit_missing_workers(state, records)
      else
        {state, []}
      end

    state = maybe_phase(state)
    {state, ready_effects} = maybe_promote_ready(state, records)

    effects = settle_effects ++ start_effects ++ ready_effects
    {:ok, state, effects}
  end

  defp reduce_verify_snapshot(state, records) do
    {state, settle_effects} = settle_absent_workers(state, records)

    # Restart workers still present that lost their process.
    {state, restart_effects} = restart_missing_processes(state, records)

    # Admit any brand-new entries only when we have pending all-requests
    # (recover_all sweep) or still in startup.
    {state, start_effects} =
      if state.phase == :startup or state.pending_all_requests != [] do
        admit_missing_workers(state, records)
      else
        # After ready, targeted recover_entry admits only the requested identity.
        # Orphan journal rows for other units are not autonomously swept.
        {state, []}
      end

    state = maybe_phase(state)
    {state, ready_effects} = maybe_promote_ready(state, records)

    effects = settle_effects ++ restart_effects ++ start_effects ++ ready_effects
    {:ok, state, effects}
  end

  defp admit_recover_entry(state, normalized, caller_pid, receipt_ref) do
    request = %{
      unit_name: normalized.unit_name,
      execution_id: normalized.execution_id,
      token: normalized.token,
      reserved_at_ms: normalized.reserved_at_ms,
      caller_pid: caller_pid,
      receipt_ref: receipt_ref
    }

    case Map.fetch(state.workers, normalized.unit_name) do
      {:ok, worker} ->
        if same_identity?(worker, normalized) do
          # Deduped: attach request; worker already running or scheduled.
          next = %{
            state
            | pending_entry_requests: state.pending_entry_requests ++ [request],
              phase: :recovering
          }

          {:ok, next, []}
        else
          {:error, :identity_mismatch}
        end

      :error ->
        worker = new_worker(normalized)
        next = put_worker(state, worker)

        next = %{
          next
          | pending_entry_requests: next.pending_entry_requests ++ [request],
            phase: :recovering
        }

        {:ok, next, [{:start_worker, normalized}]}
    end
  end

  defp admit_missing_workers(state, records) do
    Enum.reduce(records, {state, []}, fn record, {acc_state, effects} ->
      case Map.fetch(acc_state.workers, record.unit_name) do
        {:ok, worker} ->
          if same_identity?(worker, record) do
            {acc_state, effects}
          else
            # Journal identity for this name diverged — fail closed by retaining
            # the existing worker tracking and not starting the wrong record.
            # settle_absent_workers should already have cleared exact-absent
            # identities; if both exist under one name key, keep fail-closed.
            {acc_state, effects}
          end

        :error ->
          worker = new_worker(record)
          next = put_worker(acc_state, worker)
          phase = if next.phase == :ready, do: :recovering, else: startup_or_closed(next)
          next = %{next | phase: phase}
          {next, effects ++ [{:start_worker, record}]}
      end
    end)
  end

  defp startup_or_closed(%{phase: :closed}), do: :startup
  defp startup_or_closed(%{phase: :startup}), do: :startup
  defp startup_or_closed(%{phase: phase}), do: phase

  defp restart_missing_processes(state, records) do
    Enum.reduce(state.workers, {state, []}, fn {_name, worker}, {acc_state, effects} ->
      exact = Enum.find(records, &same_identity?(&1, worker))

      cond do
        is_nil(exact) ->
          {acc_state, effects}

        is_nil(worker.worker_pid) ->
          delay = worker.restart_ms
          next_ms = next_backoff(delay, @worker_restart_max_ms)
          updated = %{worker | restart_ms: next_ms, awaiting_verify: false}
          next = put_worker(acc_state, updated)

          {next,
           effects ++
             [
               {:restart_worker_after, delay, record_from_worker(updated), acc_state.generation}
             ]}

        true ->
          updated = %{worker | awaiting_verify: false}
          {put_worker(acc_state, updated), effects}
      end
    end)
  end

  defp settle_absent_workers(state, records) do
    {remaining_workers, settled_workers, settled_reqs, effects} =
      Enum.reduce(state.workers, {%{}, [], [], []}, fn {name, worker},
                                                       {keep, settled, settled_reqs_acc,
                                                        effects_acc} ->
        cond do
          Enum.any?(records, &same_identity?(&1, worker)) ->
            {Map.put(keep, name, worker), settled, settled_reqs_acc, effects_acc}

          not is_nil(worker.worker_pid) ->
            # Exact identity absent (removed or replaced under the same name)
            # but the recovery worker is still live. Retain tracking and all
            # pending requests; emit no settlement/notification. A receipt
            # without DOWN must not free the unit_name slot for a same-name
            # replacement while cleanup continues concurrently.
            {Map.put(keep, name, worker), settled, settled_reqs_acc, effects_acc}

          true ->
            # Exact identity absent and worker_pid already cleared by DOWN —
            # settle. Retain settled request identity before emitting notify
            # effects so exact post-settlement replay is idempotent within
            # the FIFO window.
            matching_reqs =
              Enum.filter(state.pending_entry_requests, &same_identity?(worker, &1))

            notify_effects =
              Enum.map(matching_reqs, fn req ->
                {:notify_entry_complete, req.caller_pid, req.unit_name, req.receipt_ref}
              end)

            ledger_rows =
              Enum.map(matching_reqs, fn req ->
                %{
                  kind: :entry,
                  unit_name: req.unit_name,
                  execution_id: req.execution_id,
                  token: req.token,
                  reserved_at_ms: req.reserved_at_ms,
                  caller_pid: req.caller_pid,
                  receipt_ref: req.receipt_ref
                }
              end)

            {keep, [worker | settled], settled_reqs_acc ++ ledger_rows,
             effects_acc ++ notify_effects}
        end
      end)

    pending_entry =
      Enum.reject(state.pending_entry_requests, fn req ->
        Enum.any?(settled_workers, &same_identity?(&1, req))
      end)

    next = %{
      state
      | workers: remaining_workers,
        pending_entry_requests: pending_entry,
        settled_requests: append_settled(state.settled_requests, settled_reqs)
    }

    {next, effects}
  end

  defp maybe_promote_ready(state, records) do
    journal_empty? = records == []
    no_workers? = map_size(state.workers) == 0

    cond do
      journal_empty? and no_workers? and not state.awaiting_journal and
          not state.awaiting_verify ->
        # Retain each recover_all request in the settled ledger before notify.
        ledger_rows =
          Enum.map(state.pending_all_requests, fn req ->
            %{
              kind: :all,
              caller_pid: req.caller_pid,
              receipt_ref: req.receipt_ref
            }
          end)

        all_effects =
          Enum.map(state.pending_all_requests, fn req ->
            {:notify_all_complete, req.caller_pid, req.receipt_ref}
          end)

        next = %{
          state
          | phase: :ready,
            pending_all_requests: [],
            settled_requests: append_settled(state.settled_requests, ledger_rows),
            journal_retry_ms: @journal_retry_initial_ms,
            generation: state.generation + 1
        }

        {next, all_effects}

      true ->
        {state, []}
    end
  end

  defp maybe_phase(state) do
    cond do
      state.phase == :closed and map_size(state.workers) > 0 ->
        %{state | phase: :startup}

      state.phase == :ready and
          (map_size(state.workers) > 0 or state.pending_entry_requests != [] or
             state.pending_all_requests != []) ->
        %{state | phase: :recovering}

      state.phase == :recovering and map_size(state.workers) == 0 and
        state.pending_entry_requests == [] and state.pending_all_requests == [] and
        not state.awaiting_journal and not state.awaiting_verify ->
        %{state | phase: :ready, generation: state.generation + 1}

      true ->
        state
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp empty_state do
    %{
      phase: :closed,
      workers: %{},
      pending_entry_requests: [],
      pending_all_requests: [],
      settled_requests: [],
      journal_retry_ms: @journal_retry_initial_ms,
      awaiting_journal: false,
      awaiting_verify: false,
      generation: 0
    }
  end

  defp require_state(
         %{
           phase: phase,
           workers: workers,
           pending_entry_requests: entry_reqs,
           pending_all_requests: all_reqs,
           settled_requests: settled_reqs,
           journal_retry_ms: retry_ms,
           awaiting_journal: awaiting_journal,
           awaiting_verify: awaiting_verify,
           generation: generation
         } = state
       )
       when phase in [:closed, :startup, :ready, :recovering] and is_map(workers) and
              is_list(entry_reqs) and is_list(all_reqs) and is_list(settled_reqs) and
              is_integer(retry_ms) and retry_ms > 0 and is_boolean(awaiting_journal) and
              is_boolean(awaiting_verify) and is_integer(generation) and generation >= 0 do
    keys = state |> Map.keys() |> MapSet.new()
    expected = MapSet.new(@logical_state_keys)

    if MapSet.equal?(keys, expected) do
      :ok
    else
      {:error, :invalid_reconciler_state}
    end
  end

  defp require_state(_), do: {:error, :invalid_reconciler_state}

  defp require_accepting_requests(%{phase: phase}) when phase in [:ready, :recovering], do: :ok
  defp require_accepting_requests(_), do: {:error, :reconciler_not_ready}

  # Pending first (never ledger-evicted), then settled FIFO window.
  defp find_request_ref(state, receipt_ref) do
    case Enum.find(state.pending_entry_requests, &(&1.receipt_ref == receipt_ref)) do
      %{} = entry ->
        {:pending_entry, entry}

      nil ->
        case Enum.find(state.pending_all_requests, &(&1.receipt_ref == receipt_ref)) do
          %{} = all ->
            {:pending_all, all}

          nil ->
            case Enum.find(state.settled_requests, &(&1.receipt_ref == receipt_ref)) do
              %{kind: :entry} = entry -> {:settled_entry, entry}
              %{kind: :all} = all -> {:settled_all, all}
              nil -> :error
            end
        end
    end
  end

  # Append completed requests newest-last; drop oldest when over the bound.
  # Pending lists are never passed through this helper.
  defp append_settled(existing, []), do: existing

  defp append_settled(existing, new_rows) when is_list(existing) and is_list(new_rows) do
    combined = existing ++ new_rows
    overflow = length(combined) - @settled_request_ledger_limit

    if overflow > 0 do
      Enum.drop(combined, overflow)
    else
      combined
    end
  end

  defp normalize_retry_action(:load_journal), do: {:ok, :load_journal}
  defp normalize_retry_action(:verify_settlements), do: {:ok, :verify_settlements}

  defp normalize_retry_action({:start_worker, record}) when is_map(record) do
    case normalize_record(record) do
      {:ok, normalized} -> {:ok, {:start_worker, normalized}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_retry_action(_), do: {:error, :invalid_retry_action}

  defp normalize_entries(entries) do
    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case normalize_record(entry) do
        {:ok, record} -> {:cont, {:ok, [record | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_record(record) when is_map(record) do
    # Route through JournalCore so schema rules stay single-sourced.
    snapshot = %{
      "schema_version" => 1,
      "generation" => 1,
      "active" => [record]
    }

    case JournalCore.new(snapshot) do
      {:ok, journal} ->
        case JournalCore.recovery_entries(journal) do
          [normalized] when is_map(normalized) ->
            {:ok, normalized}

          _other ->
            {:error, :invalid_journal_entry}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_record(_), do: {:error, :invalid_journal_entry}

  defp new_worker(record) do
    %{
      unit_name: record.unit_name,
      execution_id: record.execution_id,
      token: record.token,
      reserved_at_ms: record.reserved_at_ms,
      worker_pid: nil,
      receipt_ref: nil,
      restart_ms: @worker_restart_initial_ms,
      awaiting_verify: false
    }
  end

  defp record_from_worker(worker) do
    %{
      unit_name: worker.unit_name,
      execution_id: worker.execution_id,
      token: worker.token,
      reserved_at_ms: worker.reserved_at_ms
    }
  end

  defp put_worker(state, worker) do
    %{state | workers: Map.put(state.workers, worker.unit_name, worker)}
  end

  defp same_identity?(a, b) do
    a.unit_name == b.unit_name and a.token == b.token and a.execution_id == b.execution_id and
      a.reserved_at_ms == b.reserved_at_ms
  end

  defp find_worker_by_receipt(state, worker_pid, unit_name, receipt_ref) do
    case Map.fetch(state.workers, unit_name) do
      {:ok, worker} ->
        if worker.worker_pid == worker_pid and worker.receipt_ref == receipt_ref and
             worker.unit_name == unit_name do
          {:ok, worker}
        else
          :error
        end

      :error ->
        :error
    end
  end

  defp find_worker_by_pid(state, worker_pid) do
    case Enum.find(state.workers, fn {_name, worker} -> worker.worker_pid == worker_pid end) do
      {_name, worker} -> {:ok, worker}
      nil -> :error
    end
  end

  defp next_backoff(current, max) when is_integer(current) and is_integer(max) do
    doubled = current * 2

    if doubled > max do
      max
    else
      doubled
    end
  end
end
