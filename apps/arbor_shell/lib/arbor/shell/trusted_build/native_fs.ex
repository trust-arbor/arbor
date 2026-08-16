defmodule Arbor.Shell.TrustedBuild.NativeFs do
  @moduledoc false

  alias Arbor.Shell.TrustedBuild.NativeOverlay

  @timeout_ms 5_000
  @max_descriptor_bytes 256 * 1024
  @max_identity_bytes 512

  @exit_reasons %{
    64 => :invalid_identity,
    65 => :path_not_found,
    66 => :symlink_rejected,
    67 => :hardlink_rejected,
    68 => :not_a_regular_file,
    69 => :identity_changed,
    70 => :identity_mismatch,
    71 => :identity_mismatch,
    126 => :trusted_build_unavailable
  }

  @spec read_descriptor(map(), String.t(), non_neg_integer(), String.t()) ::
          {:ok, binary()} | {:error, atom()}
  def read_descriptor(root, selector, size, digest)
      when is_binary(selector) and is_integer(size) and size >= 0 and
             size <= @max_descriptor_bytes and is_binary(digest) do
    with {:ok, root_args} <- root_args(root),
         true <- byte_size(digest) == 64,
         {:ok, bytes} <-
           invoke(
             ["trusted-build-post-phase-read" | root_args] ++
               [selector, Integer.to_string(size), digest],
             size
           ),
         true <- byte_size(bytes) == size do
      {:ok, bytes}
    else
      false -> {:error, :identity_changed}
      {:error, reason} -> {:error, reason}
    end
  end

  def read_descriptor(_root, _selector, _size, _digest),
    do: {:error, :invalid_identity}

  @spec pin_native_overlay(map(), non_neg_integer(), String.t()) ::
          {:ok, map()} | {:error, atom()}
  def pin_native_overlay(root, size, digest)
      when is_integer(size) and size >= 0 and size <= @max_descriptor_bytes and
             is_binary(digest) do
    with {:ok, root_args} <- root_args(root),
         true <- byte_size(digest) == 64,
         {:ok, output} <-
           invoke(
             ["trusted-build-post-phase-pin-native" | root_args] ++
               [Integer.to_string(size), digest],
             @max_identity_bytes
           ),
         {:ok, identity} <- decode_native_identity(output, root.path, digest) do
      {:ok, identity}
    else
      false -> {:error, :invalid_identity}
      {:error, reason} -> {:error, reason}
    end
  end

  def pin_native_overlay(_root, _size, _digest), do: {:error, :invalid_identity}

  @spec quarantine_cookie(map()) :: :ok | {:error, atom()}
  def quarantine_cookie(root) do
    with {:ok, root_args} <- root_args(root),
         {:ok, ""} <-
           invoke(
             ["trusted-build-post-phase-quarantine-cookie" | root_args],
             0
           ) do
      :ok
    else
      {:ok, _unexpected_output} -> {:error, :identity_changed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp root_args(%{
         type: :directory,
         device: device,
         inode: inode,
         path: path
       })
       when is_integer(device) and device >= 0 and is_integer(inode) and inode >= 0 and
              is_binary(path) do
    {:ok, [Integer.to_string(device), Integer.to_string(inode), path]}
  end

  defp root_args(_root), do: {:error, :invalid_identity}

  defp decode_native_identity(output, root_path, digest) do
    with [device, inode, size, mtime, ctime, mode, uid, gid, nlink] <-
           String.split(output, "\n", trim: true),
         {:ok, device} <- parse_non_negative(device),
         {:ok, inode} <- parse_non_negative(inode),
         {:ok, size} <- parse_non_negative(size),
         {:ok, mtime} <- parse_integer(mtime),
         {:ok, ctime} <- parse_integer(ctime),
         {:ok, mode} <- parse_non_negative(mode),
         {:ok, uid} <- parse_non_negative(uid),
         {:ok, gid} <- parse_non_negative(gid),
         {:ok, nlink} <- parse_non_negative(nlink) do
      {:ok,
       %{
         path: Path.join(root_path, NativeOverlay.dest_rel()),
         type: :regular,
         device: device,
         inode: inode,
         size: size,
         mtime: mtime,
         ctime: ctime,
         mode: mode,
         uid: uid,
         gid: gid,
         sha256: digest,
         nlink: nlink
       }}
    else
      _other -> {:error, :identity_changed}
    end
  end

  defp parse_non_negative(value) do
    case parse_integer(value) do
      {:ok, integer} when integer >= 0 -> {:ok, integer}
      _other -> {:error, :identity_changed}
    end
  end

  defp parse_integer(value) do
    case Integer.parse(value) do
      {integer, ""} -> {:ok, integer}
      _other -> {:error, :identity_changed}
    end
  end

  defp invoke(args, max_output) do
    with {:ok, launcher} <- launcher_path() do
      try do
        port =
          Port.open({:spawn_executable, to_charlist(launcher)}, [
            :binary,
            :exit_status,
            args: Enum.map(args, &to_charlist/1)
          ])

        deadline = System.monotonic_time(:millisecond) + @timeout_ms
        collect(port, [], 0, max_output, deadline)
      catch
        :error, _reason -> {:error, :trusted_build_post_phase_launch_failed}
      end
    end
  end

  defp collect(port, chunks, size, max_output, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} when is_binary(data) ->
        next_size = size + byte_size(data)

        if next_size <= max_output do
          collect(port, [data | chunks], next_size, max_output, deadline)
        else
          close_port(port)
          {:error, :trusted_build_descriptor_unbounded}
        end

      {^port, {:exit_status, 0}} ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      {^port, {:exit_status, status}} ->
        {:error, Map.get(@exit_reasons, status, :identity_mismatch)}
    after
      remaining ->
        close_port(port)
        {:error, :trusted_build_post_phase_timeout}
    end
  end

  defp close_port(port) do
    if Port.info(port) != nil do
      try do
        Port.close(port)
      catch
        :error, _reason -> :ok
      end
    end

    receive do
      {^port, {:exit_status, _status}} -> :ok
      {^port, {:data, _data}} -> close_port(port)
    after
      100 -> :ok
    end
  end

  defp launcher_path do
    case :code.priv_dir(:arbor_shell) do
      path when is_list(path) ->
        launcher = Path.join(List.to_string(path), "arbor_shell_launcher")

        case File.lstat(launcher, time: :posix) do
          {:ok, %File.Stat{type: :regular}} -> {:ok, launcher}
          _other -> {:error, :trusted_build_unavailable}
        end

      _other ->
        {:error, :trusted_build_unavailable}
    end
  end
end
