defmodule Arbor.Security.AuditJournalFile do
  @moduledoc """
  Imperative append-and-sync file log for v1 Security authority-mutation records.

  Binds a regular single-link 0600 file under a caller-supplied canonical
  Security root, replays frames through `Arbor.Security.AuditJournalFileCore`,
  and acknowledges an append only after a complete frame is written, file-synced,
  and post-sync fstat-proven.

  Not a GenServer and not a generic store. Single-writer is assumed, not
  enforced. Claims explicit file-sync of the log FD plus the post-sync proof —
  not directory fsync, hostile same-UID tamper resistance, or distributed
  linearizability.
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

    defp put_inject(key, value) do
      current = Process.get(@inject_key, %{})
      Process.put(@inject_key, Map.put(current, key, value))
      :ok
    end

    defp inject(key) do
      Process.get(@inject_key, %{}) |> Map.get(key, :absent)
    end
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

  defp persist_frame(handle, core, frame, digest) do
    offset = handle.offset

    case write_frame(handle.fd, offset, frame) do
      {:error, {:not_committed, _reason}} = err ->
        invalidate(handle)
        err

      {:error, reason} ->
        invalidate(handle)
        {:error, {:not_committed, reason}}

      :ok ->
        prove_commit(handle, core, frame, digest, offset)
    end
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
          take = min(byte_count, byte_size(frame))
          part = binary_part(frame, 0, take)
          _ = :file.pwrite(fd, offset, part)
          {:error, {:not_committed, :write_failed}}
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
  else
    defp write_frame(fd, offset, frame), do: pwrite_all(fd, offset, frame)

    defp sync_and_prove(handle, expected_size) do
      case sync_fd(handle.fd) do
        :ok -> prove_identity_after_sync(handle, expected_size)
        {:error, reason} -> {:error, {:commit_uncertain, reason}}
      end
    end
  end

  defp prove_identity_after_sync(handle, expected_size) do
    with {:ok, fstat} <- fstat_io(handle.fd),
         :ok <- require_regular(fstat),
         :ok <- require_same_inode(handle.identity, fstat),
         :ok <- require_single_link(fstat),
         :ok <- require_file_mode_0600(fstat),
         :ok <- require_expected_size(fstat, expected_size),
         {:ok, lstat} <- lstat_file(handle.path),
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
    if identity.major_device == stat.major_device and identity.inode == stat.inode do
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
