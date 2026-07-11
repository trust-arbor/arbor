defmodule Arbor.Persistence.Eval.RunIdentity do
  @moduledoc false

  # Captures run-identity fields for eval runs (git sha, dataset hash, config
  # fingerprint). Public access is via Arbor.Persistence only.
  #
  # All capture is best-effort and fail-safe: any failure simply omits the
  # field. Caller-provided values are never overwritten.

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

  Hashes incrementally via a bounded stream so large datasets are not loaded
  entirely into memory.
  """
  @spec dataset_hash(String.t() | nil) :: String.t() | nil
  def dataset_hash(nil), do: nil

  def dataset_hash(path) when is_binary(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        hash =
          path
          |> File.stream!([], @stream_chunk_bytes)
          |> Enum.reduce(:crypto.hash_init(:sha256), fn chunk, acc ->
            :crypto.hash_update(acc, chunk)
          end)
          |> :crypto.hash_final()
          |> Base.encode16(case: :lower)

        "sha256:" <> hash

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  def dataset_hash(_), do: nil

  @doc """
  Deterministic SHA-256 fingerprint of a config map (nil for nil/empty).

  Uses a JSON-clean canonical encoding so fingerprints stay stable across
  BEAM releases and never embed Erlang term bytes.
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

  # Canonical JSON: objects with sorted string keys; only JSON-clean values.
  defp canonical_json(value) do
    case canonicalize(value) do
      {:ok, clean} -> encode_canonical(clean)
      :error -> :error
    end
  end

  defp canonicalize(map) when is_map(map) do
    Enum.reduce_while(map, {:ok, []}, fn {k, v}, {:ok, acc} ->
      key =
        cond do
          is_binary(k) -> k
          is_atom(k) -> Atom.to_string(k)
          true -> nil
        end

      if is_nil(key) do
        {:halt, :error}
      else
        case canonicalize(v) do
          {:ok, cv} -> {:cont, {:ok, [{key, cv} | acc]}}
          :error -> {:halt, :error}
        end
      end
    end)
    |> case do
      {:ok, pairs} ->
        sorted =
          pairs
          |> Enum.sort_by(&elem(&1, 0))
          |> Map.new()

        {:ok, sorted}

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

  defp canonicalize(v) when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v),
    do: {:ok, v}

  defp canonicalize(a) when is_atom(a), do: {:ok, Atom.to_string(a)}
  defp canonicalize(_), do: :error

  defp encode_canonical(value) do
    case Jason.encode(value) do
      {:ok, json} -> {:ok, json}
      {:error, _} -> :error
    end
  end
end
