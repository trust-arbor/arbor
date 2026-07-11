defmodule Arbor.Persistence.Eval.RunIdentity do
  @moduledoc false

  # Captures run-identity fields for eval runs (git sha, dataset hash, config
  # fingerprint). Public access is via Arbor.Persistence only.
  #
  # All capture is best-effort and fail-safe: any failure simply omits the
  # field. Caller-provided values are never overwritten.
  #
  # Dataset hashing opens the path once and requires **stable content across
  # two complete passes from the same handle**: hash captured exact size →
  # EOF-probe → seek BOF → hash a second full pass → require equal digests
  # and full handle/path identity (type/device/inode/size/mtime/ctime).
  #
  # This is a bounded stable-content check under a trusted-path contract, not
  # a claim of hostile atomic snapshots. An owner restoring *identical* bytes
  # between passes is semantically unchanged (digests match). Metadata
  # equality uses OTP posix second-resolution timestamps and is best-effort.

  @stream_chunk_bytes 65_536
  @stable_read_pass_one_event [:arbor, :persistence, :eval, :stable_read, :pass_one]

  # config_fingerprint canonicalization ceilings (public helper must not
  # recurse/materialize without a system ceiling).
  @max_fp_depth 32
  @max_fp_nodes 50_000
  @max_fp_keys 10_000
  @max_fp_string_bytes 1_048_576
  @max_fp_estimated_bytes 1_048_576
  @max_fp_integer_bits 1_000_000
  @max_fp_integer_bytes div(@max_fp_integer_bits + 7, 8)

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

  Opens the path once. Hashes the captured exact size from that handle,
  EOF-probes for growth, seeks to BOF, hashes a second full pass, and returns
  a digest only when both passes agree and full handle/path identity
  (type, device, inode, size, mtime, ctime) still matches.

  Rejects symlinks, non-regular files, unusable inode identities, growth past
  the captured size, short reads, and unstable content between passes. Closes
  the handle on every path.

  This is a bounded stable-content check under a trusted-path assumption —
  not proof of an atomic snapshot against a hostile concurrent writer. An
  owner restoring identical bytes between passes is semantically unchanged.
  Metadata uses OTP posix second-resolution timestamps (pinned OTP rejects
  `time: :native` with `:badarg`).
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

  Canonicalization is hard-bounded (depth / nodes / keys / string bytes /
  estimated encoded bytes) before Jason so the public helper cannot
  recurse or materialize without a system ceiling.
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
  # Dataset hash — single open, dual exact passes, digest equality
  # ---------------------------------------------------------------------------

  defp hash_regular_file(path, expected) do
    case :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
      {:ok, io} ->
        try do
          with {:ok, info1} <- :file.read_file_info(io, time: :posix),
               stat1 = File.Stat.from_record(info1),
               {:ok, id1} <- regular_identity(stat1),
               true <- identity_match?(id1, expected),
               {:ok, state1} <- hash_exact_size(io, expected.size),
               :ok <- eof_probe(io),
               :ok <- emit_pass_one_checkpoint(path),
               :ok <- seek_bof(io),
               {:ok, state2} <- hash_exact_size(io, expected.size),
               :ok <- eof_probe(io),
               bin1 = :crypto.hash_final(state1),
               bin2 = :crypto.hash_final(state2),
               true <- bin1 == bin2,
               {:ok, info2} <- :file.read_file_info(io, time: :posix),
               stat2 = File.Stat.from_record(info2),
               {:ok, id2} <- regular_identity(stat2),
               true <- identity_match?(id2, expected),
               {:ok, lstat} <- File.lstat(path, time: :posix),
               {:ok, id3} <- regular_identity(lstat),
               true <- identity_match?(id3, expected) do
            "sha256:" <> Base.encode16(bin1, case: :lower)
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

  # Hash exactly `size` bytes from the current position (no EOF probe).
  defp hash_exact_size(io, size) when is_integer(size) and size >= 0 do
    hash_n_bytes(io, size, :crypto.hash_init(:sha256))
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

  defp eof_probe(io) do
    case :file.read(io, 1) do
      :eof ->
        :ok

      {:ok, <<>>} ->
        :ok

      {:ok, _} ->
        # File grew past captured size during/between passes.
        {:error, :file_changed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp seek_bof(io) do
    case :file.position(io, :bof) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp emit_pass_one_checkpoint(_path) do
    # Trusted telemetry handlers run synchronously in this process. Keep the
    # exposed surface fixed; test coordination owns paths in handler closures.
    :telemetry.execute(
      @stable_read_pass_one_event,
      %{count: 1},
      %{source: :eval_run_identity}
    )

    :ok
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
  # Canonical config fingerprint — ordered, collision-rejecting, bounded
  # ---------------------------------------------------------------------------

  defp canonical_json(value) do
    budget = %{
      nodes: 0,
      keys: 0,
      max_depth: @max_fp_depth,
      max_nodes: @max_fp_nodes,
      max_keys: @max_fp_keys,
      max_string_bytes: @max_fp_string_bytes,
      max_estimated_bytes: @max_fp_estimated_bytes,
      estimated: 0
    }

    case canonicalize(value, budget, 0) do
      {:ok, clean, _budget} -> encode_canonical(clean)
      :error -> :error
    end
  end

  # Returns nested structure of Jason.OrderedObject / lists / scalars.
  # Never re-materializes objects as unordered Map.
  defp canonicalize(map, budget, depth) when is_map(map) do
    key_count = map_size(map)

    cond do
      depth > budget.max_depth ->
        :error

      budget.nodes + 1 > budget.max_nodes ->
        :error

      budget.keys + key_count > budget.max_keys ->
        :error

      true ->
        budget = %{
          budget
          | nodes: budget.nodes + 1,
            keys: budget.keys + key_count,
            estimated: budget.estimated + 2
        }

        if budget.estimated > budget.max_estimated_bytes do
          :error
        else
          Enum.reduce_while(map, {:ok, MapSet.new(), [], budget, true}, fn {k, v},
                                                                           {:ok, seen, acc, b,
                                                                            first?} ->
            case normalize_fp_key(k, b) do
              {:ok, key, b} ->
                if MapSet.member?(seen, key) do
                  # Atom/string alias collision (or duplicate string keys)
                  {:halt, :error}
                else
                  case canonicalize(v, b, depth + 1) do
                    {:ok, cv, b2} ->
                      separator_bytes = if first?, do: 0, else: 1
                      b2 = %{b2 | estimated: b2.estimated + separator_bytes}

                      if b2.estimated > b2.max_estimated_bytes do
                        {:halt, :error}
                      else
                        {:cont, {:ok, MapSet.put(seen, key), [{key, cv} | acc], b2, false}}
                      end

                    :error ->
                      {:halt, :error}
                  end
                end

              :error ->
                {:halt, :error}
            end
          end)
          |> case do
            {:ok, _seen, pairs, final_budget, _first?} ->
              ordered =
                pairs
                |> Enum.sort_by(&elem(&1, 0))
                |> Jason.OrderedObject.new()

              {:ok, ordered, final_budget}

            :error ->
              :error
          end
        end
    end
  end

  defp canonicalize(list, budget, depth) when is_list(list) do
    cond do
      depth > budget.max_depth ->
        :error

      budget.nodes + 1 > budget.max_nodes ->
        :error

      true ->
        budget = %{
          budget
          | nodes: budget.nodes + 1,
            estimated: budget.estimated + 2
        }

        if budget.estimated > budget.max_estimated_bytes do
          :error
        else
          Enum.reduce_while(list, {:ok, [], budget, true}, fn item, {:ok, acc, b, first?} ->
            case canonicalize(item, b, depth + 1) do
              {:ok, c, b2} ->
                separator_bytes = if first?, do: 0, else: 1
                b2 = %{b2 | estimated: b2.estimated + separator_bytes}

                if b2.estimated > b2.max_estimated_bytes do
                  {:halt, :error}
                else
                  {:cont, {:ok, [c | acc], b2, false}}
                end

              :error ->
                {:halt, :error}
            end
          end)
          |> case do
            {:ok, items, final_budget, _first?} ->
              {:ok, Enum.reverse(items), final_budget}

            :error ->
              :error
          end
        end
    end
  end

  defp canonicalize(v, budget, _depth) when is_binary(v) do
    size = byte_size(v)

    cond do
      size > budget.max_string_bytes ->
        :error

      size > budget.max_estimated_bytes ->
        :error

      not String.valid?(v) ->
        :error

      budget.nodes + 1 > budget.max_nodes ->
        :error

      true ->
        case encoded_scalar_size(v) do
          {:ok, encoded_size} -> add_encoded_scalar(v, budget, encoded_size)
          :error -> :error
        end
    end
  end

  defp canonicalize(v, budget, _depth) when is_integer(v) do
    with true <- budget.nodes + 1 <= budget.max_nodes,
         {:ok, _magnitude_bytes} <- bounded_integer_magnitude_bytes(v),
         {:ok, encoded_size} <- encoded_scalar_size(v) do
      add_encoded_scalar(v, budget, encoded_size)
    else
      _ -> :error
    end
  end

  defp canonicalize(v, budget, _depth) when is_float(v) do
    if budget.nodes + 1 > budget.max_nodes do
      :error
    else
      case encode_finite_float(v) do
        {:ok, encoded_size} ->
          estimated = budget.estimated + encoded_size

          if estimated > budget.max_estimated_bytes do
            :error
          else
            {:ok, v, %{budget | nodes: budget.nodes + 1, estimated: estimated}}
          end

        :error ->
          :error
      end
    end
  end

  defp canonicalize(v, budget, _depth) when is_boolean(v) or is_nil(v) do
    case encoded_scalar_size(v) do
      {:ok, encoded_size} -> add_encoded_scalar(v, budget, encoded_size)
      :error -> :error
    end
  end

  defp canonicalize(a, budget, depth) when is_atom(a) do
    canonicalize(Atom.to_string(a), budget, depth)
  end

  defp canonicalize(_, _, _), do: :error

  defp add_encoded_scalar(value, budget, encoded_size) do
    if budget.nodes + 1 > budget.max_nodes or
         budget.estimated + encoded_size > budget.max_estimated_bytes do
      :error
    else
      {:ok, value,
       %{budget | nodes: budget.nodes + 1, estimated: budget.estimated + encoded_size}}
    end
  end

  defp bounded_integer_magnitude_bytes(value) do
    # External size is available without decimal conversion or magnitude
    # arithmetic. The largest ETF bignum header is seven bytes.
    if :erlang.external_size(value) > @max_fp_integer_bytes + 7 do
      :error
    else
      value
      |> :erlang.term_to_binary()
      |> bounded_external_integer_bytes()
    end
  rescue
    _ -> :error
  end

  defp bounded_external_integer_bytes(<<131, 97, _value>>), do: {:ok, 1}

  defp bounded_external_integer_bytes(<<131, 98, value::signed-big-32>>) do
    {:ok, byte_size(:binary.encode_unsigned(abs(value)))}
  end

  defp bounded_external_integer_bytes(<<131, 110, bytes, _sign, digits::binary-size(bytes)>>) do
    bounded_magnitude_bytes(bytes, :binary.last(digits))
  end

  defp bounded_external_integer_bytes(
         <<131, 111, bytes::unsigned-big-32, _sign, digits::binary-size(bytes)>>
       ) do
    bounded_magnitude_bytes(bytes, :binary.last(digits))
  end

  defp bounded_external_integer_bytes(_), do: :error

  defp bounded_magnitude_bytes(bytes, most_significant_byte) do
    cond do
      bytes > @max_fp_integer_bytes -> :error
      bytes < @max_fp_integer_bytes -> {:ok, bytes}
      bytes * 8 - leading_zero_bits(most_significant_byte) <= @max_fp_integer_bits -> {:ok, bytes}
      true -> :error
    end
  end

  defp leading_zero_bits(byte) when byte >= 128, do: 0
  defp leading_zero_bits(byte) when byte >= 64, do: 1
  defp leading_zero_bits(byte) when byte >= 32, do: 2
  defp leading_zero_bits(byte) when byte >= 16, do: 3
  defp leading_zero_bits(byte) when byte >= 8, do: 4
  defp leading_zero_bits(byte) when byte >= 4, do: 5
  defp leading_zero_bits(byte) when byte >= 2, do: 6
  defp leading_zero_bits(_byte), do: 7

  defp encode_finite_float(value) do
    encoded_scalar_size(value)
  end

  # Called only after the scalar's byte/bit ceiling has passed. Jason therefore
  # performs exact JSON escaping/decimal conversion on bounded input, avoiding
  # both unbounded work and conservative false rejection near the 1 MiB limit.
  defp encoded_scalar_size(value) do
    case Jason.encode(value) do
      {:ok, encoded} -> {:ok, byte_size(encoded)}
      {:error, _} -> :error
    end
  rescue
    _ -> :error
  end

  defp normalize_fp_key(k, budget) when is_binary(k) do
    size = byte_size(k)

    cond do
      size > budget.max_string_bytes ->
        :error

      not String.valid?(k) ->
        :error

      true ->
        case encoded_scalar_size(k) do
          {:ok, encoded_size} ->
            estimated = budget.estimated + encoded_size + 1

            if estimated > budget.max_estimated_bytes do
              :error
            else
              {:ok, k, %{budget | estimated: estimated}}
            end

          :error ->
            :error
        end
    end
  end

  defp normalize_fp_key(k, budget) when is_atom(k) do
    normalize_fp_key(Atom.to_string(k), budget)
  end

  defp normalize_fp_key(_, _), do: :error

  defp encode_canonical(value) do
    case Jason.encode(value) do
      {:ok, json} ->
        if byte_size(json) > @max_fp_estimated_bytes do
          :error
        else
          {:ok, json}
        end

      {:error, _} ->
        :error
    end
  end
end
