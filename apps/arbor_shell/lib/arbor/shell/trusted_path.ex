defmodule Arbor.Shell.TrustedPath do
  @moduledoc false

  import Bitwise

  @max_symlinks 40
  @chunk_size 65_536
  @max_file_bytes 512 * 1024 * 1024
  @max_path_bytes 4_096

  defmodule Identity do
    @moduledoc false

    @enforce_keys [
      :path,
      :type,
      :device,
      :inode,
      :size,
      :mtime,
      :ctime,
      :mode,
      :uid,
      :gid,
      :sha256,
      :executable_required
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            path: String.t(),
            type: :regular | :directory,
            device: non_neg_integer(),
            inode: non_neg_integer(),
            size: non_neg_integer(),
            mtime: integer(),
            ctime: integer(),
            mode: non_neg_integer(),
            uid: non_neg_integer(),
            gid: non_neg_integer(),
            sha256: String.t() | nil,
            executable_required: boolean()
          }
  end

  @spec canonicalize_absolute(term()) :: {:ok, String.t()} | {:error, atom()}
  def canonicalize_absolute(path) when is_binary(path) do
    with :ok <- validate_absolute_path(path),
         {:ok, canonical} <- resolve_links(path, 0),
         true <- Path.type(canonical) == :absolute do
      {:ok, canonical}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :path_not_found}
    end
  end

  def canonicalize_absolute(_path), do: {:error, :invalid_path}

  @spec pin_root_owned_regular_file(term(), term()) ::
          {:ok, Identity.t()} | {:error, atom()}
  def pin_root_owned_regular_file(path, opts \\ [])

  def pin_root_owned_regular_file(path, opts) when is_binary(path) do
    with {:ok, executable_required} <- closed_executable_option(opts),
         {:ok, canonical} <- canonicalize_absolute(path),
         :ok <- trusted_path_chain(canonical),
         {:ok, before_stat} <- trusted_regular_stat(canonical, executable_required),
         :ok <- enforce_max_file_size(before_stat.size),
         {:ok, digest} <- hash_regular_file(canonical, before_stat.size),
         {:ok, after_stat} <- trusted_regular_stat(canonical, executable_required),
         true <- stable_identity_stat?(before_stat, after_stat) do
      {:ok, build_identity(canonical, before_stat, digest, executable_required)}
    else
      false -> {:error, :identity_changed}
      {:error, reason} -> {:error, reason}
    end
  end

  def pin_root_owned_regular_file(_path, _opts), do: {:error, :invalid_path}

  @spec pin_root_owned_directory(term()) :: {:ok, Identity.t()} | {:error, atom()}
  def pin_root_owned_directory(path) when is_binary(path) do
    with {:ok, canonical} <- canonicalize_absolute(path),
         :ok <- trusted_path_chain(canonical),
         {:ok, stat} <- trusted_directory_stat(canonical) do
      {:ok, build_identity(canonical, stat, nil, false)}
    end
  end

  def pin_root_owned_directory(_path), do: {:error, :invalid_path}

  @spec verify_pinned(Identity.t()) :: :ok | {:error, atom()}
  def verify_pinned(%Identity{type: :regular, executable_required: executable_required} = pinned) do
    case pin_root_owned_regular_file(pinned.path, executable: executable_required) do
      {:ok, current} ->
        if same_identity?(pinned, current), do: :ok, else: {:error, :identity_mismatch}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def verify_pinned(%Identity{type: :directory} = pinned) do
    case pin_root_owned_directory(pinned.path) do
      {:ok, current} ->
        if same_identity?(pinned, current), do: :ok, else: {:error, :identity_mismatch}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def verify_pinned(_identity), do: {:error, :invalid_identity}

  @spec same_identity?(Identity.t(), Identity.t()) :: boolean()
  def same_identity?(%Identity{} = left, %Identity{} = right) do
    identity_tuple(left) == identity_tuple(right)
  end

  def same_identity?(_left, _right), do: false

  defp closed_executable_option(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      case Enum.reduce_while(opts, {:ok, :absent}, fn
             {:executable, value}, {:ok, :absent} when is_boolean(value) ->
               {:cont, {:ok, value}}

             {:executable, _value}, {:ok, :absent} ->
               {:halt, {:error, :malformed_options}}

             {:executable, _value}, {:ok, _already} ->
               {:halt, {:error, :duplicate_option}}

             {_other, _value}, _acc ->
               {:halt, {:error, :unknown_option}}
           end) do
        {:ok, :absent} -> {:ok, false}
        {:ok, value} when is_boolean(value) -> {:ok, value}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :malformed_options}
    end
  end

  defp closed_executable_option(_opts), do: {:error, :malformed_options}

  defp validate_absolute_path(path) do
    with :ok <- validate_path_text(path) do
      if Path.type(path) == :absolute, do: :ok, else: {:error, :relative_path}
    end
  end

  defp validate_path_text(path) when is_binary(path) do
    cond do
      path == "" -> {:error, :invalid_path}
      byte_size(path) > @max_path_bytes -> {:error, :invalid_path}
      not String.valid?(path) -> {:error, :invalid_path}
      String.contains?(path, <<0>>) -> {:error, :invalid_path}
      true -> :ok
    end
  end

  defp validate_path_text(_path), do: {:error, :invalid_path}

  defp trusted_regular_stat(path, executable_required) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{} = stat} ->
        cond do
          stat.type != :regular ->
            {:error, :not_a_regular_file}

          not trusted_ownership?(stat) ->
            {:error, :untrusted_path}

          executable_required and not executable_mode?(stat.mode) ->
            {:error, :not_executable}

          true ->
            {:ok, stat}
        end

      {:error, :enoent} ->
        {:error, :path_not_found}

      {:error, _reason} ->
        {:error, :path_not_found}
    end
  end

  defp trusted_directory_stat(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{type: :directory} = stat} ->
        if trusted_ownership?(stat), do: {:ok, stat}, else: {:error, :untrusted_path}

      {:ok, %File.Stat{}} ->
        {:error, :not_a_directory}

      {:error, :enoent} ->
        {:error, :path_not_found}

      {:error, _reason} ->
        {:error, :path_not_found}
    end
  end

  defp trusted_path_chain(path) do
    path
    |> Path.dirname()
    |> directory_chain()
    |> Enum.reduce_while(:ok, fn directory, :ok ->
      case File.stat(directory, time: :posix) do
        {:ok, %File.Stat{type: :directory} = stat} ->
          if trusted_ownership?(stat) do
            {:cont, :ok}
          else
            {:halt, {:error, :untrusted_path}}
          end

        _other ->
          {:halt, {:error, :untrusted_path}}
      end
    end)
  end

  defp directory_chain(path) do
    path
    |> Path.split()
    |> Enum.reduce({[], "/"}, fn
      "/", {directories, current} ->
        {directories, current}

      part, {directories, current} ->
        next = Path.join(current, part)
        {[next | directories], next}
    end)
    |> elem(0)
    |> then(&["/" | Enum.reverse(&1)])
    |> Enum.uniq()
  end

  # Agent processes share the service account's filesystem authority. A
  # user-owned path is therefore mutable by the same principal and cannot
  # anchor a trusted identity. Root ownership plus no group/other write
  # permission leaves replacement under operator authority only.
  defp trusted_ownership?(%File.Stat{uid: 0, mode: mode}), do: (mode &&& 0o022) == 0
  defp trusted_ownership?(_stat), do: false

  defp executable_mode?(mode), do: (mode &&& 0o111) != 0

  defp enforce_max_file_size(size) when is_integer(size) and size > @max_file_bytes do
    {:error, :file_too_large}
  end

  defp enforce_max_file_size(_size), do: :ok

  defp hash_regular_file(path, expected_size) do
    case :file.open(path_charlist(path), [:read, :raw, :binary]) do
      {:ok, io} ->
        try do
          hash_chunks(io, :crypto.hash_init(:sha256), 0, expected_size)
        after
          :file.close(io)
        end

      {:error, :enoent} ->
        {:error, :path_not_found}

      {:error, _reason} ->
        {:error, :path_not_found}
    end
  end

  defp hash_chunks(io, acc, read_so_far, expected_size) do
    case :file.read(io, @chunk_size) do
      :eof ->
        if read_so_far == expected_size do
          digest =
            acc
            |> :crypto.hash_final()
            |> Base.encode16(case: :lower)

          {:ok, digest}
        else
          {:error, :identity_changed}
        end

      {:ok, data} ->
        new_size = read_so_far + byte_size(data)

        cond do
          new_size > @max_file_bytes ->
            {:error, :file_too_large}

          new_size > expected_size ->
            {:error, :identity_changed}

          true ->
            hash_chunks(io, :crypto.hash_update(acc, data), new_size, expected_size)
        end

      {:error, _reason} ->
        {:error, :identity_changed}
    end
  end

  defp path_charlist(path) when is_binary(path), do: String.to_charlist(path)

  defp stable_identity_stat?(left, right) do
    identity_stat_fields(left) == identity_stat_fields(right)
  end

  defp identity_stat_fields(%File.Stat{} = stat) do
    {
      stat.type,
      stat.size,
      stat.mode,
      stat.uid,
      stat.gid,
      stat.major_device,
      stat.inode,
      stat.mtime,
      stat.ctime
    }
  end

  defp build_identity(path, %File.Stat{} = stat, sha256, executable_required) do
    %Identity{
      path: path,
      type: stat.type,
      device: stat.major_device,
      inode: stat.inode,
      size: stat.size,
      mtime: stat.mtime,
      ctime: stat.ctime,
      mode: stat.mode,
      uid: stat.uid,
      gid: stat.gid,
      sha256: sha256,
      executable_required: executable_required
    }
  end

  defp identity_tuple(%Identity{} = identity) do
    {
      identity.path,
      identity.type,
      identity.device,
      identity.inode,
      identity.size,
      identity.mtime,
      identity.ctime,
      identity.mode,
      identity.uid,
      identity.gid,
      identity.sha256,
      identity.executable_required
    }
  end

  defp resolve_links(_path, count) when count > @max_symlinks,
    do: {:error, :too_many_symlinks}

  defp resolve_links(path, count) do
    with :ok <- validate_absolute_path(path) do
      parts = Path.split(Path.expand(path))
      walk_parts(parts, "/", count)
    end
  end

  defp walk_parts([], current, _count), do: {:ok, Path.expand(current)}

  defp walk_parts([part | rest], current, count) when part in ["/", ""] do
    walk_parts(rest, current, count)
  end

  defp walk_parts([part | rest], current, count) do
    candidate = Path.join(current, part)

    case File.lstat(candidate) do
      {:ok, %File.Stat{type: :symlink}} ->
        with {:ok, target} <- File.read_link(candidate),
             :ok <- validate_path_text(target) do
          target =
            if Path.type(target) == :absolute,
              do: target,
              else: Path.expand(target, Path.dirname(candidate))

          resolve_links(Path.join([target | rest]), count + 1)
        else
          {:error, :invalid_path} -> {:error, :invalid_path}
          {:error, _reason} -> {:error, :path_not_found}
        end

      {:ok, _stat} ->
        walk_parts(rest, candidate, count)

      {:error, :enoent} ->
        {:error, :path_not_found}

      {:error, _reason} ->
        {:error, :path_not_found}
    end
  end
end
