defmodule Arbor.Security.AuditJournalFileProofs do
  @moduledoc false
  # Filesystem proofs shared by the Security audit journal file
  # (`Arbor.Security.AuditJournalFile`) and its cold retirement ledger
  # (`Arbor.Security.AuditRetirementLedger`). Factored verbatim out of
  # AuditJournalFile so both files obey the exact same containment, lstat/fstat,
  # 0600, single-link, symlink and directory-fsync rules. Internal to
  # arbor_security; not a facade.

  alias Arbor.Common.SafePath
  alias Arbor.Security.AuditJournalFileCore

  @spec contained_in_root(String.t(), String.t()) :: {:ok, String.t()} | {:error, atom()}
  def contained_in_root(path, root) do
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

  @spec resolve_real_path(String.t()) :: {:ok, String.t()} | {:error, term()}
  def resolve_real_path(path) do
    case SafePath.resolve_real(path) do
      {:ok, real} -> {:ok, real}
      {:error, :not_found} -> {:error, :parent_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec lstat_file(String.t()) :: {:ok, File.Stat.t()} | {:error, term()}
  def lstat_file(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :symlink}} -> {:error, :symlink_rejected}
      {:ok, %File.Stat{type: type}} when type != :regular -> {:error, :not_regular}
      {:ok, stat} -> {:ok, stat}
      {:error, :enoent} -> {:error, :identity_changed}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec require_regular(File.Stat.t()) :: :ok | {:error, atom()}
  def require_regular(%File.Stat{type: :regular}), do: :ok
  def require_regular(%File.Stat{type: :symlink}), do: {:error, :symlink_rejected}
  def require_regular(_stat), do: {:error, :not_regular}

  @spec require_single_link(File.Stat.t()) :: :ok | {:error, :hardlink_rejected}
  def require_single_link(%File.Stat{links: 1}), do: :ok
  def require_single_link(%File.Stat{}), do: {:error, :hardlink_rejected}

  @spec require_file_mode_0600(File.Stat.t()) :: :ok | {:error, atom()}
  def require_file_mode_0600(%File.Stat{type: :regular, mode: mode}) do
    if Bitwise.band(mode, 0o777) == 0o600 do
      :ok
    else
      {:error, :insecure_mode}
    end
  end

  def require_file_mode_0600(%File.Stat{type: :symlink}), do: {:error, :symlink_rejected}
  def require_file_mode_0600(_stat), do: {:error, :not_regular}

  @spec require_expected_size(File.Stat.t(), non_neg_integer()) :: :ok | {:error, :size_mismatch}
  def require_expected_size(%File.Stat{size: size}, expected) when size == expected, do: :ok
  def require_expected_size(_stat, _expected), do: {:error, :size_mismatch}

  @spec require_same_inode(map(), File.Stat.t()) :: :ok | {:error, :identity_changed}
  def require_same_inode(identity, %File.Stat{} = stat) when is_map(identity) do
    if identity.major_device == stat.major_device and
         identity.minor_device == stat.minor_device and
         identity.inode == stat.inode do
      :ok
    else
      {:error, :identity_changed}
    end
  end

  @spec require_bound_identity(map(), File.Stat.t()) :: :ok | {:error, :identity_changed}
  def require_bound_identity(identity, %File.Stat{} = stat) do
    if file_identity(stat) == identity do
      :ok
    else
      {:error, :identity_changed}
    end
  end

  @spec require_stat_pair(File.Stat.t(), File.Stat.t()) :: :ok | {:error, :identity_changed}
  def require_stat_pair(%File.Stat{} = left, %File.Stat{} = right) do
    if file_identity(left) == file_identity(right) do
      :ok
    else
      {:error, :identity_changed}
    end
  end

  @spec file_identity(File.Stat.t()) :: map()
  def file_identity(%File.Stat{} = stat) do
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

  @spec chmod_private(String.t()) :: :ok | {:error, term()}
  def chmod_private(path) do
    case File.chmod(path, 0o600) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec fstat_io(:file.io_device()) :: {:ok, File.Stat.t()} | {:error, term()}
  def fstat_io(fd) do
    case :file.read_file_info(fd, time: :posix) do
      {:ok, info} -> {:ok, File.Stat.from_record(info)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  fsync a directory; known-unsupported directory fsync classifies as `:ok`
  (`AuditJournalFileCore.classify_dir_sync/1`), anything else is
  `{:error, :dir_sync_failed}`.
  """
  @spec fsync_directory(String.t()) :: :ok | {:error, :dir_sync_failed}
  def fsync_directory(dir) do
    case :file.open(String.to_charlist(dir), [:raw, :read, :directory]) do
      {:ok, io} ->
        try do
          case :file.sync(io) do
            :ok ->
              AuditJournalFileCore.classify_dir_sync(:ok)

            {:error, reason} ->
              map_dir_sync(AuditJournalFileCore.classify_dir_sync({:error, reason}))
          end
        after
          _ = close_io_silent(io)
        end

      {:error, reason} ->
        map_dir_sync(AuditJournalFileCore.classify_dir_sync({:error, reason}))
    end
  end

  @spec map_dir_sync(term()) :: :ok | {:error, :dir_sync_failed}
  def map_dir_sync(:ok), do: :ok
  def map_dir_sync({:error, _reason}), do: {:error, :dir_sync_failed}

  @spec close_io_silent(term()) :: term()
  def close_io_silent(fd) do
    :file.close(fd)
  catch
    _, _ -> :ok
  end
end
