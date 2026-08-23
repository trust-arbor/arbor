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

  Not a GenServer and not a generic store. Single-writer is assumed, not
  enforced. Does not claim hostile same-UID tamper resistance, host power-loss
  durability, or distributed linearizability.
  """

  alias Arbor.Common.SafePath
  alias Arbor.Security.AuditJournalCore
  alias Arbor.Security.AuditJournalFileCore
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

  @spec open(keyword()) :: {:ok, t()} | {:error, term()}
  def open(opts) when is_list(opts) do
    with :ok <- reject_unknown_opts(opts),
         {:ok, root} <- fetch_root(opts),
         {:ok, root} <- validate_root(root),
         {:ok, path} <- resolve_file_path(root, opts),
         {:ok, path} <- contained_in_root(path, root),
         {:ok, _parent} <- validate_parent(path, root),
         {:ok, fd, identity} <- open_target(path, root) do
      finish_open(fd, root, path, identity)
    end
  end

  def open(_opts), do: {:error, :invalid_opts}

  @spec close(t()) :: :ok
  def close(%__MODULE__{fd: fd, closed?: false}) when not is_nil(fd) do
    _ = close_io_silent(fd)
    :ok
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

  @spec compact(t()) ::
          {:ok, t()}
          | {:error, :closed}
          | {:error, {:not_published, not_published_reason()}}
          | {:error, {:publish_uncertain, publish_uncertain_reason()}}
  def compact(%__MODULE__{closed?: true}), do: {:error, :closed}

  def compact(%__MODULE__{} = handle) do
    case admit_compact(handle) do
      {:ok, ctx} ->
        publish_compacted(handle, ctx)

      {:error, :closed} = err ->
        err

      {:error, {:not_published, _reason}} = err ->
        finish_not_published(handle, nil, nil, err)

      {:error, reason} ->
        finish_not_published(handle, nil, nil, {:error, {:not_published, map_not_published(reason)}})
    end
  end

  def compact(_handle), do: {:error, :closed}

  if Mix.env() == :test do
    @inject_key {__MODULE__, :inject}

    @doc false
    @spec __test_inject__(:clear) :: :ok
    def __test_inject__(:clear) do
      Process.delete(@inject_key)
      :ok
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
    @spec __test_inject__(
            :compact_rewrite_source_same_size
            | :compact_replace_source_inode
            | :compact_substitute_candidate
            | :compact_rename_before_effect
            | :compact_rename_after_effect
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

    defp inject(key) do
      Process.get(@inject_key, %{}) |> Map.get(key, :absent)
    end
  end

  defp admit_compact(%__MODULE__{} = handle) do
    with :ok <- require_compact_no_torn(handle),
         :ok <- compact_revalidate(handle),
         {:ok, source} <-
           AuditJournalFileCore.source_binding(handle.digest, handle.frames, handle.offset),
         {:ok, compacted, snapshot, pending} <- compact_reducer(handle.core, source),
         {:ok, bytes, expected} <- AuditJournalFileCore.encode_compacted(snapshot, pending) do
      {:ok,
       %{
         source: source,
         compacted: compacted,
         bytes: bytes,
         expected: expected
       }}
    end
  end

  defp require_compact_no_torn(%__MODULE__{torn_tail: nil}), do: :ok
  defp require_compact_no_torn(%__MODULE__{}), do: {:error, {:not_published, :torn_tail}}

  defp compact_revalidate(handle) do
    case revalidate_identity(handle) do
      :ok -> :ok
      {:error, {:not_committed, reason}} -> {:error, {:not_published, map_not_published(reason)}}
    end
  end

  defp compact_reducer(core, source) do
    case AuditJournalCore.compact(core, source) do
      {:ok, compacted, snapshot, pending} -> {:ok, compacted, snapshot, pending}
      {:error, reason} -> {:error, {:not_published, map_not_published(reason)}}
    end
  end

  defp publish_compacted(handle, ctx) do
    case resolve_candidate_path(handle) do
      {:ok, cand_path} ->
        publish_candidate(handle, ctx, cand_path)

      {:error, reason} ->
        finish_not_published(handle, nil, nil, {:error, {:not_published, map_not_published(reason)}})
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
        finish_not_published(
          handle,
          cand_path,
          nil,
          {:error, {:not_published, map_not_published(reason)}}
        )

      :ok ->
        open_and_publish_candidate(handle, ctx, cand_path)
    end
  end

  defp open_and_publish_candidate(handle, ctx, cand_path) do
    case create_candidate(cand_path) do
      {:error, reason} ->
        finish_not_published(
          handle,
          cand_path,
          nil,
          {:error, {:not_published, map_not_published(reason)}}
        )

      {:ok, fd, identity} ->
        prove_then_rename(handle, ctx, cand_path, fd, identity)
    end
  end

  defp prove_then_rename(handle, ctx, cand_path, fd, identity) do
    case fill_and_prove_candidate(handle, ctx, cand_path, fd, identity) do
      :ok ->
        _ = close_io_silent(fd)
        source_tip_then_rename(handle, ctx, cand_path, identity)

      {:error, reason} ->
        _ = close_io_silent(fd)

        finish_not_published(
          handle,
          cand_path,
          identity,
          {:error, {:not_published, map_not_published(reason)}}
        )
    end
  end

  defp source_tip_then_rename(handle, ctx, cand_path, identity) do
    case prove_source_tip(handle, ctx.source) do
      :ok ->
        rename_and_finalize(handle, ctx, cand_path, identity)

      {:error, reason} ->
        finish_not_published(
          handle,
          cand_path,
          identity,
          {:error, {:not_published, map_not_published(reason)}}
        )
    end
  end

  defp fill_and_prove_candidate(handle, ctx, cand_path, fd, identity) do
    with :ok <- write_candidate(fd, ctx.bytes),
         :ok <- compact_sync(fd),
         :ok <- prove_candidate_first(fd, cand_path, identity, ctx),
         :ok <- after_first_proof(handle, cand_path),
         :ok <- prove_candidate_again(fd, cand_path, identity, ctx.bytes) do
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
        classify_failed_rename(handle, ctx, cand_path, identity, reason)
    end
  end

  defp classify_failed_rename(handle, ctx, cand_path, identity, reason) do
    present? = candidate_present?(cand_path)
    match? = target_still_ours?(handle)

    case AuditJournalFileCore.classify_rename_outcome(%{
           rename: {:error, reason},
           candidate_present?: present?,
           target_identity_match?: match?
         }) do
      {:not_published, mapped} ->
        finish_not_published(handle, cand_path, identity, {:error, {:not_published, mapped}})

      {:publish_uncertain, mapped} ->
        invalidate(handle)
        {:error, {:publish_uncertain, mapped}}

      :continue ->
        finalize_published(handle, ctx, identity)
    end
  end

  defp finalize_published(handle, ctx, cand_identity) do
    with :ok <- compact_fsync_parent(handle),
         :ok <- prove_published_entry(handle.path, cand_identity, byte_size(ctx.bytes)),
         {:ok, new_handle} <- reopen_published(handle, ctx) do
      {:ok, new_handle}
    else
      {:error, reason} ->
        invalidate(handle)
        {:error, {:publish_uncertain, map_uncertain(reason)}}
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
    end
  end

  defp finish_reopened_fd(handle, ctx, fd, identity) do
    case compact_replay_guard() do
      :ok ->
        finish_published_open(handle, ctx, fd, identity)

      {:error, reason} ->
        _ = close_io_silent(fd)
        {:error, reason}
    end
  end

  defp finish_published_open(handle, ctx, fd, identity) do
    case load_replay(fd, identity) do
      {:ok, replay, identity} ->
        accept_published_replay(handle, ctx, fd, identity, replay)

      {:error, reason} ->
        _ = close_io_silent(fd)
        {:error, map_uncertain(reason)}
    end
  end

  defp accept_published_replay(handle, ctx, fd, identity, replay) do
    with :ok <- require_replay_complete(replay),
         :ok <- require_core_equal(replay.core, ctx.compacted),
         :ok <- require_replay_evidence(replay, ctx.expected) do
      _ = close_io_silent(handle.fd)
      {:ok, build_handle(fd, handle.root, handle.path, identity, replay)}
    else
      {:error, reason} ->
        _ = close_io_silent(fd)
        {:error, map_uncertain(reason)}
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

  defp require_replay_complete(%{torn_tail: nil}), do: :ok
  defp require_replay_complete(_replay), do: {:error, :source_tip_mismatch}

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

  defp finish_not_published(handle, cand_path, cand_identity, err) do
    unlink_candidate_if_ours(cand_path, cand_identity)

    case rebuild_and_prove_source(handle) do
      :ok ->
        err

      {:error, _reason} ->
        invalidate(handle)
        err
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

  defp do_fsync_directory(dir) do
    case :file.open(String.to_charlist(dir), [:raw, :read, :directory]) do
      {:ok, io} ->
        try do
          case :file.sync(io) do
            :ok -> AuditJournalFileCore.classify_dir_sync(:ok)
            {:error, reason} -> map_dir_sync(AuditJournalFileCore.classify_dir_sync({:error, reason}))
          end
        after
          _ = close_io_silent(io)
        end

      {:error, reason} ->
        map_dir_sync(AuditJournalFileCore.classify_dir_sync({:error, reason}))
    end
  end

  defp map_dir_sync(:ok), do: :ok
  defp map_dir_sync({:error, _reason}), do: {:error, :dir_sync_failed}

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
              :core_mismatch
            ],
       do: reason

  defp map_not_published(_reason), do: :write_failed

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
          do_fsync_directory(parent)

        :ok ->
          :ok

        reason ->
          map_dir_sync(AuditJournalFileCore.classify_dir_sync({:error, reason}))
      end
    end

    defp compact_reopen_guard do
      case inject(:compact_reopen_error) do
        :absent -> :ok
        _reason -> {:error, :reopen_failed}
      end
    end

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

    defp compact_fsync_parent(handle), do: do_fsync_directory(Path.dirname(handle.path))

    defp compact_reopen_guard, do: :ok

    defp compact_replay_guard, do: :ok
  end

  defp finish_open(fd, root, path, identity) do
    case load_replay(fd, identity) do
      {:ok, replay, identity} ->
        {:ok, build_handle(fd, root, path, identity, replay)}

      {:error, reason} ->
        _ = close_io_silent(fd)
        {:error, reason}
    end
  end

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

  defp contained_in_root(path, root) do
    with :ok <- require_absolute_path(path),
         {:ok, resolved} <- resolve_within_root(path, root),
         :ok <- require_segment_prefix(resolved, root) do
      {:ok, resolved}
    end
  end

  defp require_absolute_path(path) when is_binary(path) do
    if Path.type(path) == :absolute do
      :ok
    else
      {:error, :relative_path}
    end
  end

  defp resolve_within_root(path, root) do
    case SafePath.resolve_within(path, root) do
      {:ok, resolved} -> {:ok, resolved}
      {:error, :path_traversal} -> {:error, :path_escape}
      {:error, _reason} -> {:error, :path_escape}
    end
  end

  defp require_segment_prefix(path, root) do
    path_segs = Path.split(path)
    root_segs = Path.split(Path.expand(root))

    if List.starts_with?(path_segs, root_segs) do
      :ok
    else
      {:error, :path_escape}
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

  defp lstat_file(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :symlink}} -> {:error, :symlink_rejected}
      {:ok, %File.Stat{type: type}} when type != :regular -> {:error, :not_regular}
      {:ok, stat} -> {:ok, stat}
      {:error, :enoent} -> {:error, :identity_changed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_real_path(path) do
    case SafePath.resolve_real(path) do
      {:ok, real} -> {:ok, real}
      {:error, :not_found} -> {:error, :parent_missing}
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

  defp require_regular(%File.Stat{type: :regular}), do: :ok
  defp require_regular(%File.Stat{type: :symlink}), do: {:error, :symlink_rejected}
  defp require_regular(_stat), do: {:error, :not_regular}

  defp require_single_link(%File.Stat{links: 1}), do: :ok
  defp require_single_link(%File.Stat{}), do: {:error, :hardlink_rejected}

  defp require_file_mode_0600(%File.Stat{type: :regular, mode: mode}) do
    if Bitwise.band(mode, 0o777) == 0o600 do
      :ok
    else
      {:error, :insecure_mode}
    end
  end

  defp require_file_mode_0600(%File.Stat{type: :symlink}), do: {:error, :symlink_rejected}
  defp require_file_mode_0600(_stat), do: {:error, :not_regular}

  defp require_expected_size(%File.Stat{size: size}, expected) when size == expected, do: :ok
  defp require_expected_size(_stat, _expected), do: {:error, :size_mismatch}

  defp require_same_inode(identity, %File.Stat{} = stat) when is_map(identity) do
    if identity.major_device == stat.major_device and
         identity.minor_device == stat.minor_device and
         identity.inode == stat.inode do
      :ok
    else
      {:error, :identity_changed}
    end
  end

  defp require_bound_identity(identity, %File.Stat{} = stat) do
    if file_identity(stat) == identity do
      :ok
    else
      {:error, :identity_changed}
    end
  end

  defp require_stat_pair(%File.Stat{} = left, %File.Stat{} = right) do
    if file_identity(left) == file_identity(right) do
      :ok
    else
      {:error, :identity_changed}
    end
  end

  defp file_identity(%File.Stat{} = stat) do
    %{
      major_device: stat.major_device,
      minor_device: stat.minor_device,
      inode: stat.inode,
      uid: stat.uid,
      gid: stat.gid,
      mode: stat.mode,
      links: stat.links,
      size: stat.size
    }
  end

  defp chmod_private(path) do
    case File.chmod(path, 0o600) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp fstat_io(fd) do
    case :file.read_file_info(fd, time: :posix) do
      {:ok, info} -> {:ok, File.Stat.from_record(info)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp invalidate(%__MODULE__{fd: fd} = handle) when not is_nil(fd) do
    _ = close_io_silent(fd)
    %{handle | fd: nil, closed?: true}
  end

  defp invalidate(handle), do: handle

  defp close_io_silent(fd) do
    :file.close(fd)
  catch
    _, _ -> :ok
  end
end
