defmodule Arbor.Security.AuditJournalFile do
  @moduledoc """
  Imperative append-and-sync file log for v1 Security authority-mutation records.

  Binds a regular single-link 0600 file under a caller-supplied canonical
  Security root, replays frames through `Arbor.Security.AuditJournalFileCore`,
  and acknowledges an append only after a complete frame is written, file-synced,
  and post-sync fstat-proven.

  Compaction publishes a snapshot-plus-pending candidate in the same directory,
  file-syncs it, proves it, re-proves the source identity and tip, then
  atomically renames. Directory-entry finalize keeps the existing node-restart
  durability claim when directory fsync is known-unsupported.

  Retirement (operational profile, `compact(handle, retire: true)` and
  `ensure_retirement_current/1`): delivered terminals leave the hot snapshot
  only inside a checked publication. Whether a publication retires is decided
  purely before any IO (`retire:` requested, operational profile, and a
  ledger posture of `:absent | :bound | :bound_orphan`); the retired compact
  strings are written as one frame of the cold retirement ledger
  (`Arbor.Security.AuditRetirementLedger`) in the `:ledger_append` phase,
  after the candidate proofs and before the source-tip proof and rename, and
  the v3 snapshot binds that frame. A transient ledger write failure is
  `{:not_published, :ledger_write_failed}` with nothing retired. A paused
  ledger (`:mismatch | :ahead`) makes every publication non-retiring; it is
  never a reason to refuse one. That includes a ledger an append proves
  inconsistent with its binding on a live handle (for example foreign bytes
  beyond the bound): the handle pauses exactly as a restart would classify
  it and the same publication runs non-retiring. Promotion
  (`ensure_capacity_profile/2`) never retires. The ledger posture is
  computed at open and after every adopted publication; the ledger tip is
  adopted only from the replayed published snapshot.

  Not a GenServer and not a generic store. Single-writer is assumed, not
  enforced. Does not claim hostile same-UID tamper resistance, host power-loss
  durability, or distributed linearizability.
  """

  import Arbor.Security.AuditJournalFileProofs

  alias Arbor.Common.SafePath
  alias Arbor.Security.AuditJournalCore
  alias Arbor.Security.AuditJournalFileCore
  alias Arbor.Security.AuditRetirementLedger
  alias Arbor.Security.AuditRetirementLedgerCore
  alias Arbor.Security.Contracts.AuditJournal

  @allowed_opts [:root, :path]
  @default_name "audit_journal.v1.log"

  defstruct [
    :fd,
    :root,
    :path,
    :identity,
    :core,
    :digest,
    :offset,
    :frames,
    :file_size,
    :torn_tail,
    :ledger,
    closed?: false
  ]

  @type identity :: %{
          major_device: non_neg_integer(),
          minor_device: non_neg_integer(),
          inode: non_neg_integer(),
          uid: non_neg_integer(),
          gid: non_neg_integer(),
          mode: non_neg_integer(),
          links: pos_integer(),
          size: non_neg_integer()
        }

  @type t :: %__MODULE__{
          fd: :file.io_device() | nil,
          root: String.t(),
          path: String.t(),
          identity: identity(),
          core: AuditJournalCore.state(),
          digest: binary(),
          offset: non_neg_integer(),
          frames: non_neg_integer(),
          file_size: non_neg_integer(),
          torn_tail: AuditJournalFileCore.torn_tail(),
          ledger: AuditRetirementLedger.t() | nil,
          closed?: boolean()
        }

  @type not_published_reason ::
          :torn_tail
          | :malformed
          | :cross_operation
          | :record_too_large
          | :capacity_exhausted
          | :identity_changed
          | :size_mismatch
          | :digest_mismatch
          | :symlink_rejected
          | :hardlink_rejected
          | :insecure_mode
          | :not_regular
          | :path_escape
          | :parent_missing
          | :candidate_exists
          | :write_failed
          | :sync_failed
          | :candidate_proof_failed
          | :source_tip_mismatch
          | :log_too_large
          | :non_canonical
          | :pending_mismatch
          | :snapshot_not_first
          | :core_mismatch
          | :ledger_write_failed

  @type publish_uncertain_reason ::
          :rename_ambiguous
          | :dir_sync_failed
          | :reopen_failed
          | :replay_mismatch
          | :identity_changed
          | :size_mismatch
          | :digest_mismatch
          | :insecure_mode
          | :not_regular
          | :hardlink_rejected
          | :symlink_rejected
          | :core_mismatch

  @type source_invalid_reason ::
          :identity_changed
          | :size_mismatch
          | :digest_mismatch
          | :source_tip_mismatch
          | :core_mismatch
          | :insecure_mode
          | :not_regular
          | :hardlink_rejected
          | :symlink_rejected

  @spec open(keyword()) :: {:ok, t()} | {:error, term()}
  def open(opts) when is_list(opts) do
    with :ok <- reject_unknown_opts(opts),
         {:ok, root} <- fetch_root(opts),
         {:ok, root} <- validate_root(root),
         {:ok, path} <- resolve_file_path(root, opts),
         :ok <- refuse_ledger_name(path),
         {:ok, path} <- contained_in_root(path, root),
         {:ok, _parent} <- validate_parent(path, root),
         {:ok, fd, identity} <- open_target(path, root) do
      finish_open(fd, root, path, identity)
    end
  end

  def open(_opts), do: {:error, :invalid_opts}

  @spec close(t()) :: :ok
  def close(%__MODULE__{fd: fd, closed?: false} = handle) when not is_nil(fd) do
    _ = close_io_silent(fd)
    AuditRetirementLedger.close(handle.ledger)
  end

  def close(%__MODULE__{}), do: :ok
  def close(_handle), do: :ok

  @spec evidence(t()) :: map()
  def evidence(%__MODULE__{} = handle) do
    %{
      committed_offset: handle.offset,
      committed_digest: handle.digest,
      committed_frames: handle.frames,
      file_size: handle.file_size,
      torn_tail: handle.torn_tail
    }
  end

  @spec append(t(), term()) ::
          {:ok, t()}
          | {:ok, t(), :idempotent}
          | {:error, {:not_committed, term()}}
          | {:error, {:commit_uncertain, term()}}
          | {:error, term()}
  def append(%__MODULE__{closed?: true}, _raw), do: {:error, :closed}

  def append(%__MODULE__{} = handle, raw) do
    with :ok <- require_no_torn_tail(handle),
         :ok <- revalidate_identity(handle),
         {:ok, record, bytes} <- admit_canonical(raw) do
      append_admitted(handle, record, bytes)
    else
      {:error, {:not_committed, _reason}} = err ->
        invalidate(handle)
        err

      {:error, reason} ->
        {:error, reason}
    end
  end

  def append(_handle, _raw), do: {:error, :closed}

  @doc """
  Publishes a snapshot-plus-pending replacement of the bound log.

  Options:
  - `retire: true` — on the operational profile, retire every delivered
    terminal into one cold ledger frame written before the rename. Honoured
    only when the ledger posture is `:absent | :bound | :bound_orphan`; under
    a paused ledger (`:mismatch | :ahead`) the publication runs non-retiring.
    Default `false` (every terminal stays hot).

  Result classes:
  - `{:ok, handle}` — candidate renamed and rebound
  - `{:error, :closed}` — handle is closed or not a live file handle
  - `{:error, {:not_published, reason}}` — rename did not occur; source is intact
    (`:ledger_write_failed` when the retirement frame could not be written
    because of a transient fault; nothing is retired). When the failed append
    proves the ledger inconsistent with its binding instead, the handle's
    ledger pauses and the publication runs non-retiring (`{:ok, handle}` with
    `ledger_state/1` `:mismatch | :ahead`).
  - `{:error, {:source_invalid, reason}}` — source identity or tip was lost before rename
  - `{:error, {:publish_uncertain, reason}}` — rename or post-rename proof is ambiguous
  """
  @spec compact(t(), keyword()) ::
          {:ok, t()}
          | {:error, :closed}
          | {:error, {:not_published, not_published_reason()}}
          | {:error, {:source_invalid, source_invalid_reason()}}
          | {:error, {:publish_uncertain, publish_uncertain_reason()}}
  def compact(handle, opts \\ [])

  def compact(%__MODULE__{closed?: true}, _opts), do: {:error, :closed}

  def compact(%__MODULE__{} = handle, opts) do
    case admit_compact(handle, :current, opts) do
      {:ok, ctx} ->
        handle
        |> publish_compacted(ctx)
        |> pause_after_ledger_fault(handle, ctx)

      {:error, :closed} = err ->
        err

      {:error, reason} ->
        publish_error(handle, nil, nil, :admit, reason)
    end
  end

  def compact(_handle, _opts), do: {:error, :closed}

  @doc """
  Boot-time retirement (T1): publish a retiring compaction when the handle
  has no torn tail, is operational, and either its snapshot predates v3
  (admission floor below 3) or at least `retire_batch` delivered terminals
  are retirable. Under a paused ledger the publication still runs,
  non-retiring: a pre-v3 snapshot is replaced by a v3 snapshot and the
  delivered terminals are kept hot (full records compacted to
  fingerprints, which relieves entry occupancy).

  Never raises. Returns:
  - `{:ok, handle}` — published (new handle) or nothing to do (same handle)
  - `{:not_published, reason, handle}` — nothing changed; the original handle
    is still live
  - `{:uncertain, reason}` — `{:publish_uncertain, r}`, `{:source_invalid, r}`
    or `:closed`; the original handle must not be used again
  """
  @spec ensure_retirement_current(t()) ::
          {:ok, t()}
          | {:not_published, not_published_reason(), t()}
          | {:uncertain, term()}
  def ensure_retirement_current(%__MODULE__{closed?: false, fd: fd} = handle)
      when not is_nil(fd) do
    if retirement_due?(handle) do
      handle
      |> compact(retire: true)
      |> retirement_result(handle)
    else
      {:ok, handle}
    end
  rescue
    _ -> {:uncertain, :exception}
  catch
    _, _ -> {:uncertain, :exception}
  end

  def ensure_retirement_current(_handle), do: {:uncertain, :closed}

  @doc """
  Ledger posture of a handle: `:absent | :bound | :bound_orphan | :mismatch |
  :ahead`.

  Computed at open and after every adopted publication (and paused by a
  publication whose append proved the ledger inconsistent). A publication
  that ends `{:not_published, _}` returns no handle, so the kept handle
  reports the posture of its last open or adopted publication: after an
  unpublished attempt that left an orphan frame, an `:absent` handle still
  reports `:absent` while a restart over the same bytes reports
  `:bound_orphan`. Both are retiring postures and the next retiring append
  re-classifies the bytes beyond the bound before it writes.
  """
  @spec ledger_state(t()) :: AuditRetirementLedgerCore.posture()
  def ledger_state(%__MODULE__{ledger: %AuditRetirementLedger{state: state}}), do: state
  def ledger_state(%__MODULE__{}), do: :mismatch

  @doc false
  def ensure_capacity_profile(%__MODULE__{} = handle, profile)
      when profile in [:small, :operational] do
    case {AuditJournalCore.profile(handle.core), profile} do
      {same, same} ->
        {:ok, handle}

      {:small, :operational} ->
        # Promotion is never retiring: it keeps every terminal hot and never
        # touches the retirement ledger, so its fatal-on-failure posture can
        # never be reached through a cold-file fault.
        result =
          case admit_compact(handle, :operational, retire: false) do
            {:ok, ctx} -> publish_compacted(handle, ctx)
            {:error, reason} -> publish_error(handle, nil, nil, :admit, reason)
          end

        if not match?({:ok, _}, result), do: close(handle)
        result

      _ ->
        close(handle)
        {:error, :capacity_profile_mismatch}
    end
  end

  if Mix.env() == :test do
    @inject_key {__MODULE__, :inject}

    @doc false
    @spec __test_inject__(:clear) :: :ok
    def __test_inject__(:clear) do
      Process.delete(@inject_key)
      AuditRetirementLedger.__test_inject__(:clear)
    end

    @doc false
    @spec __test_inject__(
            :compact_rewrite_source_same_size
            | :compact_replace_source_inode
            | :compact_substitute_candidate
            | :compact_rename_before_effect
            | :compact_rename_after_effect
            | :ledger_truncate_below_bound
          ) :: :ok
    def __test_inject__(kind)
        when kind in [
               :compact_rewrite_source_same_size,
               :compact_replace_source_inode,
               :compact_substitute_candidate,
               :compact_rename_before_effect,
               :compact_rename_after_effect
             ] do
      put_inject(kind, true)
    end

    # The retirement-ledger append truncates one byte below the bound (then
    # fails its post-truncate size proof), leaving a ledger shorter than the
    # durable binding: the next open classifies it `:mismatch`.
    def __test_inject__(:ledger_truncate_below_bound) do
      AuditRetirementLedger.__test_inject__(:ledger_truncate_below_bound, true)
    end

    # :ledger_create_chmod — the chmod after the ledger's exclusive create does
    # not take (the file keeps a group/other mode) and reports `value`.
    # :ledger_inspect_error — reading an existing ledger for classification
    # fails with `value` (a transient IO fault).
    # :ledger_append_delay — the ledger phase of a retiring publication sleeps
    # `value` milliseconds before it writes (a slow publication).
    @doc false
    @spec __test_inject__(
            :ledger_write_error
            | :ledger_dir_sync
            | :ledger_create_chmod
            | :ledger_inspect_error
            | :ledger_append_delay,
            term()
          ) :: :ok
    def __test_inject__(kind, value)
        when kind in [
               :ledger_write_error,
               :ledger_dir_sync,
               :ledger_create_chmod,
               :ledger_inspect_error,
               :ledger_append_delay
             ] do
      AuditRetirementLedger.__test_inject__(kind, value)
    end

    @doc false
    @spec __test_inject__(:write_error, term()) :: :ok
    def __test_inject__(:write_error, reason) do
      put_inject(:write_error, reason)
    end

    @doc false
    @spec __test_inject__(:sync_error, term()) :: :ok
    def __test_inject__(:sync_error, reason) do
      put_inject(:sync_error, reason)
    end

    @doc false
    @spec __test_inject__(:partial_write, non_neg_integer()) :: :ok
    def __test_inject__(:partial_write, byte_count)
        when is_integer(byte_count) and byte_count >= 0 do
      put_inject(:partial_write, byte_count)
    end

    @doc false
    @spec __test_inject__(:post_sync_proof_error, term()) :: :ok
    def __test_inject__(:post_sync_proof_error, reason) do
      put_inject(:post_sync_proof_error, reason)
    end

    @doc false
    @spec __test_inject__(:post_sync_chmod, non_neg_integer()) :: :ok
    def __test_inject__(:post_sync_chmod, mode) when is_integer(mode) do
      put_inject(:post_sync_chmod, mode)
    end

    @doc false
    @spec __test_inject__(:post_sync_lstat_minor_device_delta, integer()) :: :ok
    def __test_inject__(:post_sync_lstat_minor_device_delta, delta)
        when is_integer(delta) and delta != 0 do
      put_inject(:post_sync_lstat_minor_device_delta, delta)
    end

    @doc false
    @spec __test_inject__(:compact_sync_error, term()) :: :ok
    def __test_inject__(:compact_sync_error, reason) do
      put_inject(:compact_sync_error, reason)
    end

    @doc false
    @spec __test_inject__(:compact_after_sync_error, term()) :: :ok
    def __test_inject__(:compact_after_sync_error, reason) do
      put_inject(:compact_after_sync_error, reason)
    end

    @doc false
    @spec __test_inject__(:compact_dir_sync, term()) :: :ok
    def __test_inject__(:compact_dir_sync, result) do
      put_inject(:compact_dir_sync, result)
    end

    @doc false
    @spec __test_inject__(:compact_reopen_error, term()) :: :ok
    def __test_inject__(:compact_reopen_error, reason) do
      put_inject(:compact_reopen_error, reason)
    end

    @doc false
    @spec __test_inject__(:compact_replay_error, term()) :: :ok
    def __test_inject__(:compact_replay_error, reason) do
      put_inject(:compact_replay_error, reason)
    end

    defp put_inject(key, value) do
      current = Process.get(@inject_key, %{})
      Process.put(@inject_key, Map.put(current, key, value))
      :ok
    end

    @spec inject(atom()) :: term()
    defp inject(key) do
      Process.get(@inject_key, %{}) |> Map.get(key, :absent)
    end
  end

  # Pure admission of one publication (no IO beyond the existing source
  # revalidation): whether it retires, the retirement batch, the ledger frame
  # and the exact candidate bytes are all decided here, before any write.
  defp admit_compact(%__MODULE__{} = handle, profile, opts) do
    core =
      if profile == :operational,
        do: AuditJournalCore.promote_profile(handle.core),
        else: handle.core

    with {:ok, retire_requested?} <- compact_retire_opt(opts),
         :ok <- require_compact_no_torn(handle),
         :ok <- compact_revalidate(handle),
         {:ok, source} <-
           AuditJournalFileCore.source_binding(handle.digest, handle.frames, handle.offset),
         {:ok, plan} <- retirement_plan(handle, core, source, retire_requested?),
         {:ok, compacted, snapshot, pending} <- compact_reducer(core, source, plan.compact_opts),
         :ok <- require_retired_accounting(core, snapshot, plan.retired),
         {:ok, bytes, expected} <- AuditJournalFileCore.encode_compacted(snapshot, pending) do
      {:ok,
       %{
         source: source,
         compacted: compacted,
         bytes: bytes,
         expected: expected,
         ledger_frame: plan.framed,
         retired: plan.retired,
         ledger_written: nil
       }}
    end
  end

  defp compact_retire_opt(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         [] <- Keyword.keys(opts) -- [:retire],
         retire when is_boolean(retire) <- Keyword.get(opts, :retire, false) do
      {:ok, retire}
    else
      _ -> {:error, :malformed}
    end
  end

  defp compact_retire_opt(_opts), do: {:error, :malformed}

  # retire? = requested AND operational AND the ledger posture allows it.
  # A paused ledger (:mismatch | :ahead) makes the publication non-retiring;
  # it never refuses it. The frame chains from the binding the handle adopted
  # from its replayed published snapshot; the core refuses any other tip.
  defp retirement_plan(handle, core, source, retire_requested?) do
    retire? =
      retire_requested? and AuditJournalCore.profile(core) == :operational and
        AuditRetirementLedgerCore.retiring_allowed?(ledger_state(handle))

    if retire? do
      with {:ok, retired} <- AuditJournalCore.retirement_batch(core) do
        plan_retirement(retired, source, handle.ledger.binding)
      end
    else
      {:ok, non_retiring_plan()}
    end
  end

  defp plan_retirement(retired, _source, _bound) when map_size(retired) == 0,
    do: {:ok, non_retiring_plan()}

  defp plan_retirement(retired, source, bound) do
    case AuditRetirementLedgerCore.frame(retired, source, bound) do
      {:ok, framed} ->
        {:ok,
         %{
           compact_opts: [retire: true, ledger: framed.next_binding],
           framed: framed,
           retired: retired
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp non_retiring_plan, do: %{compact_opts: [retire: false], framed: nil, retired: %{}}

  # The snapshot must account for exactly the compact strings the ledger frame
  # carries: nothing leaves the hot set without its ledger entry.
  defp require_retired_accounting(core, snapshot, retired) do
    prior = AuditJournal.snapshot_retirement(Map.get(core, "snapshot"))["retired_total"]

    if AuditJournal.snapshot_retirement(snapshot)["retired_total"] == prior + map_size(retired),
      do: :ok,
      else: {:error, :malformed}
  end

  defp require_compact_no_torn(%__MODULE__{torn_tail: nil}), do: :ok
  defp require_compact_no_torn(%__MODULE__{}), do: {:error, :torn_tail}

  defp compact_revalidate(handle) do
    case revalidate_identity(handle) do
      :ok -> :ok
      {:error, {:not_committed, reason}} -> {:error, reason}
    end
  end

  defp compact_reducer(core, source, opts) do
    case AuditJournalCore.compact(core, source, opts) do
      {:ok, compacted, snapshot, pending} -> {:ok, compacted, snapshot, pending}
      {:error, reason} -> {:error, reason}
    end
  end

  defp publish_compacted(handle, ctx) do
    case resolve_candidate_path(handle) do
      {:ok, cand_path} ->
        publish_candidate(handle, ctx, cand_path)

      {:error, reason} ->
        publish_error(handle, nil, nil, :admit, reason)
    end
  end

  defp resolve_candidate_path(handle) do
    parent = Path.dirname(handle.path)

    with {:ok, name} <- AuditJournalFileCore.candidate_basename(Path.basename(handle.path)),
         path = Path.join(parent, name),
         {:ok, resolved} <- contained_in_root(path, handle.root) do
      {:ok, resolved}
    end
  end

  defp publish_candidate(handle, ctx, cand_path) do
    case cleanup_leftover(cand_path) do
      {:error, reason} ->
        publish_error(handle, cand_path, nil, :cleanup, reason)

      :ok ->
        open_and_publish_candidate(handle, ctx, cand_path)
    end
  end

  defp open_and_publish_candidate(handle, ctx, cand_path) do
    case create_candidate(cand_path) do
      {:error, reason} ->
        publish_error(handle, cand_path, nil, :create, reason)

      {:ok, fd, identity} ->
        prove_then_rename(handle, ctx, cand_path, fd, identity)
    end
  end

  defp prove_then_rename(handle, ctx, cand_path, fd, identity) do
    case fill_and_prove_candidate(handle, ctx, cand_path, fd, identity) do
      :ok ->
        _ = close_io_silent(fd)
        ledger_then_source_tip(handle, ctx, cand_path, identity)

      {:error, phase, reason} ->
        _ = close_io_silent(fd)
        publish_error(handle, cand_path, identity, phase, reason)
    end
  end

  # A failed ledger append that proves the ledger inconsistent with its
  # binding (re-inspected, never guessed from the error) pauses the handle's
  # ledger and runs the same publication non-retiring: a paused ledger is
  # never a reason to refuse a publication, and the handle converges to the
  # posture a restart would report. The unpublished attempt left the source
  # intact (not_published re-proved it) and unlinked its candidate.
  defp pause_after_ledger_fault(
         {:error, {:not_published, :ledger_write_failed}} = failed,
         handle,
         %{ledger_frame: %{}}
       ) do
    case AuditRetirementLedger.after_failed_append(handle.ledger, fn ->
           hot_delivered(handle.core)
         end) do
      {:paused, ledger} ->
        paused = %{handle | ledger: ledger}

        case admit_compact(paused, :current, retire: false) do
          {:ok, ctx} -> publish_compacted(paused, ctx)
          {:error, reason} -> publish_error(paused, nil, nil, :admit, reason)
        end

      :transient ->
        failed
    end
  end

  defp pause_after_ledger_fault(result, _handle, _ctx), do: result

  # :ledger_append runs after the candidate proofs (a candidate-side fault
  # leaves no ledger bytes) and before the source-tip proof and rename (a
  # published binding always names a frame that was fsynced, with its
  # directory entry fsynced when the ledger was created). Skipped when the
  # publication retires nothing.
  defp ledger_then_source_tip(handle, %{ledger_frame: nil} = ctx, cand_path, identity) do
    source_tip_then_rename(handle, ctx, cand_path, identity)
  end

  defp ledger_then_source_tip(handle, ctx, cand_path, identity) do
    case AuditRetirementLedger.append(handle.ledger, ctx.ledger_frame.frame, ctx.retired) do
      {:ok, written} ->
        source_tip_then_rename(handle, %{ctx | ledger_written: written}, cand_path, identity)

      {:error, _reason} ->
        publish_error(handle, cand_path, identity, :ledger_append, :ledger_write_failed)
    end
  end

  defp source_tip_then_rename(handle, ctx, cand_path, identity) do
    case prove_source_tip(handle, ctx.source) do
      :ok ->
        rename_and_finalize(handle, ctx, cand_path, identity)

      {:error, reason} ->
        publish_error(handle, cand_path, identity, :source_tip_proof, reason)
    end
  end

  defp fill_and_prove_candidate(handle, ctx, cand_path, fd, identity) do
    with :ok <- tag_phase(:write, write_candidate(fd, ctx.bytes)),
         :ok <- tag_phase(:sync, compact_sync(fd)),
         :ok <- tag_phase(:candidate_proof, prove_candidate_first(fd, cand_path, identity, ctx)),
         :ok <- after_first_proof(handle, cand_path),
         :ok <-
           tag_phase(
             :candidate_reproof,
             prove_candidate_again(fd, cand_path, identity, ctx.bytes)
           ) do
      :ok
    end
  end

  defp write_candidate(fd, bytes) do
    case pwrite_all(fd, 0, bytes) do
      :ok -> :ok
      {:error, {:not_committed, _reason}} -> {:error, :write_failed}
      {:error, _reason} -> {:error, :write_failed}
    end
  end

  defp do_prove_candidate_first(fd, path, identity, ctx) do
    expected_size = byte_size(ctx.bytes)

    with {:ok, data} <- read_all(fd, expected_size),
         {:ok, empty} <- AuditJournalFileCore.new(),
         {:ok, replay} <- AuditJournalFileCore.consume(empty, data),
         :ok <- require_replay_complete(replay),
         :ok <- require_core_equal(replay.core, ctx.compacted),
         :ok <- require_replay_evidence(replay, ctx.expected),
         {:ok, fstat} <- fstat_io(fd),
         :ok <- require_regular(fstat),
         :ok <- require_single_link(fstat),
         :ok <- require_file_mode_0600(fstat),
         :ok <- require_expected_size(fstat, expected_size),
         :ok <- require_same_inode(identity, fstat),
         {:ok, lstat} <- lstat_file(path),
         :ok <- require_regular(lstat),
         :ok <- require_same_inode(identity, lstat),
         :ok <- require_stat_pair(fstat, lstat) do
      :ok
    else
      {:error, reason} -> {:error, map_candidate_proof(reason)}
    end
  end

  defp prove_candidate_again(fd, path, identity, bytes) do
    expected_size = byte_size(bytes)

    with {:ok, fstat} <- fstat_io(fd),
         {:ok, lstat} <- lstat_file(path),
         :ok <- require_regular(fstat),
         :ok <- require_regular(lstat),
         :ok <- require_same_inode(identity, fstat),
         :ok <- require_same_inode(identity, lstat),
         :ok <- require_single_link(fstat),
         :ok <- require_file_mode_0600(fstat),
         :ok <- require_expected_size(fstat, expected_size),
         {:ok, data} <- read_all(fd, expected_size) do
      if data == bytes do
        :ok
      else
        {:error, :digest_mismatch}
      end
    end
  end

  defp prove_source_tip(handle, source) do
    with {:ok, fstat} <- fstat_io(handle.fd),
         {:ok, lstat} <- lstat_file(handle.path),
         :ok <- require_regular(fstat),
         :ok <- require_regular(lstat),
         :ok <- require_file_mode_0600(fstat),
         :ok <- require_single_link(fstat),
         :ok <- require_bound_identity(handle.identity, fstat),
         :ok <- require_bound_identity(handle.identity, lstat),
         :ok <- require_expected_size(fstat, handle.file_size),
         :ok <- require_expected_size(fstat, handle.offset),
         {:ok, data} <- read_all(handle.fd, handle.file_size),
         {:ok, empty} <- AuditJournalFileCore.new(),
         {:ok, replay} <- AuditJournalFileCore.consume(empty, data),
         :ok <- require_replay_complete(replay),
         :ok <- require_source_tip(replay, source),
         :ok <- require_core_equal(replay.core, handle.core) do
      :ok
    else
      {:error, reason} -> {:error, map_source_tip(reason)}
    end
  end

  defp rename_and_finalize(handle, ctx, cand_path, identity) do
    case compact_rename(cand_path, handle.path) do
      :ok ->
        finalize_published(handle, ctx, identity)

      {:after_effect, _reason} ->
        invalidate(handle)
        {:error, {:publish_uncertain, :rename_ambiguous}}

      {:error, reason} ->
        classify_failed_rename(handle, cand_path, identity, reason)
    end
  end

  defp classify_failed_rename(handle, cand_path, identity, reason) do
    present? = candidate_present?(cand_path)
    target_identity_match? = target_still_ours?(handle)

    case AuditJournalFileCore.classify_rename_outcome(%{
           rename: {:error, reason},
           candidate_present?: present?,
           target_identity_match?: target_identity_match?
         }) do
      {:not_published, mapped} ->
        finish_not_published(handle, cand_path, identity, {:error, {:not_published, mapped}})

      {:publish_uncertain, mapped} ->
        invalidate(handle)
        {:error, {:publish_uncertain, mapped}}
    end
  end

  defp finalize_published(handle, ctx, cand_identity) do
    with :ok <- tag_phase(:dir_finalize, compact_fsync_parent(handle)),
         :ok <-
           tag_phase(
             :dir_finalize,
             prove_published_entry(handle.path, cand_identity, byte_size(ctx.bytes))
           ),
         {:ok, new_handle} <- reopen_published(handle, ctx) do
      {:ok, new_handle}
    else
      {:error, phase, reason} ->
        publish_error(handle, nil, nil, phase, reason)
    end
  end

  defp prove_published_entry(path, identity, expected_size) do
    with {:ok, lstat} <- lstat_file(path),
         :ok <- require_regular(lstat),
         :ok <- require_single_link(lstat),
         :ok <- require_file_mode_0600(lstat),
         :ok <- require_expected_size(lstat, expected_size),
         :ok <- require_same_inode(identity, lstat) do
      :ok
    end
  end

  defp reopen_published(handle, ctx) do
    with :ok <- compact_reopen_guard(),
         {:ok, lstat} <- lstat_file(handle.path),
         {:ok, fd, identity} <- open_existing(handle.path, lstat, handle.root) do
      finish_reopened_fd(handle, ctx, fd, identity)
    else
      {:error, reason} ->
        {:error, :reopen, reason}
    end
  end

  if Mix.env() == :test do
    defp finish_reopened_fd(handle, ctx, fd, identity) do
      case compact_replay_guard() do
        :ok ->
          finish_published_open(handle, ctx, fd, identity)

        {:error, reason} ->
          _ = close_io_silent(fd)
          {:error, :published_replay, reason}
      end
    end
  else
    defp finish_reopened_fd(handle, ctx, fd, identity) do
      finish_published_open(handle, ctx, fd, identity)
    end
  end

  defp finish_published_open(handle, ctx, fd, identity) do
    case load_replay(fd, identity) do
      {:ok, replay, identity} ->
        accept_published_replay(handle, ctx, fd, identity, replay)

      {:error, reason} ->
        _ = close_io_silent(fd)
        {:error, :published_replay, reason}
    end
  end

  defp accept_published_replay(handle, ctx, fd, identity, replay) do
    with :ok <- require_replay_complete(replay),
         :ok <- require_core_equal(replay.core, ctx.compacted),
         :ok <- require_replay_evidence(replay, ctx.expected) do
      _ = close_io_silent(handle.fd)
      published = build_handle(fd, handle.root, handle.path, identity, replay)
      {:ok, %{published | ledger: refresh_ledger(handle.ledger, ctx, replay.core)}}
    else
      {:error, reason} ->
        _ = close_io_silent(fd)
        {:error, :published_replay, reason}
    end
  end

  defp cleanup_leftover(path) do
    case File.lstat(path, time: :posix) do
      {:error, :enoent} ->
        :ok

      {:ok, stat} ->
        unlink_leftover(path, stat)

      {:error, reason} ->
        {:error, map_not_published(reason)}
    end
  end

  defp unlink_leftover(path, stat) do
    facts = %{type: stat.type, mode: stat.mode, links: stat.links}

    case AuditJournalFileCore.leftover_action(facts) do
      :unlink ->
        case File.rm(path) do
          :ok -> :ok
          {:error, reason} -> {:error, map_not_published(reason)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_candidate(path) do
    case :file.open(String.to_charlist(path), [:raw, :binary, :read, :write, :exclusive]) do
      {:ok, fd} ->
        finish_candidate_create(fd, path)

      {:error, :eexist} ->
        {:error, :candidate_exists}

      {:error, _reason} ->
        {:error, :write_failed}
    end
  end

  defp finish_candidate_create(fd, path) do
    with :ok <- chmod_private(path),
         {:ok, stat} <- fstat_io(fd),
         :ok <- require_regular(stat),
         :ok <- require_single_link(stat),
         :ok <- require_file_mode_0600(stat),
         {:ok, lstat} <- lstat_file(path),
         :ok <- require_same_inode(file_identity(stat), lstat) do
      {:ok, fd, file_identity(stat)}
    else
      {:error, reason} ->
        identity = identity_from_fd(fd)
        _ = close_io_silent(fd)
        unlink_candidate_if_ours(path, identity)
        {:error, reason}
    end
  end

  defp identity_from_fd(fd) do
    case fstat_io(fd) do
      {:ok, stat} -> file_identity(stat)
      {:error, _reason} -> nil
    end
  end

  # Incomplete replay is context-neutral; callers map it at their boundary.
  defp require_replay_complete(%{torn_tail: nil}), do: :ok
  defp require_replay_complete(_replay), do: {:error, :incomplete_replay}

  defp require_core_equal(left, right) do
    if AuditJournalFileCore.core_match?(left, right) do
      :ok
    else
      {:error, :core_mismatch}
    end
  end

  defp require_replay_evidence(replay, expected) do
    if replay.digest == expected.digest and replay.offset == expected.offset and
         replay.frames == expected.frames and replay.torn_tail == nil do
      :ok
    else
      {:error, :candidate_proof_failed}
    end
  end

  defp require_source_tip(replay, source) do
    if AuditJournalFileCore.source_tip_match?(replay, source) do
      :ok
    else
      {:error, :source_tip_mismatch}
    end
  end

  defp candidate_present?(path) do
    match?({:ok, _stat}, File.lstat(path, time: :posix))
  end

  defp target_still_ours?(handle) do
    with {:ok, lstat} <- lstat_file(handle.path),
         {:ok, fstat} <- fstat_io(handle.fd),
         :ok <- require_bound_identity(handle.identity, lstat),
         :ok <- require_bound_identity(handle.identity, fstat) do
      true
    else
      _ -> false
    end
  end

  defp finish_not_published(handle, cand_path, cand_identity, {:error, {:not_published, reason}}) do
    unlink_candidate_if_ours(cand_path, cand_identity)

    proof =
      case rebuild_and_prove_source(handle) do
        :ok -> :ok
        {:error, proof_reason} -> {:error, map_source_tip(proof_reason)}
      end

    interpret_source_reproof(handle, proof, reason)
  end

  defp interpret_source_reproof(handle, proof, original_reason) do
    case AuditJournalFileCore.classify_source_reproof(proof, original_reason) do
      {:not_published, reason} ->
        {:error, {:not_published, reason}}

      {:source_invalid, proof_reason} ->
        invalidate(handle)
        {:error, {:source_invalid, proof_reason}}

      {:error, :malformed} ->
        invalidate(handle)
        {:error, {:publish_uncertain, :replay_mismatch}}
    end
  end

  defp rebuild_and_prove_source(handle) do
    case AuditJournalFileCore.source_binding(handle.digest, handle.frames, handle.offset) do
      {:ok, source} -> prove_source_tip(handle, source)
      {:error, reason} -> {:error, reason}
    end
  end

  defp unlink_candidate_if_ours(nil, _identity), do: :ok

  defp unlink_candidate_if_ours(_path, nil), do: :ok

  defp unlink_candidate_if_ours(path, identity) do
    case File.lstat(path, time: :posix) do
      {:ok, stat} ->
        facts = %{type: stat.type, mode: stat.mode, links: stat.links}
        ours? = same_candidate_inode?(identity, stat)

        if ours? and AuditJournalFileCore.leftover_action(facts) == :unlink do
          _ = File.rm(path)
          :ok
        else
          :ok
        end

      _other ->
        :ok
    end
  end

  defp same_candidate_inode?(identity, stat) do
    identity.major_device == stat.major_device and identity.minor_device == stat.minor_device and
      identity.inode == stat.inode
  end

  defp compact_sync_fd(fd) do
    case :file.sync(fd) do
      :ok -> :ok
      {:error, _reason} -> {:error, :sync_failed}
    end
  end

  defp tag_phase(_phase, :ok), do: :ok
  defp tag_phase(phase, {:error, reason}), do: {:error, phase, reason}

  defp publish_error(handle, cand_path, cand_identity, phase, reason) do
    mapped = map_publish_reason(phase, reason)

    case AuditJournalFileCore.classify_publish_phase(phase, mapped) do
      {:not_published, classified} ->
        finish_not_published(
          handle,
          cand_path,
          cand_identity,
          {:error, {:not_published, classified}}
        )

      {:publish_uncertain, classified} ->
        invalidate(handle)
        {:error, {:publish_uncertain, classified}}

      {:error, :malformed} ->
        invalidate(handle)
        {:error, {:publish_uncertain, :replay_mismatch}}
    end
  end

  defp map_publish_reason(phase, reason)
       when phase in [:admit, :cleanup, :create, :write, :sync] do
    map_not_published(reason)
  end

  defp map_publish_reason(phase, reason)
       when phase in [:candidate_proof, :candidate_reproof] do
    map_candidate_proof(reason)
  end

  defp map_publish_reason(:source_tip_proof, reason), do: map_source_tip(reason)

  defp map_publish_reason(phase, reason)
       when phase in [:dir_finalize, :reopen, :published_replay] do
    map_uncertain(reason)
  end

  defp map_publish_reason(_phase, reason), do: map_not_published(reason)

  defp map_not_published(reason)
       when reason in [
              :torn_tail,
              :malformed,
              :cross_operation,
              :record_too_large,
              :capacity_exhausted,
              :identity_changed,
              :size_mismatch,
              :digest_mismatch,
              :symlink_rejected,
              :hardlink_rejected,
              :insecure_mode,
              :not_regular,
              :path_escape,
              :parent_missing,
              :candidate_exists,
              :write_failed,
              :sync_failed,
              :candidate_proof_failed,
              :source_tip_mismatch,
              :log_too_large,
              :non_canonical,
              :pending_mismatch,
              :snapshot_not_first,
              :core_mismatch,
              :ledger_write_failed
            ],
       do: reason

  defp map_not_published(_reason), do: :write_failed

  defp map_uncertain(:incomplete_replay), do: :replay_mismatch

  defp map_uncertain(reason)
       when reason in [
              :rename_ambiguous,
              :dir_sync_failed,
              :reopen_failed,
              :replay_mismatch,
              :identity_changed,
              :size_mismatch,
              :digest_mismatch,
              :insecure_mode,
              :not_regular,
              :hardlink_rejected,
              :symlink_rejected,
              :core_mismatch
            ],
       do: reason

  defp map_uncertain(_reason), do: :replay_mismatch

  defp map_candidate_proof(:incomplete_replay), do: :candidate_proof_failed

  defp map_candidate_proof(reason)
       when reason in [
              :identity_changed,
              :size_mismatch,
              :digest_mismatch,
              :insecure_mode,
              :not_regular,
              :hardlink_rejected,
              :symlink_rejected,
              :core_mismatch,
              :candidate_proof_failed
            ],
       do: reason

  defp map_candidate_proof(_reason), do: :candidate_proof_failed

  defp map_source_tip(:incomplete_replay), do: :source_tip_mismatch

  defp map_source_tip(reason)
       when reason in [
              :identity_changed,
              :size_mismatch,
              :digest_mismatch,
              :source_tip_mismatch,
              :core_mismatch
            ],
       do: reason

  defp map_source_tip(_reason), do: :source_tip_mismatch

  if Mix.env() == :test do
    defp compact_sync(fd) do
      case inject(:compact_sync_error) do
        :absent -> compact_sync_fd(fd)
        _reason -> {:error, :sync_failed}
      end
    end

    defp prove_candidate_first(fd, path, identity, ctx) do
      case inject(:compact_after_sync_error) do
        :absent -> do_prove_candidate_first(fd, path, identity, ctx)
        _reason -> {:error, :candidate_proof_failed}
      end
    end

    defp after_first_proof(handle, cand_path) do
      apply_compact_mutations(handle.path, cand_path)
      :ok
    end

    defp apply_compact_mutations(source_path, cand_path) do
      if inject(:compact_substitute_candidate) != :absent do
        substitute_candidate_bytes(cand_path)
      end

      if inject(:compact_rewrite_source_same_size) != :absent do
        rewrite_source_same_size(source_path)
      end

      if inject(:compact_replace_source_inode) != :absent do
        replace_source_inode(source_path)
      end

      :ok
    end

    defp substitute_candidate_bytes(path) do
      case File.read(path) do
        {:ok, data} when byte_size(data) > 0 ->
          _ = File.write(path, flip_first_byte(data))
          _ = File.chmod(path, 0o600)
          :ok

        _other ->
          :ok
      end
    end

    defp rewrite_source_same_size(path) do
      case File.read(path) do
        {:ok, data} when byte_size(data) > 0 ->
          _ = File.write(path, flip_first_byte(data))
          _ = File.chmod(path, 0o600)
          :ok

        _other ->
          :ok
      end
    end

    defp replace_source_inode(path) do
      _ = File.rm(path)
      _ = File.write(path, <<0>>)
      _ = File.chmod(path, 0o600)
      :ok
    end

    defp flip_first_byte(<<byte, rest::binary>>), do: <<Bitwise.bxor(byte, 0xFF), rest::binary>>
    defp flip_first_byte(other), do: other

    defp compact_rename(from, to) do
      cond do
        inject(:compact_rename_before_effect) != :absent ->
          {:error, :eio}

        inject(:compact_rename_after_effect) != :absent ->
          case File.rename(from, to) do
            :ok -> {:after_effect, :eio}
            {:error, reason} -> {:error, reason}
          end

        true ->
          File.rename(from, to)
      end
    end

    defp compact_fsync_parent(handle) do
      parent = Path.dirname(handle.path)

      case inject(:compact_dir_sync) do
        :absent ->
          fsync_directory(parent)

        :ok ->
          :ok

        reason ->
          map_dir_sync(AuditJournalFileCore.classify_dir_sync({:error, reason}))
      end
    end

    @spec compact_reopen_guard() :: :ok | {:error, atom()}
    defp compact_reopen_guard do
      case inject(:compact_reopen_error) do
        :absent -> :ok
        _reason -> {:error, :reopen_failed}
      end
    end

    @spec compact_replay_guard() :: :ok | {:error, atom()}
    defp compact_replay_guard do
      case inject(:compact_replay_error) do
        :absent -> :ok
        _reason -> {:error, :replay_mismatch}
      end
    end
  else
    defp compact_sync(fd), do: compact_sync_fd(fd)

    defp prove_candidate_first(fd, path, identity, ctx),
      do: do_prove_candidate_first(fd, path, identity, ctx)

    defp after_first_proof(_handle, _cand_path), do: :ok

    defp compact_rename(from, to), do: File.rename(from, to)

    defp compact_fsync_parent(handle), do: fsync_directory(Path.dirname(handle.path))

    @spec compact_reopen_guard() :: :ok | {:error, atom()}
    defp compact_reopen_guard, do: :ok
  end

  defp finish_open(fd, root, path, identity) do
    case load_replay(fd, identity) do
      {:ok, replay, identity} ->
        handle = build_handle(fd, root, path, identity, replay)
        {:ok, %{handle | ledger: open_ledger(root, path, replay.core)}}

      {:error, reason} ->
        _ = close_io_silent(fd)
        {:error, reason}
    end
  end

  # The ledger binding is always the one the replayed journal snapshot
  # carries (v3 `retirement.ledger`, else genesis): the in-memory tip is never
  # advanced by a write, only adopted from a published, replayed snapshot.
  defp open_ledger(root, path, core) do
    AuditRetirementLedger.open(
      %{root: root, journal_path: path},
      replayed_ledger_binding(core),
      fn -> hot_delivered(core) end
    )
  end

  defp refresh_ledger(%AuditRetirementLedger{} = prior, ctx, core) do
    written_identity =
      case ctx.ledger_written do
        %AuditRetirementLedger{identity: identity} -> identity
        nil -> nil
      end

    AuditRetirementLedger.refresh(
      prior,
      replayed_ledger_binding(core),
      fn -> hot_delivered(core) end,
      written_identity
    )
  end

  defp refresh_ledger(_prior, _ctx, core) do
    %AuditRetirementLedger{binding: replayed_ledger_binding(core), state: :mismatch}
  end

  defp replayed_ledger_binding(core) do
    AuditJournal.snapshot_retirement(Map.get(core, "snapshot"))["ledger"]
  end

  defp hot_delivered(core) do
    case AuditJournalCore.retirement_batch(core) do
      {:ok, retired} -> retired
      {:error, _reason} -> %{}
    end
  end

  # Spec §6 T1: the raw retirable count, not the effective one. Under a
  # paused ledger the publication is non-retiring (decided in :admit) and
  # still compacts the delivered records to fingerprints.
  defp retirement_due?(%__MODULE__{torn_tail: nil, core: core}) do
    AuditJournalCore.profile(core) == :operational and
      (AuditJournalCore.admission_floor(core) < 3 or
         AuditJournalCore.retirable_count(core) >=
           AuditJournal.limits(:operational).retire_batch)
  end

  defp retirement_due?(_handle), do: false

  defp retirement_result({:ok, published}, _handle), do: {:ok, published}

  defp retirement_result({:error, {:not_published, reason}}, handle),
    do: {:not_published, reason, handle}

  defp retirement_result({:error, {:publish_uncertain, _reason} = err}, _handle),
    do: {:uncertain, err}

  defp retirement_result({:error, {:source_invalid, _reason} = err}, _handle),
    do: {:uncertain, err}

  defp retirement_result({:error, :closed}, _handle), do: {:uncertain, :closed}
  defp retirement_result(_other, _handle), do: {:uncertain, :malformed}

  defp build_handle(fd, root, path, identity, replay) do
    %__MODULE__{
      fd: fd,
      root: root,
      path: path,
      identity: identity,
      core: replay.core,
      digest: replay.digest,
      offset: replay.offset,
      frames: replay.frames,
      file_size: identity.size,
      torn_tail: replay.torn_tail,
      closed?: false
    }
  end

  defp append_admitted(handle, record, bytes) do
    case AuditJournalCore.append(handle.core, record) do
      {:ok, _core, :idempotent} ->
        {:ok, handle, :idempotent}

      {:error, reason} ->
        {:error, reason}

      {:ok, core} ->
        write_committed_frame(handle, core, bytes)
    end
  end

  defp write_committed_frame(handle, core, bytes) do
    case AuditJournalFileCore.encode_frame(bytes, handle.digest) do
      {:error, reason} ->
        {:error, reason}

      {:ok, frame, digest} ->
        persist_frame(handle, core, frame, digest)
    end
  end

  if Mix.env() == :test do
    defp persist_frame(handle, core, frame, digest) do
      offset = handle.offset

      case write_frame(handle.fd, offset, frame) do
        {:error, {:commit_uncertain, _reason}} = err ->
          invalidate(handle)
          err

        result ->
          finish_frame_write(result, handle, core, frame, digest, offset)
      end
    end
  else
    defp persist_frame(handle, core, frame, digest) do
      offset = handle.offset
      result = write_frame(handle.fd, offset, frame)
      finish_frame_write(result, handle, core, frame, digest, offset)
    end
  end

  defp finish_frame_write(
         {:error, {:not_committed, _reason}} = err,
         handle,
         _core,
         _frame,
         _digest,
         _offset
       ) do
    invalidate(handle)
    err
  end

  defp finish_frame_write({:error, reason}, handle, _core, _frame, _digest, _offset) do
    invalidate(handle)
    {:error, {:not_committed, reason}}
  end

  defp finish_frame_write(:ok, handle, core, frame, digest, offset) do
    prove_commit(handle, core, frame, digest, offset)
  end

  defp prove_commit(handle, core, frame, digest, offset) do
    expected_size = offset + byte_size(frame)

    case sync_and_prove(handle, expected_size) do
      {:error, {:commit_uncertain, _reason}} = err ->
        invalidate(handle)
        err

      {:error, reason} ->
        invalidate(handle)
        {:error, {:commit_uncertain, reason}}

      {:ok, identity} ->
        {:ok,
         %{
           handle
           | core: core,
             digest: digest,
             offset: expected_size,
             frames: handle.frames + 1,
             file_size: expected_size,
             identity: identity
         }}
    end
  end

  defp pwrite_all(fd, offset, frame) do
    case :file.pwrite(fd, offset, frame) do
      :ok -> :ok
      {:error, reason} -> {:error, {:not_committed, reason}}
    end
  end

  defp sync_fd(fd) do
    case :file.sync(fd) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  if Mix.env() == :test do
    defp write_frame(fd, offset, frame) do
      case inject(:write_error) do
        :absent ->
          write_frame_injected(fd, offset, frame)

        reason ->
          {:error, {:not_committed, reason}}
      end
    end

    defp write_frame_injected(fd, offset, frame) do
      case inject(:partial_write) do
        :absent ->
          pwrite_all(fd, offset, frame)

        byte_count ->
          write_injected_partial(fd, offset, frame, byte_count)
      end
    end

    defp write_injected_partial(fd, offset, frame, byte_count) do
      if byte_count < byte_size(frame) do
        part = binary_part(frame, 0, byte_count)
        _ = :file.pwrite(fd, offset, part)
        {:error, {:not_committed, :write_failed}}
      else
        {:error, {:commit_uncertain, :write_failed}}
      end
    end

    defp sync_and_prove(handle, expected_size) do
      case injected_sync(handle.fd) do
        {:error, reason} ->
          {:error, {:commit_uncertain, reason}}

        :ok ->
          apply_post_sync_chmod(handle.path)
          post_sync_proof(handle, expected_size)
      end
    end

    defp injected_sync(fd) do
      case inject(:sync_error) do
        :absent -> sync_fd(fd)
        _reason -> {:error, :sync_failed}
      end
    end

    defp apply_post_sync_chmod(path) do
      case inject(:post_sync_chmod) do
        :absent ->
          :ok

        mode ->
          _ = File.chmod(path, mode)
          :ok
      end
    end

    defp post_sync_proof(handle, expected_size) do
      case inject(:post_sync_proof_error) do
        :absent ->
          prove_identity_after_sync(handle, expected_size)

        reason ->
          {:error, {:commit_uncertain, reason}}
      end
    end

    defp post_sync_lstat(path) do
      with {:ok, stat} <- lstat_file(path) do
        case inject(:post_sync_lstat_minor_device_delta) do
          :absent -> {:ok, stat}
          delta -> {:ok, %{stat | minor_device: stat.minor_device + delta}}
        end
      end
    end
  else
    defp write_frame(fd, offset, frame), do: pwrite_all(fd, offset, frame)

    defp sync_and_prove(handle, expected_size) do
      case sync_fd(handle.fd) do
        :ok -> prove_identity_after_sync(handle, expected_size)
        {:error, reason} -> {:error, {:commit_uncertain, reason}}
      end
    end

    defp post_sync_lstat(path), do: lstat_file(path)
  end

  defp prove_identity_after_sync(handle, expected_size) do
    with {:ok, fstat} <- fstat_io(handle.fd),
         :ok <- require_regular(fstat),
         :ok <- require_same_inode(handle.identity, fstat),
         :ok <- require_single_link(fstat),
         :ok <- require_file_mode_0600(fstat),
         :ok <- require_expected_size(fstat, expected_size),
         {:ok, lstat} <- post_sync_lstat(handle.path),
         :ok <- require_regular(lstat),
         :ok <- require_same_inode(handle.identity, lstat),
         :ok <- require_stat_pair(fstat, lstat) do
      {:ok, file_identity(fstat)}
    else
      {:error, reason} -> {:error, {:commit_uncertain, reason}}
    end
  end

  defp admit_canonical(raw) do
    with {:ok, record} <- map_admit(AuditJournal.admit_record(raw)),
         {:ok, bytes} <- map_bytes(AuditJournal.canonical_record_bytes(record)) do
      {:ok, record, bytes}
    end
  end

  defp map_admit({:ok, record}), do: {:ok, record}
  defp map_admit({:error, :cross_operation}), do: {:error, :cross_operation}
  defp map_admit({:error, :record_too_large}), do: {:error, :record_too_large}
  defp map_admit({:error, _reason}), do: {:error, :malformed}

  defp map_bytes({:ok, bytes}), do: {:ok, bytes}
  defp map_bytes({:error, :record_too_large}), do: {:error, :record_too_large}
  defp map_bytes({:error, _reason}), do: {:error, :malformed}

  defp require_no_torn_tail(%__MODULE__{torn_tail: nil}), do: :ok
  defp require_no_torn_tail(%__MODULE__{}), do: {:error, {:not_committed, :torn_tail}}

  defp revalidate_identity(%__MODULE__{} = handle) do
    with {:ok, lstat} <- lstat_file(handle.path),
         {:ok, fstat} <- fstat_io(handle.fd),
         :ok <- require_regular(lstat),
         :ok <- require_regular(fstat),
         :ok <- require_bound_identity(handle.identity, lstat),
         :ok <- require_bound_identity(handle.identity, fstat) do
      :ok
    else
      {:error, reason} -> {:error, {:not_committed, reason}}
    end
  end

  defp reject_unknown_opts(opts) do
    unknown = Keyword.keys(opts) -- @allowed_opts

    if unknown == [] do
      :ok
    else
      {:error, :invalid_opts}
    end
  end

  defp fetch_root(opts) do
    case Keyword.fetch(opts, :root) do
      {:ok, root} when is_binary(root) -> {:ok, root}
      {:ok, _other} -> {:error, :invalid_opts}
      :error -> {:error, :invalid_opts}
    end
  end

  defp validate_root(root) do
    with {:ok, expanded} <- expand_absolute_root(root),
         {:ok, stat} <- lstat_root(expanded),
         :ok <- require_owner_only_dir(stat),
         {:ok, real} <- resolve_real_path(expanded),
         :ok <- require_same_path(real, expanded) do
      {:ok, real}
    end
  end

  defp expand_absolute_root(root) when is_binary(root) do
    cond do
      not String.valid?(root) ->
        {:error, :root_invalid}

      String.contains?(root, <<0>>) ->
        {:error, :root_invalid}

      Path.type(root) != :absolute ->
        {:error, :relative_path}

      true ->
        expanded = Path.expand(root)

        if Path.split(expanded) == ["/"] do
          {:error, :root_invalid}
        else
          {:ok, expanded}
        end
    end
  end

  defp expand_absolute_root(_root), do: {:error, :root_invalid}

  defp resolve_file_path(root, opts) do
    case Keyword.fetch(opts, :path) do
      :error ->
        default_file_path(root)

      {:ok, path} when is_binary(path) ->
        explicit_file_path(path)

      {:ok, _other} ->
        {:error, :invalid_opts}
    end
  end

  # A basename in the retirement-ledger namespace is reserved for ledgers: a
  # journal opened there could be (or share) another journal's ledger.
  defp refuse_ledger_name(path) do
    if AuditJournalFileCore.ledger_basename?(Path.basename(path)),
      do: {:error, :reserved_name},
      else: :ok
  end

  defp default_file_path(root) do
    case SafePath.safe_join(root, @default_name) do
      {:ok, path} -> {:ok, path}
      {:error, _reason} -> {:error, :path_escape}
    end
  end

  defp explicit_file_path(path) do
    cond do
      not String.valid?(path) -> {:error, :path_escape}
      String.contains?(path, <<0>>) -> {:error, :path_escape}
      Path.type(path) != :absolute -> {:error, :relative_path}
      true -> {:ok, Path.expand(path)}
    end
  end

  defp validate_parent(path, root) do
    parent = Path.dirname(path)

    with {:ok, stat} <- lstat_parent(parent),
         :ok <- require_owner_only_dir(stat),
         {:ok, real} <- resolve_real_path(parent),
         :ok <- require_same_path(real, Path.expand(parent)),
         {:ok, _contained} <- contained_in_root(real, root) do
      {:ok, parent}
    end
  end

  defp open_target(path, root) do
    case File.lstat(path, time: :posix) do
      {:error, :enoent} ->
        create_exclusive(path)

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, :symlink_rejected}

      {:ok, %File.Stat{type: type}} when type != :regular ->
        {:error, :not_regular}

      {:ok, stat} ->
        open_existing(path, stat, root)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_exclusive(path) do
    case :file.open(String.to_charlist(path), [:raw, :binary, :read, :write, :exclusive]) do
      {:ok, fd} ->
        finish_create(fd, path)

      {:error, :eexist} ->
        {:error, :identity_changed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp finish_create(fd, path) do
    with :ok <- chmod_private(path),
         {:ok, stat} <- fstat_io(fd),
         :ok <- require_regular(stat),
         :ok <- require_single_link(stat),
         :ok <- require_file_mode_0600(stat),
         {:ok, lstat} <- lstat_file(path),
         :ok <- require_same_inode(file_identity(stat), lstat),
         :ok <- sync_created(fd) do
      {:ok, fd, file_identity(stat)}
    else
      {:error, reason} ->
        _ = close_io_silent(fd)
        {:error, reason}
    end
  end

  defp sync_created(fd) do
    case :file.sync(fd) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp open_existing(path, lstat, root) do
    with :ok <- require_single_link(lstat),
         :ok <- require_file_mode_0600(lstat),
         {:ok, real} <- resolve_real_path(path),
         {:ok, _contained} <- contained_in_root(real, root),
         {:ok, fd} <- open_rw(path) do
      finish_existing_open(fd, lstat)
    end
  end

  defp finish_existing_open(fd, lstat) do
    case match_opened_fd(fd, lstat) do
      {:ok, identity} ->
        {:ok, fd, identity}

      {:error, reason} ->
        _ = close_io_silent(fd)
        {:error, reason}
    end
  end

  defp match_opened_fd(fd, lstat) do
    with {:ok, fstat} <- fstat_io(fd),
         :ok <- require_regular(fstat),
         :ok <- require_stat_pair(lstat, fstat) do
      {:ok, file_identity(fstat)}
    end
  end

  defp open_rw(path) do
    case :file.open(String.to_charlist(path), [:raw, :binary, :read, :write]) do
      {:ok, fd} -> {:ok, fd}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_replay(fd, identity) do
    if identity.size > AuditJournalFileCore.max_file_bytes() do
      {:error, :log_too_large}
    else
      read_and_consume(fd, identity)
    end
  end

  defp read_and_consume(fd, identity) do
    with {:ok, binary} <- read_all(fd, identity.size),
         {:ok, empty} <- AuditJournalFileCore.new(),
         {:ok, replay} <- AuditJournalFileCore.consume(empty, binary) do
      {:ok, replay, identity}
    end
  end

  defp read_all(_fd, 0), do: {:ok, <<>>}

  defp read_all(fd, size) when is_integer(size) and size > 0 do
    case :file.pread(fd, 0, size) do
      {:ok, data} when is_binary(data) and byte_size(data) == size -> {:ok, data}
      {:ok, _data} -> {:error, :read_failed}
      :eof -> {:error, :read_failed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp lstat_root(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :directory} = stat} -> {:ok, stat}
      {:ok, %File.Stat{type: :symlink}} -> {:error, :symlink_rejected}
      {:ok, %File.Stat{}} -> {:error, :root_invalid}
      {:error, :enoent} -> {:error, :root_invalid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp lstat_parent(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :directory} = stat} -> {:ok, stat}
      {:ok, %File.Stat{type: :symlink}} -> {:error, :symlink_rejected}
      {:ok, %File.Stat{}} -> {:error, :not_regular}
      {:error, :enoent} -> {:error, :parent_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_same_path(left, right) when left == right, do: :ok
  defp require_same_path(_left, _right), do: {:error, :symlink_rejected}

  defp require_owner_only_dir(%File.Stat{type: :directory, mode: mode}) do
    if Bitwise.band(mode, 0o077) == 0 do
      :ok
    else
      {:error, :insecure_mode}
    end
  end

  defp require_owner_only_dir(%File.Stat{type: :symlink}), do: {:error, :symlink_rejected}
  defp require_owner_only_dir(_stat), do: {:error, :not_regular}

  defp invalidate(%__MODULE__{fd: fd} = handle) when not is_nil(fd) do
    _ = close_io_silent(fd)
    %{handle | fd: nil, closed?: true}
  end

  defp invalidate(handle), do: handle
end
