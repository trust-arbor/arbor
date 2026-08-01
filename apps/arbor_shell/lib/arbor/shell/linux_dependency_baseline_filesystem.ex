defmodule Arbor.Shell.LinuxDependencyBaselineFilesystem do
  @moduledoc false

  alias Arbor.Common.SafePath

  @chunk_size 65_536

  @doc false
  @spec read_regular_file(String.t(), pos_integer()) ::
          {:ok, binary()} | {:error, term()}
  def read_regular_file(path, max_bytes)
      when is_binary(path) and is_integer(max_bytes) and max_bytes > 0 do
    case stream_regular_file(path, max_bytes, [], fn chunk, acc ->
           {:ok, [chunk | acc]}
         end) do
      {:ok, chunks} -> {:ok, IO.iodata_to_binary(Enum.reverse(chunks))}
      {:error, reason} -> {:error, reason}
    end
  end

  def read_regular_file(_path, _max_bytes), do: {:error, :invalid_regular_file}

  @doc false
  @spec hash_regular_file(String.t(), pos_integer()) ::
          {:ok, %{sha256: String.t(), prefix: binary(), size: non_neg_integer()}}
          | {:error, term()}
  def hash_regular_file(path, max_bytes)
      when is_binary(path) and is_integer(max_bytes) and max_bytes > 0 do
    initial = %{hash: :crypto.hash_init(:sha256), prefix: <<>>, size: 0}

    case stream_regular_file(path, max_bytes, initial, fn chunk, state ->
           {:ok,
            %{
              hash: :crypto.hash_update(state.hash, chunk),
              prefix: prefix(state.prefix, chunk),
              size: state.size + byte_size(chunk)
            }}
         end) do
      {:ok, %{hash: hash, prefix: prefix, size: size}} ->
        {:ok,
         %{
           sha256: hash |> :crypto.hash_final() |> Base.encode16(case: :lower),
           prefix: prefix,
           size: size
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def hash_regular_file(_path, _max_bytes), do: {:error, :invalid_regular_file}

  @doc false
  @spec device_identity(File.Stat.t()) :: {non_neg_integer(), non_neg_integer()}
  def device_identity(%File.Stat{} = stat), do: {stat.major_device, stat.minor_device}

  @doc false
  @spec same_device?(File.Stat.t(), File.Stat.t()) :: boolean()
  def same_device?(%File.Stat{} = left, %File.Stat{} = right) do
    {left.major_device, left.minor_device} == {right.major_device, right.minor_device}
  end

  def same_device?(_left, _right), do: false

  @doc false
  @spec same_identity?(File.Stat.t(), File.Stat.t()) :: boolean()
  def same_identity?(%File.Stat{} = left, %File.Stat{} = right) do
    left.type == right.type and
      left.size == right.size and
      left.mode == right.mode and
      left.links == right.links and
      same_device?(left, right) and
      left.inode == right.inode and
      left.mtime == right.mtime and
      left.ctime == right.ctime and
      left.uid == right.uid and
      left.gid == right.gid
  end

  def same_identity?(_left, _right), do: false

  @doc false
  @spec resolve_source_root(String.t()) :: {:ok, String.t()} | {:error, term()}
  def resolve_source_root(path) when is_binary(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :symlink}} ->
        {:error, :symlink_rejected}

      {:ok, %File.Stat{type: :directory}} ->
        case SafePath.resolve_real(path) do
          {:ok, resolved} -> {:ok, resolved}
          {:error, :not_found} -> {:error, :source_not_found}
          {:error, _reason} -> {:error, :source_root_resolution_failed}
        end

      {:ok, %File.Stat{}} ->
        {:error, :invalid_source_root}

      {:error, :enoent} ->
        {:error, :source_not_found}

      {:error, _reason} ->
        {:error, :source_root_resolution_failed}
    end
  end

  def resolve_source_root(_path), do: {:error, :invalid_source_root}

  @doc false
  @spec reject_symlink_ancestors(String.t()) :: :ok | {:error, term()}
  def reject_symlink_ancestors(path) when is_binary(path) do
    Path.split(path)
    |> Enum.reduce_while({:ok, nil}, fn
      "/", {:ok, _current} ->
        {:cont, {:ok, "/"}}

      component, {:ok, current} when is_binary(current) ->
        candidate = Path.join(current, component)

        case File.lstat(candidate, time: :posix) do
          {:ok, %File.Stat{type: :directory}} ->
            {:cont, {:ok, candidate}}

          {:ok, %File.Stat{type: :symlink}} ->
            {:halt, {:error, :symlink_rejected}}

          {:ok, %File.Stat{}} ->
            {:halt, {:error, :invalid_source_root}}

          {:error, :enoent} ->
            {:halt, {:error, :source_not_found}}

          {:error, _reason} ->
            {:halt, {:error, :source_stat_failed}}
        end
    end)
    |> case do
      {:ok, _current} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def reject_symlink_ancestors(_path), do: {:error, :invalid_source_root}

  @doc false
  def __test_set_before_open_hook__(fun) when is_function(fun, 1) do
    Process.put({__MODULE__, :before_open_hook}, fun)
    :ok
  end

  def __test_set_before_open_hook__(nil) do
    Process.delete({__MODULE__, :before_open_hook})
    :ok
  end

  defp stream_regular_file(path, max_bytes, acc, consumer)
       when is_binary(path) and is_integer(max_bytes) and max_bytes > 0 and
              is_function(consumer, 2) do
    with {:ok, before} <- lstat_regular(path, max_bytes),
         :ok <- maybe_before_open_hook(path),
         {:ok, io} <- open_read(path),
         {:ok, opened} <- descriptor_stat(io),
         :ok <- match_identity(before, opened) do
      try do
        result = stream_chunks(io, before.size, 0, acc, consumer)

        case result do
          {:ok, next_acc} ->
            with {:ok, after_stat} <- descriptor_stat(io),
                 :ok <- match_identity(before, after_stat) do
              {:ok, next_acc}
            end

          {:error, reason} ->
            {:error, reason}
        end
      after
        _ = :file.close(io)
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp lstat_regular(path, max_bytes) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular, links: 1, size: size} = stat}
      when is_integer(size) and size >= 0 and size <= max_bytes ->
        {:ok, stat}

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, :symlink_rejected}

      {:ok, %File.Stat{type: :regular}} ->
        {:error, :file_too_large_or_hardlinked}

      {:ok, %File.Stat{}} ->
        {:error, :unsupported_source_entry_type}

      {:error, :enoent} ->
        {:error, :source_not_found}

      {:error, _reason} ->
        {:error, :source_stat_failed}
    end
  end

  defp open_read(path) do
    case :file.open(String.to_charlist(path), [:read, :raw, :binary]) do
      {:ok, io} -> {:ok, io}
      {:error, _reason} -> {:error, :source_open_failed}
    end
  end

  defp descriptor_stat(io) do
    case :file.read_file_info(io, time: :posix) do
      {:ok, info} -> {:ok, File.Stat.from_record(info)}
      {:error, _reason} -> {:error, :source_fstat_failed}
    end
  end

  defp match_identity(before, after_stat) do
    if same_identity?(before, after_stat), do: :ok, else: {:error, :source_changed}
  end

  defp stream_chunks(io, expected_size, read_size, acc, consumer) do
    case :file.read(io, @chunk_size) do
      :eof when read_size == expected_size ->
        {:ok, acc}

      :eof ->
        {:error, :source_changed}

      {:ok, chunk} when is_binary(chunk) and byte_size(chunk) > 0 ->
        new_size = read_size + byte_size(chunk)

        if new_size > expected_size do
          {:error, :source_changed}
        else
          case consumer.(chunk, acc) do
            {:ok, next_acc} -> stream_chunks(io, expected_size, new_size, next_acc, consumer)
            {:error, reason} -> {:error, reason}
            _other -> {:error, :invalid_file_consumer_result}
          end
        end

      {:ok, _empty} ->
        {:error, :source_changed}

      {:error, _reason} ->
        {:error, :source_read_failed}
    end
  end

  defp prefix(prefix, _chunk) when byte_size(prefix) >= 20, do: prefix

  defp prefix(prefix, chunk) do
    wanted = min(20 - byte_size(prefix), byte_size(chunk))
    prefix <> binary_part(chunk, 0, wanted)
  end

  defp maybe_before_open_hook(path) do
    case Process.get({__MODULE__, :before_open_hook}) do
      fun when is_function(fun, 1) ->
        _ = fun.(path)
        :ok

      _ ->
        :ok
    end
  end
end
