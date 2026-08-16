defmodule Arbor.Commands.SafeRecoveryArtifact.Overlay do
  @moduledoc false

  alias Arbor.Common.SafePath

  @spec descriptor() :: map()
  def descriptor, do: Arbor.Shell.trusted_build_native_overlay_descriptor()

  @spec logical_path() :: String.t()
  def logical_path, do: descriptor()["logical_path"]

  @spec source_path() :: String.t()
  def source_path, do: logical_path()

  @spec staging_rel() :: String.t()
  def staging_rel, do: descriptor()["staging_rel"]

  @spec sha256() :: String.t()
  def sha256, do: descriptor()["sha256"]

  @spec size() :: pos_integer()
  def size, do: descriptor()["size"]

  @spec bind(String.t()) ::
          {:ok, %{path: String.t(), sha256: String.t(), bytes: binary()}} | {:error, term()}
  def bind(root) when is_binary(root) do
    bind_expected(root, size(), sha256())
  end

  def bind(_root), do: {:error, :invalid_root}

  @spec bind_expected(String.t(), pos_integer(), String.t()) ::
          {:ok, %{path: String.t(), sha256: String.t(), bytes: binary()}} | {:error, term()}
  def bind_expected(root, expected_size, expected_sha256)
      when is_binary(root) and is_integer(expected_size) and expected_size > 0 and
             is_binary(expected_sha256) do
    with {:ok, root} <- admit_overlay_root(root),
         {:ok, path} <- resolve_overlay_path(root),
         {:ok, bytes} <- read_regular_file(path, expected_size) do
      digest = sha256_hex(bytes)

      cond do
        byte_size(bytes) != expected_size ->
          {:error, :overlay_digest_mismatch}

        digest != expected_sha256 ->
          {:error, :overlay_digest_mismatch}

        true ->
          {:ok, %{path: logical_path(), sha256: digest, bytes: bytes}}
      end
    end
  end

  def bind_expected(_root, _size, _digest), do: {:error, :overlay_digest_mismatch}

  defp admit_overlay_root(root) when is_binary(root) do
    case File.lstat(root) do
      {:ok, %File.Stat{type: :directory}} ->
        case SafePath.resolve_real(root) do
          {:ok, real} -> {:ok, real}
          _other -> {:error, :overlay_missing}
        end

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, :overlay_not_regular}

      {:ok, %File.Stat{}} ->
        {:error, :overlay_not_regular}

      {:error, :enoent} ->
        {:error, :overlay_missing}

      {:error, _reason} ->
        {:error, :overlay_missing}
    end
  end

  defp resolve_overlay_path(root) do
    with {:ok, lexical} <- SafePath.safe_join(root, logical_path()),
         true <- SafePath.within?(lexical, root),
         :ok <- verify_ancestors(root, lexical),
         {:ok, %File.Stat{type: :regular, links: 1}} <- File.lstat(lexical) do
      {:ok, lexical}
    else
      {:error, :enoent} ->
        {:error, :overlay_missing}

      {:ok, %File.Stat{type: :regular, links: links}} when links != 1 ->
        {:error, :overlay_not_regular}

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, :overlay_not_regular}

      {:ok, %File.Stat{}} ->
        {:error, :overlay_not_regular}

      false ->
        {:error, :overlay_missing}

      {:error, :not_found} ->
        {:error, :overlay_missing}

      {:error, reason} when is_atom(reason) ->
        {:error, reason}

      {:error, _} ->
        {:error, :overlay_missing}
    end
  end

  defp verify_ancestors(root, file_path) do
    parent = Path.dirname(file_path)
    rel = Path.relative_to(parent, root)

    segments =
      cond do
        rel == parent -> []
        rel == "." -> []
        true -> Path.split(rel)
      end

    walk_ancestors(root, root, segments)
  end

  defp walk_ancestors(root, current, []) do
    case File.lstat(current) do
      {:error, :enoent} ->
        {:error, :overlay_missing}

      {:ok, %File.Stat{type: :directory}} ->
        case SafePath.resolve_real(current) do
          {:ok, real} ->
            if SafePath.within?(real, root), do: :ok, else: {:error, :overlay_not_regular}

          _other ->
            {:error, :overlay_not_regular}
        end

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, :overlay_not_regular}

      _other ->
        {:error, :overlay_not_regular}
    end
  end

  defp walk_ancestors(root, current, [segment | rest]) do
    next = Path.join(current, segment)

    case File.lstat(next) do
      {:error, :enoent} ->
        {:error, :overlay_missing}

      {:ok, %File.Stat{type: :directory}} ->
        case SafePath.resolve_real(next) do
          {:ok, real} ->
            if SafePath.within?(real, root) do
              walk_ancestors(root, next, rest)
            else
              {:error, :overlay_not_regular}
            end

          _other ->
            {:error, :overlay_not_regular}
        end

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, :overlay_not_regular}

      _other ->
        {:error, :overlay_not_regular}
    end
  end

  defp read_regular_file(path, expected_size) do
    case :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
      {:ok, io} ->
        try do
          with {:ok, opened} <- descriptor_identity(io),
               :ok <- verify_path_identity(path, opened),
               {:ok, bytes} <- read_descriptor(io, expected_size),
               {:ok, final} <- descriptor_identity(io),
               true <- final == opened,
               :ok <- verify_path_identity(path, final) do
            {:ok, bytes}
          else
            false -> {:error, :overlay_changed_during_read}
            {:error, _} = error -> error
          end
        after
          :file.close(io)
        end

      {:error, :enoent} ->
        {:error, :overlay_missing}

      {:error, :eisdir} ->
        {:error, :overlay_not_regular}

      {:error, _reason} ->
        {:error, :overlay_missing}
    end
  end

  defp descriptor_identity(io) do
    case :file.read_file_info(io, time: :posix) do
      {:ok, info} -> info |> File.Stat.from_record() |> regular_identity()
      {:error, _reason} -> {:error, :overlay_changed_during_read}
    end
  end

  defp verify_path_identity(path, expected) do
    case File.lstat(path, time: :posix) do
      {:ok, stat} ->
        case regular_identity(stat) do
          {:ok, ^expected} -> :ok
          {:ok, _other} -> {:error, :overlay_changed_during_read}
          {:error, reason} -> {:error, reason}
        end

      {:error, :enoent} ->
        {:error, :overlay_missing}

      {:error, _reason} ->
        {:error, :overlay_changed_during_read}
    end
  end

  defp regular_identity(%File.Stat{type: :regular, links: 1} = stat) do
    {:ok,
     %{
       type: stat.type,
       inode: stat.inode,
       major_device: stat.major_device,
       minor_device: stat.minor_device,
       size: stat.size,
       mtime: stat.mtime,
       ctime: stat.ctime
     }}
  end

  defp regular_identity(%File.Stat{type: :regular, links: links}) when links != 1,
    do: {:error, :overlay_not_regular}

  defp regular_identity(%File.Stat{}), do: {:error, :overlay_not_regular}

  defp read_descriptor(io, expected_size) do
    case :file.read(io, expected_size + 1) do
      {:ok, bytes} when byte_size(bytes) > expected_size ->
        {:error, :overlay_too_large}

      {:ok, bytes} ->
        {:ok, bytes}

      :eof ->
        {:ok, ""}

      {:error, _reason} ->
        {:error, :overlay_changed_during_read}
    end
  end

  defp sha256_hex(bytes) do
    :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  end
end
