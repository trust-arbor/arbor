defmodule Arbor.Shell.TrustedBuild.Identity do
  @moduledoc false

  import Bitwise

  alias Arbor.Shell.RegularTreeInventory

  @chunk_size 65_536
  @max_file_bytes 512 * 1024 * 1024
  @max_path_bytes 4_096

  @type file_identity :: %{
          path: String.t(),
          type: :regular,
          device: non_neg_integer(),
          inode: non_neg_integer(),
          size: non_neg_integer(),
          mtime: integer(),
          ctime: integer(),
          mode: non_neg_integer(),
          uid: non_neg_integer(),
          gid: non_neg_integer(),
          sha256: String.t(),
          nlink: non_neg_integer()
        }

  @type dir_identity :: %{
          path: String.t(),
          type: :directory,
          device: non_neg_integer(),
          minor_device: non_neg_integer(),
          inode: non_neg_integer(),
          mode: non_neg_integer(),
          uid: non_neg_integer()
        }

  @spec pin_regular_file(term()) :: {:ok, file_identity()} | {:error, atom()}
  def pin_regular_file(path) when is_binary(path) do
    with :ok <- validate_path(path),
         {:ok, before} <- lstat_regular(path),
         :ok <- reject_group_other_write(before.mode),
         :ok <- require_nlink(before.links, 1),
         :ok <- enforce_max_file_size(before.size),
         {:ok, digest} <- hash_file(path, before.size),
         {:ok, after_stat} <- lstat_regular(path),
         true <- stable_file?(before, after_stat) do
      {:ok, file_identity(path, before, digest)}
    else
      false -> {:error, :identity_changed}
      {:error, reason} -> {:error, reason}
    end
  end

  def pin_regular_file(_path), do: {:error, :invalid_path}

  @spec pin_directory(term()) :: {:ok, dir_identity()} | {:error, atom()}
  def pin_directory(path) when is_binary(path) do
    with :ok <- validate_path(path),
         {:ok, stat} <- lstat_directory(path),
         :ok <- reject_group_other_write(stat.mode) do
      {:ok, dir_identity(path, stat)}
    end
  end

  def pin_directory(_path), do: {:error, :invalid_path}

  @spec pin_writable_directory(term()) :: {:ok, dir_identity()} | {:error, atom()}
  def pin_writable_directory(path) when is_binary(path) do
    with :ok <- validate_path(path),
         {:ok, stat} <- lstat_directory(path),
         :ok <- require_mode(stat.mode, 0o700),
         :ok <- require_owner(stat.uid) do
      {:ok, dir_identity(path, stat)}
    end
  end

  def pin_writable_directory(_path), do: {:error, :invalid_path}

  @spec verify_file(file_identity()) :: :ok | {:error, atom()}
  def verify_file(%{type: :regular, path: path} = pinned) do
    case pin_regular_file(path) do
      {:ok, current} ->
        if same_file?(pinned, current), do: :ok, else: {:error, :identity_mismatch}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def verify_file(_identity), do: {:error, :invalid_identity}

  @spec verify_directory(dir_identity()) :: :ok | {:error, atom()}
  def verify_directory(%{type: :directory, path: path} = pinned) do
    case pin_directory(path) do
      {:ok, current} ->
        if same_dir?(pinned, current), do: :ok, else: {:error, :identity_mismatch}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def verify_directory(_identity), do: {:error, :invalid_identity}

  @spec verify_writable(dir_identity()) :: :ok | {:error, atom()}
  def verify_writable(%{type: :directory, path: path} = pinned) do
    case pin_writable_directory(path) do
      {:ok, current} ->
        if same_dir?(pinned, current), do: :ok, else: {:error, :identity_mismatch}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def verify_writable(_identity), do: {:error, :invalid_identity}

  @spec verify_owned_identity(map()) :: :ok | {:error, atom()}
  def verify_owned_identity(%{
        path: path,
        type: :directory,
        device: device,
        minor_device: minor,
        inode: inode
      }) do
    case File.lstat(path, time: :posix) do
      {:ok,
       %File.Stat{
         type: :directory,
         major_device: ^device,
         minor_device: ^minor,
         inode: ^inode
       }} ->
        :ok

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, :symlink_rejected}

      {:ok, %File.Stat{}} ->
        {:error, :identity_mismatch}

      {:error, :enoent} ->
        {:error, :path_not_found}

      {:error, _reason} ->
        {:error, :stat_failed}
    end
  end

  def verify_owned_identity(_identity), do: {:error, :invalid_identity}

  @spec tree_digest(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def tree_digest(path) when is_binary(path) do
    case RegularTreeInventory.scan_resolved(path) do
      {:ok, facts} -> {:ok, digest_facts(facts)}
      {:error, reason} -> {:error, reason}
    end
  end

  def tree_digest(_path), do: {:error, :invalid_path}

  @spec digest_facts(RegularTreeInventory.facts()) :: String.t()
  def digest_facts(%{directories: directories, regular_files: files}) do
    dir_rows =
      Enum.map(directories, fn %{path: path, mode: mode} ->
        ["d", path, Integer.to_string(mode)]
      end)

    file_rows =
      Enum.map(files, fn %{path: path, mode: mode, sha256: sha, size: size} ->
        ["f", path, Integer.to_string(mode), sha, Integer.to_string(size)]
      end)

    canonical =
      (dir_rows ++ file_rows)
      |> Enum.sort()
      |> Enum.map(&Enum.join(&1, "\0"))
      |> Enum.join("\n")

    :crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower)
  end

  @spec child_of?(String.t(), String.t()) :: boolean()
  def child_of?(parent, child) when is_binary(parent) and is_binary(child) do
    parent_segs = Path.split(parent)
    child_segs = Path.split(child)
    List.starts_with?(child_segs, parent_segs) and child_segs != parent_segs
  end

  def child_of?(_parent, _child), do: false

  @spec overlap?(String.t(), String.t()) :: boolean()
  def overlap?(left, right) when is_binary(left) and is_binary(right) do
    left == right or child_of?(left, right) or child_of?(right, left)
  end

  def overlap?(_left, _right), do: true

  defp lstat_regular(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular} = stat} -> {:ok, stat}
      {:ok, %File.Stat{type: :symlink}} -> {:error, :symlink_rejected}
      {:ok, %File.Stat{}} -> {:error, :not_a_regular_file}
      {:error, :enoent} -> {:error, :path_not_found}
      {:error, _reason} -> {:error, :path_not_found}
    end
  end

  defp lstat_directory(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :directory} = stat} -> {:ok, stat}
      {:ok, %File.Stat{type: :symlink}} -> {:error, :symlink_rejected}
      {:ok, %File.Stat{}} -> {:error, :not_a_directory}
      {:error, :enoent} -> {:error, :path_not_found}
      {:error, _reason} -> {:error, :path_not_found}
    end
  end

  defp reject_group_other_write(mode) when (mode &&& 0o022) == 0, do: :ok
  defp reject_group_other_write(_mode), do: {:error, :untrusted_mode}

  defp require_mode(mode, expected) do
    if (mode &&& 0o777) == expected, do: :ok, else: {:error, :untrusted_mode}
  end

  defp require_owner(uid) do
    case :os.getuid() do
      ^uid -> :ok
      _other -> {:error, :untrusted_owner}
    end
  end

  defp require_nlink(nlink, expected) when nlink == expected, do: :ok
  defp require_nlink(_nlink, _expected), do: {:error, :hardlink_rejected}

  defp enforce_max_file_size(size) when is_integer(size) and size > @max_file_bytes,
    do: {:error, :file_too_large}

  defp enforce_max_file_size(_size), do: :ok

  defp validate_path(path) do
    cond do
      path == "" -> {:error, :invalid_path}
      byte_size(path) > @max_path_bytes -> {:error, :invalid_path}
      not String.valid?(path) -> {:error, :invalid_path}
      String.contains?(path, <<0>>) -> {:error, :invalid_path}
      Path.type(path) != :absolute -> {:error, :invalid_path}
      true -> :ok
    end
  end

  defp hash_file(path, expected_size) do
    case :file.open(String.to_charlist(path), [:read, :raw, :binary]) do
      {:ok, io} ->
        try do
          hash_chunks(io, :crypto.hash_init(:sha256), 0, expected_size)
        after
          :file.close(io)
        end

      {:error, _reason} ->
        {:error, :path_not_found}
    end
  end

  defp hash_chunks(io, acc, read_so_far, expected_size) do
    case :file.read(io, @chunk_size) do
      :eof ->
        if read_so_far == expected_size do
          {:ok, acc |> :crypto.hash_final() |> Base.encode16(case: :lower)}
        else
          {:error, :identity_changed}
        end

      {:ok, data} ->
        new_size = read_so_far + byte_size(data)

        cond do
          new_size > @max_file_bytes -> {:error, :file_too_large}
          new_size > expected_size -> {:error, :identity_changed}
          true -> hash_chunks(io, :crypto.hash_update(acc, data), new_size, expected_size)
        end

      {:error, _reason} ->
        {:error, :identity_changed}
    end
  end

  defp stable_file?(left, right) do
    left.type == right.type and left.size == right.size and left.mode == right.mode and
      left.major_device == right.major_device and left.inode == right.inode and
      left.mtime == right.mtime and left.ctime == right.ctime and left.uid == right.uid and
      left.gid == right.gid and left.links == right.links
  end

  defp file_identity(path, %File.Stat{} = stat, digest) do
    %{
      path: path,
      type: :regular,
      device: stat.major_device,
      inode: stat.inode,
      size: stat.size,
      mtime: stat.mtime,
      ctime: stat.ctime,
      mode: stat.mode,
      uid: stat.uid,
      gid: stat.gid,
      sha256: digest,
      nlink: stat.links
    }
  end

  defp dir_identity(path, %File.Stat{} = stat) do
    %{
      path: path,
      type: :directory,
      device: stat.major_device,
      minor_device: stat.minor_device,
      inode: stat.inode,
      mode: stat.mode,
      uid: stat.uid
    }
  end

  defp same_file?(left, right) do
    left.path == right.path and left.device == right.device and left.inode == right.inode and
      left.size == right.size and left.mtime == right.mtime and left.ctime == right.ctime and
      left.mode == right.mode and left.uid == right.uid and left.gid == right.gid and
      left.sha256 == right.sha256 and left.nlink == right.nlink
  end

  defp same_dir?(left, right) do
    left.path == right.path and left.device == right.device and
      left.minor_device == right.minor_device and left.inode == right.inode and
      left.mode == right.mode and left.uid == right.uid
  end
end
