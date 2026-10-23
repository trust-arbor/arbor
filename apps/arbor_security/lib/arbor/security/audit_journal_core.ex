defmodule Arbor.Security.AuditJournalCore do
  @moduledoc """
  Pure CRC reducer for the v1 Security authority-mutation audit journal.

  Record fingerprints are unkeyed SHA-256 of canonical bytes. The journal
  detects accidental corruption; it is not keyed or signed, so a same-UID
  writer can rewrite entries and recompute the hashes.

  Folds admitted append records, enforces prepared -> effect_applied -> delivered
  or prepared -> effect_rejected, exact duplicate/conflict semantics, static-floor
  capacity accounting, and pure snapshot compact/restore.

  Compact occupancy is 1 (the snapshot) plus retained pending records. Terminals
  compact to fingerprints; pending records are retained in full.
  `snapshot_bytes` is a non-negative integer canonical snapshot byte size.
  Restore admits the snapshot and bounded pending records, rejects hard occupancy,
  then checks retained-set equality/order/content before installing state.

  `compaction_reclaims_occupancy?/1` is entry-based: projected occupancy is
  `1 + pending_record_count`, matching compact's `used_entries`.
  `compaction_reclaims_occupancy?/1` and `publication_relieves?/3` first
  decide from operation statuses and counts alone (O(n) in the operation
  count, no record decode) and decode the retained records only when that
  count-based projection says a publication could relieve. The count-based
  projection equals the decoded one whenever the records decode, so the
  answers are unchanged; a refusal that nothing can relieve (a no-consumer
  backlog) never pays for a decode of the hot set.

  `reserved_entries`/`reserved_bytes` hold the records every pending v2/v3
  operation has reserved for the rest of its lifecycle. They are derived
  state, maintained incrementally by every transition and recomputed once by
  compact/restore, so an admission costs O(1) in the pending count (a fold or
  publication re-fold is linear, not quadratic, under a delivery backlog).

  Terminal-identity retirement (operational profile only):
  - Every operational compaction emits a v3 snapshot carrying
    `retirement.retired_total` and the cold retirement-ledger binding. The
    binding and total live only inside `state["snapshot"]`; there are no other
    retirement keys in reducer state.
  - `compact(state, source, retire: true, ledger: next)` drops every
    `delivered` terminal from the hot set (they are recorded in the ledger by
    the file layer before the publication renames, and `next` names that
    frame); `effect_rejected` terminals and pending operations are always kept.
    `retire: false` (the default, and every small-profile compaction) keeps
    every terminal and carries the binding forward.
  - `admission_floor/1` is 3 iff the installed snapshot is v3, else 1. A new
    `prepared` whose intent version is below the floor is refused
    `:retired_version` before any capacity check, with no state change.
    Pending-manifest records installed by `restore/2` bypass the floor, so
    operations pending across the cutover complete by id.

  Compact errors: `:malformed`, `:cross_operation`, `:record_too_large`,
  `:capacity_exhausted`. Restore adds `:pending_mismatch`.

  Returns data and errors only. No effects, IO, time, processes, ETS, logging,
  signals, or store/facade calls.
  """

  alias Arbor.Security.Contracts.AuditJournal

  @version 1
  @retirement_version 3
  @compact_opts [:retire, :ledger]
  @terminals ["effect_rejected", "delivered"]
  @pending_statuses ["prepared", "effect_applied"]
  @max_pending_age_seconds 31_536_000
  @small_principal_increase_cap 8
  @operational_principal_increase_cap 128

  @type state :: %{
          required(String.t()) => term()
        }

  @type fold_error ::
          :malformed
          | :out_of_order
          | :illegal_transition
          | :post_terminal
          | :operation_conflict
          | :cross_operation
          | :record_too_large
          | :soft_capacity_exhausted
          | :capacity_exhausted
          | :retired_version
          | :pending_mismatch

  @type compact_error ::
          :malformed
          | :cross_operation
          | :record_too_large
          | :capacity_exhausted

  @type restore_error :: compact_error() | :pending_mismatch

  @spec new() :: {:ok, state()}
  def new do
    {:ok, empty_state()}
  end

  def new(:small), do: new()
  def new(:operational), do: {:ok, Map.put(empty_state(), "capacity_profile", "operational")}

  def profile(state),
    do: if(state["capacity_profile"] == "operational", do: :operational, else: :small)

  def promote_profile(state), do: Map.put(state, "capacity_profile", "operational")
  defp limits(state), do: AuditJournal.limits(profile(state))

  @spec append(term(), term()) ::
          {:ok, state()} | {:ok, state(), :idempotent} | {:error, fold_error()}
  def append(state, raw) do
    with :ok <- valid_state(state),
         {:ok, record} <- map_admit(AuditJournal.admit_record(raw)),
         {:ok, bytes} <- map_bytes(AuditJournal.canonical_record_bytes(record)) do
      transition(state, record, bytes)
    end
  rescue
    _ -> {:error, :malformed}
  catch
    _, _ -> {:error, :malformed}
  end

  @spec fold(term()) :: {:ok, state()} | {:error, fold_error()}
  def fold(records), do: fold(empty_state(), records)

  @spec fold(term(), term()) :: {:ok, state()} | {:error, fold_error()}
  def fold(state, records) do
    with :ok <- valid_state(state) do
      fold_records(state, records, 0, limits(state).max_fold_records)
    end
  end

  defp fold_records(state, [], _count, _max_records), do: {:ok, state}

  defp fold_records(_state, [_record | _tail], count, max_records)
       when count >= max_records,
       do: {:error, :malformed}

  defp fold_records(state, [record | tail], count, max_records) do
    case append(state, record) do
      {:ok, next} -> fold_records(next, tail, count + 1, max_records)
      {:ok, next, :idempotent} -> fold_records(next, tail, count + 1, max_records)
      {:error, _} = err -> err
    end
  end

  defp fold_records(_state, _improper_tail, _count, _max_records), do: {:error, :malformed}

  @doc """
  True when compacting would drop entry occupancy below the current count.

  Projected occupancy is `1 + pending_record_count` and must also fit the
  hard entry cap. Does not invent a source or call `compact/2`. The projection
  is counted from operation statuses first; the retained records are decoded
  (and must compact) only when that count says compaction could reclaim.
  """
  @spec compaction_reclaims_occupancy?(term()) :: boolean()
  def compaction_reclaims_occupancy?(state) do
    with :ok <- valid_state(state),
         true <- reclaims_entries?(state, projected_compact_entries(state["operations"])),
         {:ok, pending_ops, terminal_ops} <- partition_operations(state["operations"]),
         {:ok, _pending_manifest, pending} <- compact_pending(pending_ops),
         {:ok, _terminal_manifest, _compacted} <- compact_terminals(terminal_ops) do
      reclaims_entries?(state, 1 + length(pending))
    else
      _ -> false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  @doc """
  True when publishing a compaction now could admit the refused `raw` record.

  - Every operational publication installs a v3 snapshot (admission floor 3),
    so a refused v1/v2 `prepared` on the operational profile is never relieved:
    the single retry of that exact record would be refused `:retired_version`.
  - Otherwise, either compaction reclaims entry occupancy
    (`compaction_reclaims_occupancy?/1`, unchanged), or, on the operational
    profile, retiring `effective_retirable` delivered terminals brings the
    retained-operation dimension within the refused record's class cap
    (`soft_entry_cap` for an `authority_increase` prepared, `hard_entry_cap`
    otherwise) AND the post-publication entry dimension (the snapshot, the
    retained pending records and every pending reservation, plus the record)
    fits the same cap. Retirement frees no entries, so an entry-refused pending
    backlog is never reported as relieved just because a few delivered
    terminals are retirable.

  The caller passes `0` when the retirement ledger is paused; the value is
  clamped to `retirable_count/1`.
  """
  @spec publication_relieves?(term(), term(), term()) :: boolean()
  def publication_relieves?(state, raw, effective_retirable)
      when is_integer(effective_retirable) and effective_retirable >= 0 do
    not post_publication_floor_refuses?(state, raw) and
      (compaction_reclaims_occupancy?(state) or
         retirement_relieves?(state, raw, effective_retirable))
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  def publication_relieves?(_state, _raw, _effective_retirable), do: false

  # A capacity refusal of a `prepared` is only ever for an unknown id (known ids
  # answer :idempotent/:operation_conflict first), and an operational
  # publication always installs floor 3.
  defp post_publication_floor_refuses?(state, raw) do
    with :ok <- valid_state(state),
         :operational <- profile(state),
         {:ok, %{"record_type" => "prepared", "intent" => %{"version" => version}}}
         when is_integer(version) <- map_admit(AuditJournal.admit_record(raw)) do
      version < @retirement_version
    else
      _ -> false
    end
  end

  # Cheapest first: the retirable count and the retained-operation dimension
  # are status counts, the post-publication entry projection counts pending
  # records by status, and only a projection that fits decodes the pending
  # records (which a compaction must be able to retain) to confirm it.
  defp retirement_relieves?(state, raw, effective_retirable) do
    with :ok <- valid_state(state),
         :operational <- profile(state),
         retirable when retirable > 0 <- min(effective_retirable, retirable_count(state)),
         {:ok, record} <- map_admit(AuditJournal.admit_record(raw)),
         cap = class_cap(record, limits(state)),
         true <- map_size(state["operations"]) - retirable + new_operation_cost(record) <= cap,
         # After the publication the hot entries are exactly the snapshot plus
         # the pending records; kept terminals reserve nothing, so the
         # maintained reservation (O(1)) is the pending operations' own.
         {maintained_entries, _bytes} = prospective_reservation(state, record),
         true <- projected_compact_entries(state["operations"]) + maintained_entries + 1 <= cap,
         {:ok, pending_ops, _terminal_ops} <- partition_operations(state["operations"]),
         {:ok, _manifest, pending_records} <- compact_pending(pending_ops) do
      {reserved_entries, _bytes} =
        prospective_reservation(%{"operations" => pending_ops}, record)

      1 + length(pending_records) + reserved_entries + 1 <= cap
    else
      _ -> false
    end
  end

  # The entries a compaction keeps, from statuses alone: the snapshot plus
  # every pending operation's retained records. Equal to `1 + length(pending)`
  # from `compact_pending/1` whenever the records decode (it admits exactly the
  # records `pending_record_types/1` names), so it filters exactly.
  defp projected_compact_entries(operations) do
    Enum.reduce(operations, 1, fn
      {_id, %{"status" => status}}, acc -> acc + length(pending_record_types(status))
      {_id, _op}, acc -> acc
    end)
  end

  defp reclaims_entries?(state, projected),
    do: projected < state["entry_count"] and projected <= limits(state).hard_entry_cap

  defp new_operation_cost(%{"record_type" => "prepared"}), do: 1
  defp new_operation_cost(_record), do: 0

  defp class_cap(record, limits) do
    case capacity_class(record) do
      :soft -> limits.soft_entry_cap
      :reserve -> limits.hard_entry_cap
    end
  end

  @doc """
  Admission floor derived from the installed snapshot: 3 iff it is a v3
  snapshot, otherwise 1. Unknown prepared records below the floor are refused
  `:retired_version`.
  """
  @spec admission_floor(term()) :: 1 | 3
  def admission_floor(%{"snapshot" => %{"version" => @retirement_version}}),
    do: @retirement_version

  def admission_floor(_state), do: 1

  @doc "Delivered operations a retiring operational compaction would retire (0 on small)."
  @spec retirable_count(term()) :: non_neg_integer()
  def retirable_count(%{"operations" => operations} = state) when is_map(operations) do
    if profile(state) == :operational do
      Enum.count(operations, fn {_id, op} -> is_map(op) and op["status"] == "delivered" end)
    else
      0
    end
  end

  def retirable_count(_state), do: 0

  @doc "True when any pending operation carries an intent version below 3."
  @spec legacy_pending?(term()) :: boolean()
  def legacy_pending?(%{"operations" => operations}) when is_map(operations) do
    Enum.any?(operations, fn {_id, op} ->
      is_map(op) and op["status"] in @pending_statuses and legacy_intent?(op["intent"])
    end)
  end

  def legacy_pending?(_state), do: false

  defp legacy_intent?(%{"version" => version}) when is_integer(version),
    do: version < @retirement_version

  defp legacy_intent?(_intent), do: false

  @doc """
  The exact compact strings a retiring compaction would drop from the hot set.

  `{:ok, %{operation_id => delivered_terminal_compact}}` on the operational
  profile (empty on small). Strings are byte-identical to the terminals a
  non-retiring compaction would keep; unclassifiable operations fail closed.
  """
  @spec retirement_batch(term()) :: {:ok, map()} | {:error, compact_error()}
  def retirement_batch(state) do
    with :ok <- valid_state(state) do
      if profile(state) == :operational do
        with {:ok, _pending_ops, terminal_ops} <- partition_operations(state["operations"]),
             {:ok, retired_ops, _kept} <- split_retired(terminal_ops, true),
             {:ok, manifest, _compacted} <- compact_terminals(retired_ops) do
          {:ok, manifest}
        end
      else
        {:ok, %{}}
      end
    end
  rescue
    _ -> {:error, :malformed}
  catch
    _, _ -> {:error, :malformed}
  end

  @doc """
  Build a snapshot from reducer state and a committed source binding.

  Same as `compact(state, source, [])`: small profile emits a v1 snapshot,
  operational emits a non-retiring v3 snapshot that carries the prior
  retirement accounting forward.
  """
  @spec compact(term(), term()) ::
          {:ok, state(), map(), [map()]} | {:error, compact_error()}
  def compact(state, source), do: compact(state, source, [])

  @doc """
  Build a snapshot from reducer state, a committed source binding and options.

  Occupancy becomes 1 (the snapshot) plus retained pending records. Terminals
  compact to fingerprints. `snapshot_bytes` is a non-negative integer.

  Options (operational profile; ignored for small except validation):
  - `retire: true` drops every `delivered` terminal from the hot set and adds
    their count to `retirement.retired_total`. Default `false`.
  - `ledger: binding` the string-keyed ledger binding to install. When nothing
    retires it defaults to (and must equal) the prior binding. When at least
    one operation retires it is REQUIRED and must name exactly the next frame:
    `frames + 1`, `tip_offset` at the prior bound end
    (`AuditJournal.ledger_bound_size/1`) and a new `tip_digest` (the frame the
    file layer wrote before publication). Only a genesis prior may stay at
    genesis (explicit in-memory retirement of an ephemeral journal, which has
    no ledger); a bound journal can never retire without advancing its ledger.

  Errors: `:malformed`, `:cross_operation`, `:record_too_large`,
  `:capacity_exhausted`.
  """
  @spec compact(term(), term(), term()) ::
          {:ok, state(), map(), [map()]} | {:error, compact_error()}
  def compact(state, source, opts) do
    with :ok <- valid_state(state),
         {:ok, plan} <- retirement_plan(state, opts),
         {:ok, snapshot, pending, operations} <- build_compact_snapshot(state, source, plan),
         {:ok, snap_size} <- snapshot_occupancy_size(snapshot) do
      finish_compact(snapshot, pending, operations, snap_size)
    end
  rescue
    _ -> {:error, :malformed}
  catch
    _, _ -> {:error, :malformed}
  end

  @doc """
  Install an admitted snapshot plus retained pending records.

  Admits snapshot and bounded pending first, rejects hard occupancy, then
  checks retained-set equality, order, and content before installing state.
  Errors: `:malformed`, `:cross_operation`, `:record_too_large`,
  `:capacity_exhausted`, `:pending_mismatch`.
  """
  @spec restore(term(), term()) :: {:ok, state()} | {:error, restore_error()}
  def restore(snapshot, pending_records) do
    with {:ok, admitted} <- map_admit(AuditJournal.admit_snapshot(snapshot)),
         {:ok, snap_size} <- snapshot_occupancy_size(admitted),
         {:ok, supplied} <- admit_pending_list(pending_records),
         {:ok, used_entries, used_bytes} <- restore_occupancy(supplied, snap_size, admitted),
         :ok <- match_pending_entries(supplied, admitted) do
      finish_restore(admitted, supplied, snap_size, used_entries, used_bytes)
    end
  rescue
    _ -> {:error, :malformed}
  catch
    _, _ -> {:error, :malformed}
  end

  @spec show(state()) :: map()
  def show(state) when is_map(state) do
    operations =
      state
      |> Map.get("operations", %{})
      |> Enum.sort_by(fn {operation_id, _op} -> operation_id end)
      |> Enum.map(fn {operation_id, op} ->
        %{
          "operation_id" => operation_id,
          "status" => op["status"],
          "effect_class" => op["effect_class"],
          "intent_sha256" => operation_intent_digest(op)
        }
      end)

    %{
      "version" => @version,
      "entry_count" => Map.get(state, "entry_count", 0),
      "byte_count" => Map.get(state, "byte_count", 0),
      "operations" => operations
    }
  end

  @doc false
  def operation(state, operation_id), do: Map.fetch(state["operations"], operation_id)

  @doc false
  def pending_intents(state) do
    state["operations"]
    |> Enum.filter(fn {_id, op} -> op["status"] in @pending_statuses end)
    |> Enum.sort_by(fn {id, _op} -> id end)
    |> Enum.map(fn {_id, op} -> Map.take(op, ["intent", "status"]) end)
  end

  @doc false
  def delivery_batch(state) do
    state["operations"]
    |> Enum.filter(fn {_id, op} -> op["status"] == "effect_applied" end)
    |> Enum.sort_by(fn {id, _op} -> id end)
    |> Enum.map(fn {id, op} -> delivery_item(id, op) end)
  end

  @doc false
  def acknowledgement_matches?(state, id, digest) when is_binary(digest) do
    case operation(state, id) do
      {:ok, op} ->
        op["status"] in ["effect_applied", "delivered"] and operation_intent_digest(op) == digest

      :error ->
        false
    end
  end

  def acknowledgement_matches?(_state, _id, _digest), do: false

  defp delivery_item(id, op) do
    intent = op["intent"]
    digest = operation_intent_digest(op)

    %{
      "operation_id" => id,
      "intent_sha256" => digest,
      "event" => %{
        "id" => id,
        "stream_id" => "security:authority_mutation:" <> id,
        "type" => intent["audit"]["event_type"],
        "timestamp" => intent["prepared_at"],
        "agent_id" => intent["audit"]["data"]["principal_id"],
        "correlation_id" => intent["correlation_id"],
        "causation_id" => intent["causation_id"],
        "data" => %{"intent" => intent, "effect" => "applied"},
        "metadata" => %{"audit_source" => "security.authority_journal", "intent_sha256" => digest}
      }
    }
  end

  @spec capacity(state()) :: map()
  def capacity(state) when is_map(state), do: capacity(state, [])

  @doc """
  Capacity projection with retirement headroom.

  `retirable_operation_count` is the raw number of delivered operations the
  next retiring publication would retire; `remaining_increase_admissions` is
  `soft_entry_cap - (retained - effective_retirable)`, the retained-dimension
  headroom after that retirement.

  The effective retirable count is an explicit caller input and defaults to 0
  (conservative: headroom is only claimed when the caller knows a retiring
  publication is reachable):
  - `paused: false` — retirement is live: effective retirable = the raw count;
  - `paused: true` — the retirement ledger is paused: 0;
  - `effective_retirable: n` — `n`, clamped to `0..raw count` (ignored when
    `paused: true`).

  `reserved_entries`/`reserved_bytes` are the records every pending v2/v3
  operation has reserved for its remaining lifecycle. They are not part of
  `used_entries`, but every new admission is checked against
  `used + reserved`: an increase needs `remaining_soft_entries -
  reserved_entries >= 3` (its own prepared record plus two reserved records).

  Existing fields keep their map-size definitions so an empty queue is never
  read as capacity.
  """
  @spec capacity(state(), keyword()) :: map()
  def capacity(state, opts) when is_map(state) and is_list(opts) do
    limits = limits(state)
    used_entries = Map.get(state, "entry_count", 0)
    used_bytes = Map.get(state, "byte_count", 0)
    retained = map_size(Map.get(state, "operations", %{}))
    retirable = retirable_count(state)
    effective = effective_retirable(retirable, opts)
    retirement = AuditJournal.snapshot_retirement(Map.get(state, "snapshot"))
    {reserved_entries, reserved_bytes} = capacity_reservation(state)

    %{
      "used_entries" => used_entries,
      "used_bytes" => used_bytes,
      "hard_entry_cap" => limits.hard_entry_cap,
      "hard_byte_cap" => limits.hard_byte_cap,
      "soft_entry_cap" => limits.soft_entry_cap,
      "soft_byte_cap" => limits.soft_byte_cap,
      "reserve_entries" => limits.reserve_entries,
      "reserve_bytes" => limits.reserve_bytes,
      "retained_operation_count" => retained,
      "retained_operation_cap" => limits.hard_entry_cap,
      "retained_increase_operation_cap" => limits.soft_entry_cap,
      "remaining_retained_operations" => max(0, limits.hard_entry_cap - retained),
      "remaining_retained_increase_operations" => max(0, limits.soft_entry_cap - retained),
      "remaining_soft_entries" => max(0, limits.soft_entry_cap - used_entries),
      "remaining_soft_bytes" => max(0, limits.soft_byte_cap - used_bytes),
      "remaining_hard_entries" => max(0, limits.hard_entry_cap - used_entries),
      "remaining_hard_bytes" => max(0, limits.hard_byte_cap - used_bytes),
      "retirable_operation_count" => retirable,
      "retired_operation_total" => retirement["retired_total"],
      "retire_batch" => Map.get(limits, :retire_batch, 0),
      "remaining_increase_admissions" => max(0, limits.soft_entry_cap - (retained - effective)),
      "reserved_entries" => reserved_entries,
      "reserved_bytes" => reserved_bytes
    }
  end

  @doc """
  Readiness projection over `capacity/2` with the same `opts`: true when one
  more `authority_increase` would pass the retained, entry and soft-byte
  clauses of the admission check.

  - retained: `remaining_increase_admissions > 0`;
  - entries (exact): `remaining_soft_entries - reserved_entries >= 3`, the
    increase's own prepared record plus the two records it reserves;
  - bytes (conservative): room for a maximum-size prepared record beyond every
    reservation.

  A readiness signal only; `append/2` is always the admission decision.
  """
  @spec increase_headroom?(term(), keyword()) :: boolean()
  def increase_headroom?(state, opts \\ [])

  def increase_headroom?(state, opts) when is_map(state) and is_list(opts) do
    capacity = capacity(state, opts)

    capacity["remaining_increase_admissions"] > 0 and
      capacity["remaining_soft_entries"] - capacity["reserved_entries"] >= 3 and
      capacity["remaining_soft_bytes"] - capacity["reserved_bytes"] >=
        limits(state).max_record_bytes
  rescue
    _ -> false
  end

  def increase_headroom?(_state, _opts), do: false

  @doc false
  @spec principal_increase_admission(term(), term()) ::
          :ok | {:error, :principal_capacity_exhausted | :malformed}
  def principal_increase_admission(
        %{"operations" => operations} = state,
        %{
          "effect_class" => "authority_increase",
          "audit" => %{"data" => %{"principal_id" => principal_id}}
        }
      )
      when is_map(operations) and is_binary(principal_id) do
    cap =
      if profile(state) == :operational,
        do: @operational_principal_increase_cap,
        else: @small_principal_increase_cap

    active =
      Enum.count(operations, fn
        {_operation_id,
         %{
           "status" => status,
           "effect_class" => "authority_increase",
           "intent" => %{"audit" => %{"data" => %{"principal_id" => ^principal_id}}}
         }} ->
          status != "delivered"

        _other ->
          false
      end)

    if active < cap, do: :ok, else: {:error, :principal_capacity_exhausted}
  rescue
    _ -> {:error, :malformed}
  catch
    _, _ -> {:error, :malformed}
  end

  def principal_increase_admission(%{"operations" => operations}, %{"effect_class" => class})
      when is_map(operations) and class != "authority_increase",
      do: :ok

  def principal_increase_admission(_state, _intent), do: {:error, :malformed}

  defp capacity_reservation(%{"operations" => operations} = state) when is_map(operations) do
    reservation(state)
  rescue
    _ -> {0, 0}
  end

  defp capacity_reservation(_state), do: {0, 0}

  defp effective_retirable(retirable, opts) do
    paused = Keyword.get(opts, :paused)
    explicit = Keyword.get(opts, :effective_retirable)

    cond do
      paused == true -> 0
      is_integer(explicit) -> explicit |> max(0) |> min(retirable)
      paused == false -> retirable
      true -> 0
    end
  end

  @spec pending_summary(term(), term()) :: {:ok, map()} | {:error, :malformed}
  def pending_summary(state, now) do
    with :ok <- valid_state(state),
         {:ok, now_unix} <- unix_from_timestamp(now),
         {:ok, pending} <- pending_ops(state) do
      ages = Enum.map(pending, &pending_age(&1, now_unix))

      prepared_ages =
        pending
        |> Enum.zip(ages)
        |> Enum.flat_map(fn
          {{_id, %{"status" => "prepared"}}, age} -> [age]
          _other -> []
        end)

      if Enum.any?(ages, &(&1 == :malformed)) do
        {:error, :malformed}
      else
        {:ok,
         %{
           "pending_count" => length(pending),
           "oldest_pending_age_seconds" => Enum.max(ages, fn -> 0 end),
           "prepared_count" => length(prepared_ages),
           "oldest_prepared_age_seconds" => Enum.max(prepared_ages, fn -> 0 end),
           "operations" => project_pending(pending)
         }}
      end
    end
  rescue
    _ -> {:error, :malformed}
  catch
    _, _ -> {:error, :malformed}
  end

  defp empty_state do
    %{
      "version" => @version,
      "operations" => %{},
      "entry_count" => 0,
      "byte_count" => 0,
      "reserved_entries" => 0,
      "reserved_bytes" => 0
    }
  end

  defp valid_state(state) when is_map(state) and not is_struct(state) do
    with true <- state["version"] == @version,
         true <- Map.get(state, "capacity_profile", "small") in ["small", "operational"],
         true <- is_map(state["operations"]),
         true <- is_integer(state["entry_count"]) and state["entry_count"] >= 0,
         true <- is_integer(state["byte_count"]) and state["byte_count"] >= 0,
         :ok <- valid_reservation_fields(state),
         :ok <- valid_snapshot_fields(state) do
      :ok
    else
      _ -> {:error, :malformed}
    end
  end

  defp valid_state(_state), do: {:error, :malformed}

  # Derived reservation totals: absent (a hand-built state; derived on demand)
  # or both present as non-negative integers.
  defp valid_reservation_fields(state) do
    case {Map.fetch(state, "reserved_entries"), Map.fetch(state, "reserved_bytes")} do
      {:error, :error} ->
        :ok

      {{:ok, entries}, {:ok, bytes}}
      when is_integer(entries) and entries >= 0 and is_integer(bytes) and bytes >= 0 ->
        :ok

      _invalid ->
        {:error, :malformed}
    end
  end

  defp valid_snapshot_fields(state) do
    case Map.fetch(state, "snapshot") do
      :error ->
        :ok

      {:ok, snapshot} when is_map(snapshot) and not is_struct(snapshot) ->
        case state["snapshot_bytes"] do
          bytes when is_integer(bytes) and bytes >= 0 -> :ok
          _invalid -> {:error, :malformed}
        end

      _invalid ->
        {:error, :malformed}
    end
  end

  defp map_admit({:ok, record}), do: {:ok, record}
  defp map_admit({:error, :cross_operation}), do: {:error, :cross_operation}
  defp map_admit({:error, :record_too_large}), do: {:error, :record_too_large}
  defp map_admit({:error, _reason}), do: {:error, :malformed}

  defp map_bytes({:ok, bytes}), do: {:ok, bytes}
  defp map_bytes({:error, :record_too_large}), do: {:error, :record_too_large}
  defp map_bytes({:error, _reason}), do: {:error, :malformed}

  defp snapshot_occupancy_size(snapshot) do
    case map_bytes(AuditJournal.canonical_snapshot_bytes(snapshot)) do
      {:ok, bytes} when is_binary(bytes) ->
        size = byte_size(bytes)

        if size > AuditJournal.limits(AuditJournal.snapshot_profile(snapshot)).max_snapshot_bytes do
          {:error, :record_too_large}
        else
          {:ok, size}
        end

      {:ok, _not_binary} ->
        {:error, :malformed}

      {:error, _} = err ->
        err
    end
  end

  defp transition(state, record, bytes) do
    limits = limits(state)

    if byte_size(bytes) > limits.max_record_bytes do
      {:error, :record_too_large}
    else
      apply_transition(state, record, bytes, limits)
    end
  end

  defp apply_transition(state, record, bytes, limits) do
    operation_id = record["operation_id"]
    record_type = record["record_type"]
    operations = state["operations"]
    existing = Map.get(operations, operation_id)

    case {existing, record_type} do
      {nil, "prepared"} ->
        # The floor is evaluated before capacity: a retired-version identity is
        # an identity refusal, never a capacity error, and consumes nothing.
        with :ok <- check_floor(state, record),
             :ok <- check_capacity(state, record, bytes, limits) do
          {:ok, put_new_prepared(state, record, bytes)}
        end

      {nil, _type} ->
        {:error, :out_of_order}

      {op, _type} ->
        continue_operation(state, op, record, bytes, limits)
    end
  end

  defp check_floor(state, %{"intent" => %{"version" => version}}) when is_integer(version) do
    if version < admission_floor(state), do: {:error, :retired_version}, else: :ok
  end

  defp check_floor(_state, _record), do: {:error, :malformed}

  defp continue_operation(state, op, record, bytes, limits) do
    record_type = record["record_type"]

    case stored_identity(op, record_type, bytes) do
      :idempotent ->
        {:ok, state, :idempotent}

      :conflict ->
        {:error, :operation_conflict}

      :absent ->
        cond do
          op["status"] in @terminals ->
            {:error, :post_terminal}

          not legal_next?(op["status"], record_type) ->
            {:error, :illegal_transition}

          record_type == "effect_applied" and not after_match?(op, record) ->
            {:error, :malformed}

          true ->
            with :ok <- check_capacity(state, record, bytes, limits) do
              {:ok, put_next(state, op, record, bytes)}
            end
        end
    end
  end

  defp stored_identity(op, record_type, bytes) do
    records = Map.get(op, "records", %{})
    fingerprints = Map.get(op, "fingerprints", %{})

    cond do
      Map.has_key?(records, record_type) ->
        if records[record_type] == bytes, do: :idempotent, else: :conflict

      Map.has_key?(fingerprints, record_type) ->
        fingerprint_identity(fingerprints[record_type], bytes)

      true ->
        :absent
    end
  end

  defp fingerprint_identity(stored, bytes) do
    case AuditJournal.record_fingerprint(bytes) do
      {:ok, ^stored} -> :idempotent
      {:ok, _other} -> :conflict
      {:error, _reason} -> :conflict
    end
  end

  defp legal_next?("prepared", "effect_applied"), do: true
  defp legal_next?("prepared", "effect_rejected"), do: true
  defp legal_next?("effect_applied", "delivered"), do: true
  defp legal_next?(_status, _type), do: false

  defp after_match?(op, record) do
    op["intent"]["after_fingerprint"] === record["observation"]["after_fingerprint"]
  end

  defp check_capacity(state, record, bytes, limits) do
    {reserved_entries, reserved_bytes} = prospective_reservation(state, record)
    used_entries = state["entry_count"] + reserved_entries
    used_bytes = state["byte_count"] + reserved_bytes
    cost_bytes = byte_size(bytes)

    retained =
      map_size(state["operations"]) + if(record["record_type"] == "prepared", do: 1, else: 0)

    cond do
      cost_bytes > limits.max_record_bytes ->
        {:error, :record_too_large}

      profile(state) == :operational and retained > limits.hard_entry_cap ->
        {:error, :capacity_exhausted}

      used_entries + 1 > limits.hard_entry_cap or used_bytes + cost_bytes > limits.hard_byte_cap ->
        {:error, :capacity_exhausted}

      capacity_class(record) == :soft and
          ((profile(state) == :operational and retained > limits.soft_entry_cap) or
             used_entries + 1 > limits.soft_entry_cap or
             used_bytes + cost_bytes > limits.soft_byte_cap) ->
        {:error, :soft_capacity_exhausted}

      true ->
        :ok
    end
  end

  # V1 records retain their historical replay rules. Every newly wired mutation
  # uses V2/V3 and reserves its remaining applied+delivered (or rejected)
  # records before the authority effect. Finishing an admitted operation
  # consumes its reservation instead of spending the reduction reserve twice.
  #
  # The reservation after this transition: every other operation's remaining
  # cost (the maintained total minus the target's current share) plus the
  # target's remaining cost after it. O(1) in the pending count.
  defp prospective_reservation(state, record) do
    target = record["operation_id"]

    other =
      case Map.fetch(state["operations"], target) do
        {:ok, operation} ->
          sub_cost(reservation(state), remaining_cost(operation["intent"], operation["status"]))

        :error ->
          reservation(state)
      end

    intent =
      case record["record_type"] do
        "prepared" -> record["intent"]
        _ -> get_in(state, ["operations", target, "intent"])
      end

    add_cost(other, remaining_cost(intent, record["record_type"]))
  end

  # The maintained reservation total; derived from the operations for a state
  # built without it (a projection such as `%{"operations" => pending}`).
  defp reservation(%{"reserved_entries" => entries, "reserved_bytes" => bytes})
       when is_integer(entries) and is_integer(bytes),
       do: {entries, bytes}

  defp reservation(%{"operations" => operations}), do: reserved_cost(operations)

  defp put_reservation(state, {entries, bytes}),
    do: Map.merge(state, %{"reserved_entries" => entries, "reserved_bytes" => bytes})

  defp remaining_cost(%{"version" => version} = intent, "prepared") when version in [2, 3] do
    {applied_entries, applied_bytes} = transition_cost(intent, "effect_applied")
    {delivered_entries, delivered_bytes} = transition_cost(intent, "delivered")
    {_rejected_entries, rejected_bytes} = transition_cost(intent, "effect_rejected")
    {applied_entries + delivered_entries, max(applied_bytes + delivered_bytes, rejected_bytes)}
  end

  defp remaining_cost(%{"version" => version} = intent, "effect_applied") when version in [2, 3],
    do: transition_cost(intent, "delivered")

  defp remaining_cost(_intent, _status), do: {0, 0}

  defp transition_cost(intent, type) do
    base = %{
      "version" => 1,
      "kind" => AuditJournal.record_kind(),
      "record_type" => type,
      "operation_id" => intent["operation_id"],
      "occurred_at" => intent["prepared_at"]
    }

    record =
      case type do
        "effect_applied" ->
          Map.put(base, "observation", %{
            "kind" => "applied",
            "after_fingerprint" => intent["after_fingerprint"]
          })

        "effect_rejected" ->
          Map.put(base, "observation", %{"kind" => "rejected", "reason" => "identity_conflict"})

        "delivered" ->
          base
      end

    {:ok, bytes} = AuditJournal.canonical_record_bytes(record)
    {1, byte_size(bytes)}
  end

  defp add_cost({entries, bytes}, {more_entries, more_bytes}),
    do: {entries + more_entries, bytes + more_bytes}

  defp sub_cost({entries, bytes}, {less_entries, less_bytes}),
    do: {entries - less_entries, bytes - less_bytes}

  defp reserved_cost(operations) do
    Enum.reduce(operations, {0, 0}, fn {_id, op}, acc ->
      add_cost(acc, remaining_cost(op["intent"], op["status"]))
    end)
  end

  defp reserved_occupancy_exceeded?(operations, reserved, entries, bytes, limits) do
    {reserved_entries, reserved_bytes} = reserved

    (limits.hard_entry_cap == AuditJournal.limits(:operational).hard_entry_cap and
       map_size(operations) > limits.hard_entry_cap) or
      occupancy_exceeded?(entries + reserved_entries, bytes + reserved_bytes, limits)
  end

  defp capacity_class(%{"record_type" => "prepared", "intent" => intent}) do
    case intent["effect_class"] do
      "authority_increase" -> :soft
      _ -> :reserve
    end
  end

  defp capacity_class(_record), do: :reserve

  defp put_new_prepared(state, record, bytes) do
    intent = record["intent"]
    operation_id = record["operation_id"]

    op = %{
      "status" => "prepared",
      "effect_class" => intent["effect_class"],
      "intent" => intent,
      "records" => %{record["record_type"] => bytes}
    }

    reserved = add_cost(reservation(state), remaining_cost(intent, "prepared"))

    %{
      state
      | "operations" => Map.put(state["operations"], operation_id, op),
        "entry_count" => state["entry_count"] + 1,
        "byte_count" => state["byte_count"] + byte_size(bytes)
    }
    |> put_reservation(reserved)
  end

  defp put_next(state, op, record, bytes) do
    operation_id = record["operation_id"]
    record_type = record["record_type"]

    updated = %{
      op
      | "status" => record_type,
        "records" => Map.put(op["records"], record_type, bytes)
    }

    reserved =
      state
      |> reservation()
      |> sub_cost(remaining_cost(op["intent"], op["status"]))
      |> add_cost(remaining_cost(op["intent"], record_type))

    %{
      state
      | "operations" => Map.put(state["operations"], operation_id, updated),
        "entry_count" => state["entry_count"] + 1,
        "byte_count" => state["byte_count"] + byte_size(bytes)
    }
    |> put_reservation(reserved)
  end

  defp operation_intent_digest(%{"intent_sha256" => sha256}) when is_binary(sha256), do: sha256
  defp operation_intent_digest(%{"intent" => intent}), do: canonical_intent_digest(intent)
  defp operation_intent_digest(_op), do: String.duplicate("0", 64)

  defp canonical_intent_digest(intent) when is_map(intent) do
    case AuditJournal.canonical_intent_bytes(intent) do
      {:ok, bytes} ->
        Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

      {:error, _reason} ->
        String.duplicate("0", 64)
    end
  end

  defp canonical_intent_digest(_intent), do: String.duplicate("0", 64)

  defp retirement_plan(state, opts) do
    with {:ok, retire_opt, ledger_opt} <- compact_opts(opts) do
      retire? = retire_opt and profile(state) == :operational
      prior = AuditJournal.snapshot_retirement(Map.get(state, "snapshot"))
      retiring = if retire?, do: retirable_count(state), else: 0

      case next_ledger_binding(prior["ledger"], ledger_opt, retiring) do
        {:ok, ledger} ->
          {:ok, %{retire?: retire?, retired_total: prior["retired_total"], ledger: ledger}}

        :error ->
          {:error, :malformed}
      end
    end
  end

  defp compact_opts(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         true <- Enum.all?(Keyword.keys(opts), &(&1 in @compact_opts)),
         retire when is_boolean(retire) <- Keyword.get(opts, :retire, false),
         ledger when ledger == :carry or is_map(ledger) <- Keyword.get(opts, :ledger, :carry) do
      {:ok, retire, ledger}
    else
      _ -> {:error, :malformed}
    end
  end

  defp compact_opts(_opts), do: {:error, :malformed}

  # Ledger binding rules (the binding's shape is admitted with the snapshot):
  # - Nothing retires: the binding is carried unchanged (`ledger:` omitted or
  #   equal to the prior binding).
  # - Something retires: `ledger:` is REQUIRED, so no caller retires by
  #   default without naming where the retired compact strings went. It must
  #   name exactly the next frame, written at the prior bound end with a new
  #   tip digest. Only a genesis prior may stay at genesis (in-memory,
  #   ledgerless retirement of an ephemeral journal); once a journal is bound
  #   to a real ledger every retiring compaction must advance it.
  defp next_ledger_binding(prior, :carry, 0), do: {:ok, prior}
  defp next_ledger_binding(prior, prior, 0), do: {:ok, prior}
  defp next_ledger_binding(%{"frames" => 0} = genesis, genesis, _retiring), do: {:ok, genesis}

  defp next_ledger_binding(prior, next, retiring) when retiring > 0 and is_map(next) do
    if ledger_advances?(prior, next), do: {:ok, next}, else: :error
  end

  defp next_ledger_binding(_prior, _next, _retiring), do: :error

  defp ledger_advances?(%{"frames" => frames, "tip_digest" => digest} = prior, %{
         "frames" => next_frames,
         "tip_offset" => next_offset,
         "tip_digest" => next_digest
       })
       when is_integer(frames) do
    case AuditJournal.ledger_bound_size(prior) do
      {:ok, bound_size} ->
        next_frames == frames + 1 and next_offset == bound_size and next_digest != digest

      {:error, _} ->
        false
    end
  end

  defp ledger_advances?(_prior, _next), do: false

  defp split_retired(terminal_ops, false), do: {:ok, %{}, terminal_ops}

  defp split_retired(terminal_ops, true) do
    {retired, kept} =
      Enum.split_with(terminal_ops, fn {_id, op} -> op["status"] == "delivered" end)

    {:ok, Map.new(retired), Map.new(kept)}
  end

  defp build_compact_snapshot(state, source, plan) do
    with {:ok, pending_ops, terminal_ops} <- partition_operations(state["operations"]),
         {:ok, retired_ops, kept_ops} <- split_retired(terminal_ops, plan.retire?),
         {:ok, pending_manifest, pending_records} <- compact_pending(pending_ops),
         {:ok, terminals, compacted_terminals} <- compact_terminals(kept_ops),
         {:ok, retired, _dropped} <- compact_terminals(retired_ops) do
      snapshot = %{
        "version" => @version,
        "kind" => AuditJournal.snapshot_kind(),
        "source" => source,
        "pending_manifest" => pending_manifest,
        "terminals" => terminals
      }

      snapshot =
        if profile(state) == :operational do
          Map.merge(snapshot, %{
            "version" => @retirement_version,
            "kind" => AuditJournal.snapshot_kind(@retirement_version),
            "capacity_profile" => "operational",
            "retirement" => %{
              "retired_total" => plan.retired_total + map_size(retired),
              "ledger" => plan.ledger
            }
          })
        else
          snapshot
        end

      case map_admit(AuditJournal.admit_snapshot(snapshot)) do
        {:ok, admitted} ->
          operations = Map.merge(pending_ops, compacted_terminals)
          {:ok, admitted, pending_records, operations}

        {:error, _} = err ->
          err
      end
    end
  end

  defp finish_compact(snapshot, pending, operations, snap_size)
       when is_integer(snap_size) and snap_size >= 0 do
    limits = AuditJournal.limits(AuditJournal.snapshot_profile(snapshot))
    pending_n = length(pending)

    case sum_record_bytes(pending) do
      {:ok, pending_bytes} ->
        used_entries = 1 + pending_n
        used_bytes = snap_size + pending_bytes

        finish_compact_occupancy(
          snapshot,
          pending,
          operations,
          snap_size,
          used_entries,
          used_bytes,
          limits
        )

      {:error, _} = err ->
        err
    end
  end

  defp finish_compact(_snapshot, _pending, _operations, _snap_size), do: {:error, :malformed}

  defp finish_compact_occupancy(
         snapshot,
         pending,
         operations,
         snap_size,
         used_entries,
         used_bytes,
         limits
       ) do
    reserved = reserved_cost(operations)

    if reserved_occupancy_exceeded?(operations, reserved, used_entries, used_bytes, limits) do
      {:error, :capacity_exhausted}
    else
      next =
        put_reservation(
          %{
            "version" => @version,
            "operations" => operations,
            "entry_count" => used_entries,
            "byte_count" => used_bytes,
            "snapshot" => snapshot,
            "snapshot_bytes" => snap_size
          },
          reserved
        )

      next =
        if AuditJournal.snapshot_profile(snapshot) == :operational,
          do: promote_profile(next),
          else: next

      {:ok, next, snapshot, pending}
    end
  end

  defp sum_record_bytes(records) do
    Enum.reduce_while(records, {:ok, 0}, fn record, {:ok, acc} ->
      case AuditJournal.canonical_record_bytes(record) do
        {:ok, bytes} -> {:cont, {:ok, acc + byte_size(bytes)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp partition_operations(operations) when is_map(operations) do
    sorted = Enum.sort_by(operations, fn {operation_id, _op} -> operation_id end)

    Enum.reduce_while(sorted, {:ok, %{}, %{}}, fn {operation_id, op}, {:ok, pending, terminals} ->
      case op["status"] do
        status when status in @pending_statuses ->
          {:cont, {:ok, Map.put(pending, operation_id, op), terminals}}

        status when status in @terminals ->
          {:cont, {:ok, pending, Map.put(terminals, operation_id, op)}}

        _other ->
          {:halt, {:error, :malformed}}
      end
    end)
  end

  defp compact_pending(pending_ops) do
    result =
      pending_ops
      |> Enum.sort_by(fn {operation_id, _op} -> operation_id end)
      |> Enum.reduce_while({:ok, %{}, []}, fn {operation_id, op}, {:ok, manifest, records} ->
        case compact_pending_op(operation_id, op) do
          {:ok, compact, decoded} ->
            {:cont,
             {:ok, Map.put(manifest, operation_id, compact), Enum.reverse(decoded, records)}}

          {:error, _} = err ->
            {:halt, err}
        end
      end)

    case result do
      {:ok, manifest, records} -> {:ok, manifest, Enum.reverse(records)}
      {:error, _} = err -> err
    end
  end

  defp compact_pending_op(operation_id, op) do
    with :ok <- require_pending_shape(op),
         {:ok, decoded, fingerprints} <- decode_pending_records(operation_id, op),
         :ok <- validate_pending_lifecycle(operation_id, op, decoded),
         {:ok, compact} <- pending_compact_string(op["status"], fingerprints) do
      {:ok, compact, decoded}
    end
  end

  defp require_pending_shape(%{"intent" => intent, "records" => records} = op)
       when is_map(intent) and is_map(records) do
    required = pending_record_types(op["status"])
    stored = records |> Map.keys() |> Enum.sort()

    if stored == Enum.sort(required) and Enum.all?(required, &is_binary(records[&1])) do
      :ok
    else
      {:error, :malformed}
    end
  end

  defp require_pending_shape(_op), do: {:error, :malformed}

  defp pending_record_types("prepared"), do: ["prepared"]
  defp pending_record_types("effect_applied"), do: ["prepared", "effect_applied"]
  defp pending_record_types(_status), do: []

  defp decode_pending_records(operation_id, op) do
    types = pending_record_types(op["status"])

    case Enum.reduce_while(types, {:ok, {[], %{}}}, fn type, acc ->
           decode_pending_type(operation_id, op, type, acc)
         end) do
      {:ok, {records, fingerprints}} -> {:ok, records, fingerprints}
      {:error, _} = err -> err
    end
  end

  defp decode_pending_type(operation_id, op, type, {:ok, {records, fingerprints}}) do
    case decode_bound_record(operation_id, type, op["records"][type]) do
      {:ok, record, fingerprint} ->
        next_records = records ++ [record]
        next_fingerprints = Map.put(fingerprints, type, fingerprint)
        {:cont, {:ok, {next_records, next_fingerprints}}}

      {:error, _} = err ->
        {:halt, err}
    end
  end

  defp validate_pending_lifecycle(operation_id, op, decoded) do
    prepared = Enum.find(decoded, &(&1["record_type"] == "prepared"))

    with true <- is_map(prepared),
         :ok <- bind_decoded_record(operation_id, "prepared", prepared),
         :ok <- bind_intent(op, prepared) do
      validate_pending_status(op, prepared, decoded)
    else
      {:error, _} = err -> err
      _other -> {:error, :malformed}
    end
  end

  defp validate_pending_status(%{"status" => "prepared"}, _prepared, _decoded), do: :ok

  defp validate_pending_status(%{"status" => "effect_applied"}, prepared, decoded) do
    applied = Enum.find(decoded, &(&1["record_type"] == "effect_applied"))

    if is_map(applied) and after_match_record?(prepared, applied) do
      :ok
    else
      {:error, :malformed}
    end
  end

  defp validate_pending_status(_op, _prepared, _decoded), do: {:error, :malformed}

  defp pending_compact_string("prepared", %{"prepared" => prepared}) do
    {:ok, "prepared:" <> prepared}
  end

  defp pending_compact_string("effect_applied", %{
         "prepared" => prepared,
         "effect_applied" => applied
       }) do
    {:ok, "prepared:" <> prepared <> "|effect_applied:" <> applied}
  end

  # Invariant backstop, not a success path.
  defp pending_compact_string(_status, _fingerprints), do: {:error, :malformed}

  defp compact_terminals(terminal_ops) do
    terminal_ops
    |> Enum.sort_by(fn {operation_id, _op} -> operation_id end)
    |> Enum.reduce_while({:ok, %{}, %{}}, fn {operation_id, op}, {:ok, manifest, compacted} ->
      case compact_terminal_op(operation_id, op) do
        {:ok, compact, next_op} ->
          next_manifest = Map.put(manifest, operation_id, compact)
          next_ops = Map.put(compacted, operation_id, next_op)
          {:cont, {:ok, next_manifest, next_ops}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
  end

  defp compact_terminal_op(operation_id, op) do
    with :ok <- require_terminal_status(op),
         {:ok, fingerprints, intent_sha256} <- terminal_identity(operation_id, op),
         {:ok, compact} <-
           terminal_compact_string(
             op["status"],
             op["effect_class"],
             intent_sha256,
             fingerprints
           ) do
      next = %{
        "status" => op["status"],
        "effect_class" => op["effect_class"],
        "intent_sha256" => intent_sha256,
        "fingerprints" => fingerprints
      }

      {:ok, compact, next}
    end
  end

  defp require_terminal_status(%{"status" => status, "effect_class" => effect_class})
       when status in @terminals and
              effect_class in ["authority_increase", "authority_reduce"],
       do: :ok

  defp require_terminal_status(_op), do: {:error, :malformed}

  defp terminal_record_types("delivered"), do: ["prepared", "effect_applied", "delivered"]
  defp terminal_record_types("effect_rejected"), do: ["prepared", "effect_rejected"]
  defp terminal_record_types(_status), do: []

  defp terminal_identity(operation_id, %{"records" => records} = op) when is_map(records) do
    types = terminal_record_types(op["status"])

    with :ok <- require_exact_types(records, types),
         {:ok, decoded, fingerprints} <- decode_terminal_records(operation_id, records, types),
         :ok <- validate_terminal_lifecycle(op, decoded),
         {:ok, intent_sha256} <- prepared_intent_digest(op, decoded) do
      {:ok, fingerprints, intent_sha256}
    end
  end

  defp terminal_identity(_operation_id, %{"fingerprints" => fingerprints} = op)
       when is_map(fingerprints) do
    with :ok <- require_exact_types(fingerprints, terminal_record_types(op["status"])),
         :ok <- require_fingerprint_values(fingerprints),
         {:ok, intent_sha256} <- terminal_intent_digest(op) do
      {:ok, fingerprints, intent_sha256}
    end
  end

  defp terminal_identity(_operation_id, _op), do: {:error, :malformed}

  defp decode_terminal_records(operation_id, records, types) do
    Enum.reduce_while(types, {:ok, {%{}, %{}}}, fn type, {:ok, {decoded, fingerprints}} ->
      case decode_bound_record(operation_id, type, records[type]) do
        {:ok, record, fingerprint} ->
          next_decoded = Map.put(decoded, type, record)
          next_fingerprints = Map.put(fingerprints, type, fingerprint)
          {:cont, {:ok, {next_decoded, next_fingerprints}}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
    |> case do
      {:ok, {decoded, fingerprints}} -> {:ok, decoded, fingerprints}
      {:error, _} = err -> err
    end
  end

  defp validate_terminal_lifecycle(op, decoded) do
    prepared = decoded["prepared"]

    with true <- is_map(prepared),
         :ok <- bind_intent(op, prepared) do
      validate_terminal_status(op["status"], prepared, decoded)
    else
      {:error, _} = err -> err
      _other -> {:error, :malformed}
    end
  end

  defp validate_terminal_status("delivered", prepared, decoded) do
    applied = decoded["effect_applied"]
    delivered = decoded["delivered"]

    if is_map(applied) and is_map(delivered) and after_match_record?(prepared, applied) do
      :ok
    else
      {:error, :malformed}
    end
  end

  defp validate_terminal_status("effect_rejected", _prepared, decoded) do
    if is_map(decoded["effect_rejected"]) do
      :ok
    else
      {:error, :malformed}
    end
  end

  defp validate_terminal_status(_status, _prepared, _decoded), do: {:error, :malformed}

  defp prepared_intent_digest(op, decoded) do
    prepared = decoded["prepared"]

    with true <- is_map(prepared),
         :ok <- bind_intent(op, prepared),
         {:ok, bytes} <- AuditJournal.canonical_intent_bytes(prepared["intent"]) do
      {:ok, Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)}
    else
      {:error, _} = err -> err
      _other -> {:error, :malformed}
    end
  end

  defp require_exact_types(map, expected) when is_map(map) do
    actual = map |> Map.keys() |> Enum.sort()

    if actual == Enum.sort(expected) and Enum.all?(expected, &is_binary(Map.get(map, &1))) do
      :ok
    else
      {:error, :malformed}
    end
  end

  defp require_exact_types(_map, _expected), do: {:error, :malformed}

  defp require_fingerprint_values(fingerprints) do
    if Enum.all?(fingerprints, fn {_type, sha} -> valid_fingerprint?(sha) end) do
      :ok
    else
      {:error, :malformed}
    end
  end

  defp valid_fingerprint?(sha) when is_binary(sha) and byte_size(sha) == 64 do
    Regex.match?(~r/\A[0-9a-f]{64}\z/, sha)
  end

  defp valid_fingerprint?(_sha), do: false

  defp decode_bound_record(operation_id, type, bytes) do
    with {:ok, record, canonical} <- decode_stored_record(bytes),
         :ok <- bind_decoded_record(operation_id, type, record),
         {:ok, fingerprint} <- AuditJournal.record_fingerprint(canonical) do
      {:ok, record, fingerprint}
    end
  end

  defp bind_decoded_record(operation_id, type, record) when is_map(record) do
    cond do
      record["operation_id"] != operation_id -> {:error, :cross_operation}
      record["record_type"] != type -> {:error, :malformed}
      true -> :ok
    end
  end

  defp bind_decoded_record(_operation_id, _type, _record), do: {:error, :malformed}

  defp bind_intent(op, prepared) do
    intent = prepared["intent"]

    cond do
      not is_map(intent) -> {:error, :malformed}
      intent["effect_class"] != op["effect_class"] -> {:error, :malformed}
      true -> bind_stored_intent(op["intent"], intent)
    end
  end

  defp bind_stored_intent(stored, decoded) when is_map(stored) do
    with {:ok, left} <- AuditJournal.canonical_intent_bytes(stored),
         {:ok, right} <- AuditJournal.canonical_intent_bytes(decoded) do
      if left == right, do: :ok, else: {:error, :malformed}
    else
      {:error, _} -> {:error, :malformed}
    end
  end

  defp bind_stored_intent(nil, _decoded), do: :ok
  defp bind_stored_intent(_stored, _decoded), do: {:error, :malformed}

  defp after_match_record?(prepared, applied) do
    get_in(prepared, ["intent", "after_fingerprint"]) ===
      get_in(applied, ["observation", "after_fingerprint"])
  end

  defp terminal_intent_digest(%{"intent_sha256" => sha256})
       when is_binary(sha256) and byte_size(sha256) == 64,
       do: {:ok, sha256}

  defp terminal_intent_digest(%{"intent" => intent}) when is_map(intent) do
    case AuditJournal.canonical_intent_bytes(intent) do
      {:ok, bytes} -> {:ok, Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)}
      {:error, _reason} -> {:error, :malformed}
    end
  end

  defp terminal_intent_digest(_op), do: {:error, :malformed}

  defp terminal_compact_string(
         "delivered",
         effect_class,
         intent_sha256,
         %{
           "prepared" => prepared,
           "effect_applied" => applied,
           "delivered" => delivered
         }
       )
       when effect_class in ["authority_increase", "authority_reduce"] do
    {:ok,
     "delivered|" <>
       effect_class <>
       "|" <>
       intent_sha256 <>
       "|prepared:" <> prepared <> "|effect_applied:" <> applied <> "|delivered:" <> delivered}
  end

  defp terminal_compact_string(
         "effect_rejected",
         effect_class,
         intent_sha256,
         %{
           "prepared" => prepared,
           "effect_rejected" => rejected
         }
       )
       when effect_class in ["authority_increase", "authority_reduce"] do
    {:ok,
     "effect_rejected|" <>
       effect_class <>
       "|" <> intent_sha256 <> "|prepared:" <> prepared <> "|effect_rejected:" <> rejected}
  end

  # Invariant backstop, not a success path.
  defp terminal_compact_string(_status, _effect_class, _intent_sha256, _fingerprints),
    do: {:error, :malformed}

  defp decode_stored_record(bytes) when is_binary(bytes) do
    with {:ok, decoded} <- decode_json(bytes),
         {:ok, record} <- map_admit(AuditJournal.admit_record(decoded)),
         {:ok, canonical} <- map_bytes(AuditJournal.canonical_record_bytes(record)),
         true <- canonical == bytes do
      {:ok, record, canonical}
    else
      false -> {:error, :malformed}
      {:error, _} = err -> err
    end
  end

  defp decode_stored_record(_bytes), do: {:error, :malformed}

  defp decode_json(bytes) do
    case Jason.decode(bytes) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, :malformed}
    end
  end

  defp admit_pending_list(records) when is_list(records) do
    max = AuditJournal.limits(:operational).hard_entry_cap
    admit_pending_members(records, [], 0, max, MapSet.new())
  end

  defp admit_pending_list(_records), do: {:error, :malformed}

  defp admit_pending_members([], acc, _count, _max, _seen), do: {:ok, Enum.reverse(acc)}

  defp admit_pending_members(_records, _acc, count, max, _seen) when count >= max,
    do: {:error, :malformed}

  defp admit_pending_members([record | tail], acc, count, max, seen) do
    with {:ok, admitted} <- map_admit(AuditJournal.admit_record(record)),
         {:ok, bytes} <- map_bytes(AuditJournal.canonical_record_bytes(admitted)),
         :ok <- require_pending_type(admitted),
         {:ok, seen} <- remember_pending(seen, admitted) do
      admit_pending_members(tail, [{admitted, bytes} | acc], count + 1, max, seen)
    end
  end

  defp admit_pending_members(_improper, _acc, _count, _max, _seen), do: {:error, :malformed}

  defp require_pending_type(%{"record_type" => type}) when type in ["prepared", "effect_applied"],
    do: :ok

  defp require_pending_type(_record), do: {:error, :pending_mismatch}

  defp remember_pending(seen, record) do
    key = {record["operation_id"], record["record_type"]}

    if MapSet.member?(seen, key) do
      {:error, :pending_mismatch}
    else
      {:ok, MapSet.put(seen, key)}
    end
  end

  defp match_pending_entries(supplied, snapshot) do
    expected =
      snapshot
      |> AuditJournal.snapshot_pending_entries()
      |> Enum.map(&pending_tuple/1)

    supplied_tuples =
      Enum.map(supplied, fn {record, bytes} ->
        fingerprint =
          case AuditJournal.record_fingerprint(bytes) do
            {:ok, sha256} -> sha256
            {:error, _reason} -> nil
          end

        {record["operation_id"], record["record_type"], fingerprint}
      end)

    compare_pending_tuples(supplied_tuples, expected)
  end

  defp pending_tuple(entry) do
    {entry["operation_id"], entry["record_type"], entry["sha256"]}
  end

  defp compare_pending_tuples(supplied, expected) do
    cond do
      supplied == expected ->
        :ok

      length(supplied) != length(expected) ->
        {:error, :pending_mismatch}

      MapSet.new(supplied) == MapSet.new(expected) ->
        {:error, :pending_mismatch}

      true ->
        zip_pending_tuples(supplied, expected)
    end
  end

  defp zip_pending_tuples(supplied, expected) do
    supplied
    |> Enum.zip(expected)
    |> Enum.reduce_while(:ok, fn
      {{oid, type, sha}, {oid, type, sha}}, :ok ->
        {:cont, :ok}

      {{oid, type, _sha}, {oid, type, _other}}, :ok ->
        {:halt, {:error, :pending_mismatch}}

      {{oid, _type, _sha}, {expected_oid, _expected_type, _expected_sha}}, :ok
      when oid != expected_oid ->
        {:halt, {:error, :cross_operation}}

      {_supplied, _expected}, :ok ->
        {:halt, {:error, :pending_mismatch}}
    end)
  end

  defp occupancy_exceeded?(used_entries, used_bytes, limits) do
    used_entries > limits.hard_entry_cap or used_bytes > limits.hard_byte_cap
  end

  defp restore_occupancy(supplied, snap_size, snapshot)
       when is_integer(snap_size) and snap_size >= 0 do
    pending_bytes =
      Enum.reduce(supplied, 0, fn {_record, bytes}, acc -> acc + byte_size(bytes) end)

    used_entries = 1 + length(supplied)
    used_bytes = snap_size + pending_bytes
    limits = AuditJournal.limits(AuditJournal.snapshot_profile(snapshot))

    if occupancy_exceeded?(used_entries, used_bytes, limits) do
      {:error, :capacity_exhausted}
    else
      {:ok, used_entries, used_bytes}
    end
  end

  defp restore_occupancy(_supplied, _snap_size, _snapshot), do: {:error, :malformed}

  defp finish_restore(snapshot, supplied, snap_bytes, used_entries, used_bytes) do
    with {:ok, initial} <- new(AuditJournal.snapshot_profile(snapshot)),
         {:ok, state} <- install_terminals(initial, snapshot),
         {:ok, state} <- install_pending(state, supplied) do
      if reserved_occupancy_exceeded?(
           state["operations"],
           reservation(state),
           used_entries,
           used_bytes,
           limits(state)
         ) do
        {:error, :capacity_exhausted}
      else
        {:ok,
         state
         |> Map.put("entry_count", used_entries)
         |> Map.put("byte_count", used_bytes)
         |> Map.put("snapshot", snapshot)
         |> Map.put("snapshot_bytes", snap_bytes)}
      end
    end
  end

  defp install_terminals(state, snapshot) do
    snapshot
    |> AuditJournal.snapshot_terminal_entries()
    |> Enum.reduce_while({:ok, state}, fn entry, {:ok, acc} ->
      op = %{
        "status" => entry["status"],
        "effect_class" => entry["effect_class"],
        "intent_sha256" => entry["intent_sha256"],
        "fingerprints" => entry["fingerprints"]
      }

      next = put_in(acc, ["operations", entry["operation_id"]], op)
      {:cont, {:ok, next}}
    end)
  end

  defp install_pending(state, supplied) do
    Enum.reduce_while(supplied, {:ok, state}, fn {record, bytes}, {:ok, acc} ->
      case install_pending_record(acc, record, bytes) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp install_pending_record(state, %{"record_type" => "prepared"} = record, bytes) do
    {:ok, put_new_prepared(state, record, bytes)}
  end

  defp install_pending_record(state, %{"record_type" => "effect_applied"} = record, bytes) do
    op = Map.get(state["operations"], record["operation_id"])

    if is_map(op) and after_match?(op, record) do
      {:ok, put_next(state, op, record, bytes)}
    else
      {:error, :malformed}
    end
  end

  # Invariant backstop, not a success path.
  defp install_pending_record(_state, _record, _bytes), do: {:error, :pending_mismatch}

  defp pending_ops(state) do
    ops =
      state
      |> Map.get("operations", %{})
      |> Enum.sort_by(fn {operation_id, _op} -> operation_id end)
      |> Enum.filter(fn {_id, op} -> op["status"] in @pending_statuses end)
      |> Enum.take(AuditJournal.limits(:operational).hard_entry_cap)

    {:ok, ops}
  end

  defp project_pending(ops) do
    Enum.map(ops, fn {operation_id, op} ->
      %{
        "operation_id" => operation_id,
        "status" => op["status"],
        "effect_class" => op["effect_class"],
        "intent_sha256" => canonical_intent_digest(op["intent"])
      }
    end)
  end

  defp pending_age({_id, op}, now_unix) do
    case unix_from_timestamp(get_in(op, ["intent", "prepared_at"])) do
      {:ok, prepared_unix} ->
        diff = now_unix - prepared_unix
        age = if diff < 0, do: 0, else: diff
        min(age, @max_pending_age_seconds)

      {:error, _} ->
        :malformed
    end
  end

  defp unix_from_timestamp(
         <<year::binary-size(4), "-", month::binary-size(2), "-", day::binary-size(2), "T",
           hour::binary-size(2), ":", minute::binary-size(2), ":", second::binary-size(2), "Z">>
       ) do
    with {yi, ""} <- Integer.parse(year),
         {mo, ""} <- Integer.parse(month),
         {da, ""} <- Integer.parse(day),
         {ho, ""} <- Integer.parse(hour),
         {mi, ""} <- Integer.parse(minute),
         {se, ""} <- Integer.parse(second),
         true <- Calendar.ISO.valid_date?(yi, mo, da),
         true <- Calendar.ISO.valid_time?(ho, mi, se, {0, 0}),
         {:ok, naive} <- NaiveDateTime.new(yi, mo, da, ho, mi, se),
         {:ok, dt} <- DateTime.from_naive(naive, "Etc/UTC") do
      {:ok, DateTime.to_unix(dt)}
    else
      _ -> {:error, :malformed}
    end
  end

  defp unix_from_timestamp(_value), do: {:error, :malformed}
end
