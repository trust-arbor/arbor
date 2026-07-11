defmodule Arbor.Persistence.Eval.RunIdentity do
  @moduledoc false

  # Captures run-identity fields for eval runs (git sha, dataset hash, config
  # fingerprint). Public access is via Arbor.Persistence only.
  #
  # All capture is best-effort and fail-safe: any failure simply omits the
  # field. Caller-provided values are never overwritten.
  #
  # Dataset hashing opens the path once, hashes bounded chunks from that
  # handle up to the captured initial size, and compares full handle/path
  # identity (type/device/inode/size/mtime/ctime) before and after. Same-inode
  # content mutation, growth past the captured size, and short reads fail
  # closed (return nil). Metadata equality is best-effort under a trusted
  # path assumption — not proof against an owner restoring timestamps.

  @stream_chunk_bytes 65_536

  @spec capture(map()) :: map()
  def capture(attrs) when is_map(attrs) do
    attrs
    |> put_new_lazy_safe(:git_sha, &git_sha/0)
    |> put_new_lazy_safe(:git_dirty, &git_dirty/0)
    |> put_new_lazy_safe(:dataset_hash, fn -> dataset_hash(attrs[:dataset]) end)
    |> put_new_lazy_safe(:config_fingerprint, fn -> config_fingerprint(attrs[:config]) end)
  end

  @spec git_sha() :: String.t() | nil
  def git_sha do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @spec git_dirty() :: boolean() | nil
  def git_dirty do
    case System.cmd("git", ["status", "--porcelain"], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out) != ""
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc """
  SHA-256 (hex, \"sha256:\" prefixed) of the dataset file at `path`.

  Opens the path once, hashes bounded chunks from that handle up to the
  captured initial size, and compares full handle/path identity (type, device,
  inode, size, mtime, ctime) before and after. Rejects symlinks, non-regular
  files, unusable inode identities, growth past the captured size, short
  reads, and same-inode mutation. Closes the handle on every path.

  Metadata checks use OTP posix timestamps (native resolution exposed by the
  pinned OTP File.Stat API) and are best-effort — not proof against an owner
  restoring timestamps after mutation.
  """
  @spec dataset_hash(String.t() | nil) :: String.t() | nil
  def dataset_hash(nil), do: nil

  def dataset_hash(path) when is_binary(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular} = stat} ->
        case regular_identity(stat) do
          {:ok, expected} ->
            hash_regular_file(path, expected)

          {:error, _} ->
            nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  def dataset_hash(_), do: nil

  @doc """
  Deterministic SHA-256 fingerprint of a config map (nil for nil/empty).

  Uses a JSON-clean canonical encoding with recursively sorted keys as an
  ordered representation (Jason.OrderedObject) so fingerprints never depend
  on unordered Map iteration. Atom/string key collisions are rejected (nil).
  """
  @spec config_fingerprint(map() | nil) :: String.t() | nil
  def config_fingerprint(nil), do: nil
  def config_fingerprint(config) when config == %{}, do: nil

  def config_fingerprint(config) when is_map(config) do
    case canonical_json(config) do
      {:ok, json} ->
        "sha256:" <> Base.encode16(:crypto.hash(:sha256, json), case: :lower)

      :error ->
        nil
    end
  rescue
    _ -> nil
  end

  def config_fingerprint(_), do: nil

  defp put_new_lazy_safe(attrs, key, fun) do
    if Map.has_key?(attrs, key) do
      attrs
    else
      case fun.() do
        nil -> attrs
        value -> Map.put(attrs, key, value)
      end
    end
  rescue
    _ -> attrs
  end

  # ---------------------------------------------------------------------------
  # Dataset hash — single open, chunked to captured size, full identity
  # ---------------------------------------------------------------------------

  defp hash_regular_file(path, expected) do
    case :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
      {:ok, io} ->
        try do
          with {:ok, info1} <- :file.read_file_info(io, time: :posix),
               stat1 = File.Stat.from_record(info1),
               {:ok, id1} <- regular_identity(stat1),
               true <- identity_match?(id1, expected),
               {:ok, digest} <- hash_exact_size(io, expected.size),
               {:ok, info2} <- :file.read_file_info(io, time: :posix),
               stat2 = File.Stat.from_record(info2),
               {:ok, id2} <- regular_identity(stat2),
               true <- identity_match?(id2, expected),
               {:ok, lstat} <- File.lstat(path, time: :posix),
               {:ok, id3} <- regular_identity(lstat),
               true <- identity_match?(id3, expected) do
            "sha256:" <> Base.encode16(:crypto.hash_final(digest), case: :lower)
          else
            _ -> nil
          end
        after
          :file.close(io)
        end

      {:error, _} ->
        nil
    end
  end

  # Hash exactly `size` bytes from the handle. Stop at the captured initial
  # size; reject short reads; probe one extra byte to reject growth.
  defp hash_exact_size(io, size) when is_integer(size) and size >= 0 do
    case hash_n_bytes(io, size, :crypto.hash_init(:sha256)) do
      {:ok, digest} ->
        case :file.read(io, 1) do
          :eof ->
            {:ok, digest}

          {:ok, <<>>} ->
            {:ok, digest}

          {:ok, _} ->
            # File grew past captured size during read.
            {:error, :file_changed}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, _} = err ->
        err
    end
  end

  defp hash_exact_size(_, _), do: {:error, :unusable_size}

  defp hash_n_bytes(_io, 0, acc), do: {:ok, acc}

  defp hash_n_bytes(io, remaining, acc) when remaining > 0 do
    chunk_size = min(remaining, @stream_chunk_bytes)

    case :file.read(io, chunk_size) do
      {:ok, chunk} when byte_size(chunk) == chunk_size ->
        hash_n_bytes(io, remaining - chunk_size, :crypto.hash_update(acc, chunk))

      {:ok, chunk} when byte_size(chunk) < chunk_size ->
        _ = chunk
        {:error, :short_read}

      :eof ->
        {:error, :short_read}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp regular_identity(%File.Stat{type: :regular, inode: inode, major_device: major} = stat)
       when is_integer(inode) and inode > 0 and is_integer(major) do
    {:ok,
     %{
       type: :regular,
       inode: inode,
       major_device: major,
       minor_device: stat.minor_device,
       size: stat.size,
       mtime: stat.mtime,
       ctime: stat.ctime
     }}
  end

  defp regular_identity(%File.Stat{type: :symlink}), do: {:error, :symlink}
  defp regular_identity(%File.Stat{}), do: {:error, :not_regular}
  defp regular_identity(_), do: {:error, :unusable_inode}

  defp identity_match?(a, b) when is_map(a) and is_map(b) do
    a.type == b.type and a.inode == b.inode and a.major_device == b.major_device and
      a.minor_device == b.minor_device and a.size == b.size and a.mtime == b.mtime and
      a.ctime == b.ctime
  end

  defp identity_match?(_, _), do: false

  # ---------------------------------------------------------------------------
  # Canonical config fingerprint — ordered, collision-rejecting
  # ---------------------------------------------------------------------------

  defp canonical_json(value) do
    case canonicalize(value) do
      {:ok, clean} -> encode_canonical(clean)
      :error -> :error
    end
  end

  # Returns nested structure of Jason.OrderedObject / lists / scalars.
  # Never re-materializes objects as unordered Map.
  defp canonicalize(map) when is_map(map) do
    Enum.reduce_while(map, {:ok, MapSet.new(), []}, fn {k, v}, {:ok, seen, acc} ->
      key =
        cond do
          is_binary(k) and String.valid?(k) -> k
          is_atom(k) -> Atom.to_string(k)
          true -> nil
        end

      cond do
        is_nil(key) ->
          {:halt, :error}

        MapSet.member?(seen, key) ->
          # Atom/string alias collision (or duplicate string keys)
          {:halt, :error}

        true ->
          case canonicalize(v) do
            {:ok, cv} ->
              {:cont, {:ok, MapSet.put(seen, key), [{key, cv} | acc]}}

            :error ->
              {:halt, :error}
          end
      end
    end)
    |> case do
      {:ok, _seen, pairs} ->
        ordered =
          pairs
          |> Enum.sort_by(&elem(&1, 0))
          |> Jason.OrderedObject.new()

        {:ok, ordered}

      :error ->
        :error
    end
  end

  defp canonicalize(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case canonicalize(item) do
        {:ok, c} -> {:cont, {:ok, [c | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      :error -> :error
    end
  end

  defp canonicalize(v) when is_binary(v) do
    if String.valid?(v), do: {:ok, v}, else: :error
  end

  defp canonicalize(v) when is_number(v) or is_boolean(v) or is_nil(v), do: {:ok, v}
  defp canonicalize(a) when is_atom(a), do: {:ok, Atom.to_string(a)}
  defp canonicalize(_), do: :error

  defp encode_canonical(value) do
    case Jason.encode(value) do
      {:ok, json} -> {:ok, json}
      {:error, _} -> :error
    end
  end
end
