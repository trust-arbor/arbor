defmodule Arbor.Security.AuditRetirementLedger do
  @moduledoc """
  Imperative shell for the cold authority-audit retirement ledger.

  Called only from `Arbor.Security.AuditJournalFile`. The ledger file lives in
  the journal's own directory under a name derived from the journal basename
  (`AuditJournalFileCore.ledger_basename/1`) and obeys the journal's file
  rules (`Arbor.Security.AuditJournalFileProofs`): contained in the frozen
  Security root, regular, never a symlink, single link, mode 0600, identity
  re-proven by lstat/fstat pairs.

  - `open/3` classifies the ledger against the binding of the replayed journal
    snapshot. It never writes and never fails: every problem is a posture
    (`:absent | :bound | :bound_orphan | :mismatch | :ahead`), so a cold-file
    fault can pause retirement but never faults the hot path.
  - `append/3` writes exactly one frame at the bound offset: re-prove the
    file (and its recorded identity), fsync the parent directory when the
    first frame is written (the create durability point), re-verify the
    bound tip, truncate to the bound only when the bytes beyond it are an
    overwritable orphan, `pwrite`, `fsync`, then prove size and identity.
    The ledger therefore always holds exactly its bound content plus at most
    one candidate frame at the bound offset.
  - `refresh/4` recomputes the posture after an adopted publication. The
    binding is always the one the replayed published snapshot carries; a
    paused posture only changes by restart.

  No file descriptor is held between calls: each open/append re-opens the
  path through the same containment and identity proofs and closes it before
  returning, so a handle that the owner keeps after an unpublished attempt can
  never leak a descriptor or hold a stale one.

  Single-writer is assumed (the journal owner), not enforced. Does not claim
  hostile same-UID tamper resistance or host power-loss durability beyond the
  journal's own claims.
  """

  import Arbor.Security.AuditJournalFileProofs

  alias Arbor.Common.SafePath
  alias Arbor.Security.AuditJournalFileCore
  alias Arbor.Security.AuditRetirementLedgerCore, as: LedgerCore

  defstruct [:root, :path, :binding, :identity, state: :mismatch, detail: :none]

  @type t :: %__MODULE__{
          root: String.t(),
          path: String.t() | nil,
          binding: map(),
          identity: map() | nil,
          state: LedgerCore.posture(),
          detail: atom()
        }

  @type location :: %{root: String.t(), journal_path: String.t()}

  @typedoc "Hot delivered terminals, or a thunk that computes them only when needed."
  @type hot :: map() | (-> map())

  @doc """
  Classify the ledger that belongs to `journal_path` against `binding` (the
  replayed snapshot's `retirement.ledger`, or genesis).

  - absent file: genesis binding -> `:absent`; a binding naming frames ->
    `:mismatch`;
  - present file failing the journal's file rules -> `:mismatch`;
  - shorter than the bound, or a bound tip frame whose digest does not
    recompute to `tip_digest` -> `:mismatch`;
  - otherwise the bytes beyond the bound classify `:bound`, `:bound_orphan`
    or `:ahead` (`AuditRetirementLedgerCore.classify_tail/3`).
  """
  @spec open(location(), map(), hot()) :: t()
  def open(%{root: root, journal_path: journal_path}, binding, hot)
      when is_binary(root) and is_binary(journal_path) do
    base = %__MODULE__{root: root, binding: binding}

    with {:ok, path} <- ledger_path(root, journal_path),
         {:ok, _size} <- LedgerCore.bound_size(binding) do
      inspect_file(%{base | path: path}, hot, nil)
    else
      {:error, reason} -> paused(base, :mismatch, reason)
    end
  end

  @doc """
  Recompute the posture after an adopted publication whose replayed snapshot
  binds `binding`. `written_identity` is the identity `append/3` proved when
  the publication wrote a frame (else `nil`: the prior identity is expected).
  A paused posture (`:mismatch | :ahead`) is kept: it changes only by restart
  after the journal/ledger pair is repaired.
  """
  @spec refresh(t(), map(), hot(), map() | nil) :: t()
  def refresh(%__MODULE__{} = prior, binding, hot, written_identity) do
    cond do
      LedgerCore.paused?(prior.state) ->
        %{prior | binding: binding}

      is_nil(prior.path) ->
        paused(%{prior | binding: binding}, :mismatch, :path_escape)

      true ->
        expected = written_identity || prior.identity
        fresh = %{prior | binding: binding, identity: nil, state: :mismatch, detail: :none}
        inspect_file(fresh, hot, expected)
    end
  end

  @doc """
  Append one frame (built by `AuditRetirementLedgerCore.frame/3` from this
  ledger's binding) at the bound offset. `hot_delivered` is the hot delivered
  set of the journal being published; any bytes beyond the bound must be an
  orphan of it to be overwritten.

  Returns `{:ok, ledger}` with the proven identity (the binding is NOT
  advanced: the tip is adopted only from the replayed published snapshot), or
  `{:error, reason}` (the caller reports `:ledger_write_failed`).
  """
  @spec append(t(), binary(), map()) :: {:ok, t()} | {:error, atom()}
  def append(%__MODULE__{path: path, state: state} = ledger, frame, hot_delivered)
      when is_binary(path) and is_binary(frame) and is_map(hot_delivered) do
    if LedgerCore.retiring_allowed?(state) do
      with :ok <- LedgerCore.verify_next_frame(ledger.binding, frame),
           {:ok, bound} <- LedgerCore.bound_size(ledger.binding),
           {:ok, fd, identity} <- open_for_append(ledger, bound) do
        try do
          write_at_bound(ledger, fd, identity, bound, frame, hot_delivered)
        after
          _ = close_io_silent(fd)
        end
      end
    else
      {:error, :ledger_paused}
    end
  rescue
    _ -> {:error, :exception}
  catch
    _, _ -> {:error, :exception}
  end

  def append(_ledger, _frame, _hot_delivered), do: {:error, :malformed}

  @doc "Release the ledger. No descriptor is held between calls, so this is a no-op."
  @spec close(term()) :: :ok
  def close(_ledger), do: :ok

  @spec state(t()) :: LedgerCore.posture()
  def state(%__MODULE__{state: state}), do: state

  if Mix.env() == :test do
    @inject_key {__MODULE__, :inject}

    @doc false
    @spec __test_inject__(:clear) :: :ok
    def __test_inject__(:clear) do
      Process.delete(@inject_key)
      :ok
    end

    @doc false
    @spec __test_inject__(
            :ledger_write_error | :ledger_truncate_below_bound | :ledger_dir_sync,
            term()
          ) :: :ok
    def __test_inject__(key, value)
        when key in [:ledger_write_error, :ledger_truncate_below_bound, :ledger_dir_sync] do
      current = Process.get(@inject_key, %{})
      Process.put(@inject_key, Map.put(current, key, value))
      :ok
    end

    defp inject(key), do: Process.get(@inject_key, %{}) |> Map.get(key, :absent)

    defp pwrite_frame(fd, offset, frame) do
      case inject(:ledger_write_error) do
        :absent -> do_pwrite(fd, offset, frame)
        _reason -> {:error, :write_failed}
      end
    end

    defp truncate_target(bound) do
      case inject(:ledger_truncate_below_bound) do
        :absent -> {bound, false}
        _flag -> {max(bound - 1, 0), true}
      end
    end

    defp sync_parent(dir) do
      case inject(:ledger_dir_sync) do
        :absent -> fsync_directory(dir)
        :ok -> :ok
        reason -> map_dir_sync(AuditJournalFileCore.classify_dir_sync({:error, reason}))
      end
    end
  else
    defp pwrite_frame(fd, offset, frame), do: do_pwrite(fd, offset, frame)
    defp truncate_target(bound), do: {bound, false}
    defp sync_parent(dir), do: fsync_directory(dir)
  end

  # ---------------------------------------------------------------------------
  # Open-time classification (read-only)
  # ---------------------------------------------------------------------------

  defp ledger_path(root, journal_path) do
    parent = Path.dirname(journal_path)

    with {:ok, name} <- AuditJournalFileCore.ledger_basename(Path.basename(journal_path)),
         {:ok, joined} <- safe_join(parent, name) do
      contained_in_root(joined, root)
    else
      {:error, :malformed} -> {:error, :path_escape}
      {:error, reason} -> {:error, reason}
    end
  end

  defp safe_join(parent, name) do
    case SafePath.safe_join(parent, name) do
      {:ok, path} -> {:ok, path}
      {:error, _reason} -> {:error, :path_escape}
    end
  end

  # Never raises: the posture is also recomputed after a publication's rename,
  # where a cold-file surprise must pause retirement, not crash the owner.
  defp inspect_file(ledger, hot, expected_identity) do
    do_inspect_file(ledger, hot, expected_identity)
  rescue
    _ -> paused(ledger, :mismatch, :exception)
  catch
    _, _ -> paused(ledger, :mismatch, :exception)
  end

  defp do_inspect_file(ledger, hot, expected_identity) do
    case File.lstat(ledger.path, time: :posix) do
      {:error, :enoent} ->
        absent_posture(ledger, expected_identity)

      {:ok, %File.Stat{type: :regular} = lstat} ->
        inspect_existing(ledger, lstat, hot, expected_identity)

      {:ok, %File.Stat{type: :symlink}} ->
        paused(ledger, :mismatch, :symlink_rejected)

      {:ok, %File.Stat{}} ->
        paused(ledger, :mismatch, :not_regular)

      {:error, reason} ->
        paused(ledger, :mismatch, io_reason(reason))
    end
  end

  # An absent ledger is consistent only with a genesis binding and only when
  # no identity was ever proven for it in this handle's lifetime.
  defp absent_posture(ledger, nil) do
    case ledger.binding do
      %{"frames" => 0} -> %{ledger | state: :absent, identity: nil, detail: :none}
      _bound -> paused(ledger, :mismatch, :ledger_missing)
    end
  end

  defp absent_posture(ledger, _expected_identity),
    do: paused(ledger, :mismatch, :identity_changed)

  defp inspect_existing(ledger, lstat, hot, expected_identity) do
    with :ok <- require_single_link(lstat),
         :ok <- require_file_mode_0600(lstat),
         {:ok, real} <- resolve_real_path(ledger.path),
         {:ok, _contained} <- contained_in_root(real, ledger.root),
         {:ok, fd} <- open_file(ledger.path, [:raw, :binary, :read]) do
      try do
        classify_open_fd(ledger, fd, lstat, hot, expected_identity)
      after
        _ = close_io_silent(fd)
      end
    else
      {:error, reason} -> paused(ledger, :mismatch, io_reason(reason))
    end
  end

  defp classify_open_fd(ledger, fd, lstat, hot, expected_identity) do
    with {:ok, fstat} <- fstat_io(fd),
         :ok <- require_regular(fstat),
         :ok <- require_stat_pair(lstat, fstat),
         identity = file_identity(fstat),
         :ok <- require_expected_identity(expected_identity, identity),
         {:ok, bound} <- LedgerCore.bound_size(ledger.binding),
         :ok <- require_covers_bound(identity.size, bound),
         :ok <- verify_tip(fd, ledger.binding),
         {:ok, tail} <- read_tail(fd, bound, identity.size) do
      classified(%{ledger | identity: identity}, tail, hot)
    else
      {:error, reason} -> paused(ledger, :mismatch, io_reason(reason))
    end
  end

  defp classified(ledger, <<>>, _hot), do: %{ledger | state: :bound, detail: :none}

  defp classified(ledger, tail, hot) do
    case LedgerCore.classify_tail(ledger.binding, tail, hot_map(hot)) do
      :bound -> %{ledger | state: :bound, detail: :none}
      :bound_orphan -> %{ledger | state: :bound_orphan, detail: :orphan_frame}
      :ahead -> paused(ledger, :ahead, :beyond_bound)
      {:error, reason} -> paused(ledger, :mismatch, reason)
    end
  end

  defp hot_map(hot) when is_function(hot, 0), do: hot.()
  defp hot_map(hot) when is_map(hot), do: hot
  defp hot_map(_hot), do: %{}

  defp paused(ledger, state, detail), do: %{ledger | state: state, detail: detail}

  # ---------------------------------------------------------------------------
  # Append (write at bound)
  # ---------------------------------------------------------------------------

  defp open_for_append(ledger, bound) do
    case File.lstat(ledger.path, time: :posix) do
      {:error, :enoent} when bound == 0 and is_nil(ledger.identity) ->
        create_ledger(ledger.path)

      {:error, :enoent} ->
        {:error, :identity_changed}

      {:ok, %File.Stat{type: :regular} = lstat} ->
        open_existing_rw(ledger, lstat)

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, :symlink_rejected}

      {:ok, %File.Stat{}} ->
        {:error, :not_regular}

      {:error, reason} ->
        {:error, io_reason(reason)}
    end
  end

  defp create_ledger(path) do
    case open_file(path, [:raw, :binary, :read, :write, :exclusive]) do
      {:ok, fd} -> finish_ledger_create(fd, path)
      {:error, :eexist} -> {:error, :identity_changed}
      {:error, reason} -> {:error, io_reason(reason)}
    end
  end

  defp finish_ledger_create(fd, path) do
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
        _ = close_io_silent(fd)
        {:error, io_reason(reason)}
    end
  end

  defp open_existing_rw(ledger, lstat) do
    with :ok <- require_single_link(lstat),
         :ok <- require_file_mode_0600(lstat),
         {:ok, real} <- resolve_real_path(ledger.path),
         {:ok, _contained} <- contained_in_root(real, ledger.root),
         {:ok, fd} <- open_file(ledger.path, [:raw, :binary, :read, :write]) do
      case match_append_fd(fd, lstat, ledger.identity) do
        {:ok, identity} ->
          {:ok, fd, identity}

        {:error, reason} ->
          _ = close_io_silent(fd)
          {:error, io_reason(reason)}
      end
    else
      {:error, reason} -> {:error, io_reason(reason)}
    end
  end

  defp match_append_fd(fd, lstat, expected_identity) do
    with {:ok, fstat} <- fstat_io(fd),
         :ok <- require_regular(fstat),
         :ok <- require_stat_pair(lstat, fstat),
         :ok <- require_single_link(fstat),
         :ok <- require_file_mode_0600(fstat),
         identity = file_identity(fstat),
         :ok <- require_expected_identity(expected_identity, identity) do
      {:ok, identity}
    end
  end

  defp write_at_bound(ledger, fd, identity, bound, frame, hot_delivered) do
    with :ok <- sync_parent_on_first_frame(ledger.path, bound),
         :ok <- require_covers_bound(identity.size, bound),
         :ok <- verify_tip(fd, ledger.binding),
         :ok <- require_overwritable_tail(fd, ledger.binding, bound, identity.size, hot_delivered),
         :ok <- truncate_to_bound(fd, bound, identity.size),
         :ok <- prove_size(fd, identity, bound),
         :ok <- pwrite_frame(fd, bound, frame),
         :ok <- sync_ledger(fd),
         {:ok, proven} <- prove_written(fd, ledger.path, identity, bound + byte_size(frame)) do
      {:ok, %{ledger | identity: proven, detail: :none}}
    else
      {:error, reason} -> {:error, io_reason(reason)}
    end
  end

  # The first frame makes a durable binding point at this file, so its
  # directory entry is fsynced before the journal publication can rename
  # (the journal's known-unsupported directory-fsync classification applies).
  defp sync_parent_on_first_frame(path, 0) do
    case sync_parent(Path.dirname(path)) do
      :ok -> :ok
      {:error, _reason} -> {:error, :dir_sync_failed}
    end
  end

  defp sync_parent_on_first_frame(_path, _bound), do: :ok

  defp require_overwritable_tail(_fd, _binding, bound, size, _hot) when size == bound, do: :ok

  defp require_overwritable_tail(fd, binding, bound, size, hot_delivered) do
    with {:ok, tail} <- read_tail(fd, bound, size) do
      case LedgerCore.classify_tail(binding, tail, hot_delivered) do
        state when state in [:bound, :bound_orphan] -> :ok
        :ahead -> {:error, :ledger_ahead}
        {:error, _reason} -> {:error, :malformed}
      end
    end
  end

  defp truncate_to_bound(fd, bound, size) do
    case truncate_target(bound) do
      {_target, false} when size == bound ->
        :ok

      {target, _forced} ->
        with {:ok, ^target} <- :file.position(fd, target),
             :ok <- :file.truncate(fd) do
          :ok
        else
          {:error, reason} -> {:error, io_reason(reason)}
          _other -> {:error, :truncate_failed}
        end
    end
  end

  defp prove_size(fd, identity, expected_size) do
    with {:ok, fstat} <- fstat_io(fd),
         :ok <- require_same_inode(identity, fstat) do
      require_expected_size(fstat, expected_size)
    end
  end

  defp do_pwrite(fd, offset, frame) do
    case :file.pwrite(fd, offset, frame) do
      :ok -> :ok
      {:error, _reason} -> {:error, :write_failed}
    end
  end

  defp sync_ledger(fd) do
    case :file.sync(fd) do
      :ok -> :ok
      {:error, _reason} -> {:error, :sync_failed}
    end
  end

  defp prove_written(fd, path, identity, expected_size) do
    with {:ok, fstat} <- fstat_io(fd),
         :ok <- require_regular(fstat),
         :ok <- require_expected_identity(identity, file_identity(fstat)),
         :ok <- require_single_link(fstat),
         :ok <- require_file_mode_0600(fstat),
         :ok <- require_expected_size(fstat, expected_size),
         {:ok, lstat} <- lstat_file(path),
         :ok <- require_regular(lstat),
         :ok <- require_same_inode(identity, lstat),
         :ok <- require_stat_pair(fstat, lstat) do
      {:ok, file_identity(fstat)}
    end
  end

  # ---------------------------------------------------------------------------
  # Shared reads and proofs
  # ---------------------------------------------------------------------------

  defp verify_tip(fd, binding) do
    case LedgerCore.tip_range(binding) do
      {:ok, :none} ->
        :ok

      {:ok, {offset, len}} ->
        with {:ok, bytes} <- pread_exact(fd, offset, len) do
          LedgerCore.verify_bound_frame(binding, bytes)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_tail(_fd, bound, size) when size == bound, do: {:ok, <<>>}

  defp read_tail(fd, bound, size) when size > bound do
    pread_exact(fd, bound, min(size - bound, AuditJournalFileCore.max_frame_bytes() + 1))
  end

  defp read_tail(_fd, _bound, _size), do: {:error, :below_bound}

  defp pread_exact(fd, offset, len) do
    case :file.pread(fd, offset, len) do
      {:ok, data} when is_binary(data) and byte_size(data) == len -> {:ok, data}
      {:ok, _short} -> {:error, :read_failed}
      :eof -> {:error, :read_failed}
      {:error, reason} -> {:error, io_reason(reason)}
    end
  end

  defp require_covers_bound(size, bound) when size >= bound, do: :ok
  defp require_covers_bound(_size, _bound), do: {:error, :below_bound}

  # The recorded identity is re-proven on every append; the size is excluded
  # because the ledger legitimately grows (and an unpublished attempt may
  # leave one orphan frame beyond the bound).
  defp require_expected_identity(nil, _identity), do: :ok

  defp require_expected_identity(expected, identity) do
    if Map.delete(expected, :size) == Map.delete(identity, :size),
      do: :ok,
      else: {:error, :identity_changed}
  end

  defp open_file(path, modes) do
    case :file.open(String.to_charlist(path), modes) do
      {:ok, fd} -> {:ok, fd}
      {:error, reason} -> {:error, reason}
    end
  end

  defp io_reason(reason) when is_atom(reason), do: reason
  defp io_reason(_reason), do: :io_error
end
