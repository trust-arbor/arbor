defmodule Arbor.Orchestrator.DurableJson do
  @moduledoc false

  @encoding "arbor_orchestrator_durable_json_v1"
  @digest_algorithm "sha256"

  @type projection :: nil | boolean() | number() | String.t() | [projection()] | map()
  @type digest_result :: %{
          encoding: String.t(),
          digest_algorithm: String.t(),
          sha256: String.t(),
          projection: projection()
        }

  @doc """
  Projects a term through Jason's JSON semantics and returns its canonical digest.

  Object keys are ordered by their decoded UTF-8 bytes before hashing. Duplicate
  keys produced by JSON key normalization are rejected rather than collapsed.
  The function adds no size or depth policy beyond the Jason encode/decode path
  used by durable orchestrator payloads.
  """
  @spec project_and_digest(term()) :: {:ok, digest_result()} | {:error, atom()}
  def project_and_digest(value) do
    with {:ok, encoded} <- encode_projection(value),
         {:ok, decoded} <- Jason.decode(encoded, objects: :ordered_objects),
         {:ok, canonical, projection} <- canonicalize(decoded),
         {:ok, canonical_iodata} <- Jason.encode_to_iodata(canonical, maps: :strict) do
      digest =
        canonical_iodata
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      {:ok,
       %{
         encoding: @encoding,
         digest_algorithm: @digest_algorithm,
         sha256: digest,
         projection: projection
       }}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, _reason} -> {:error, :invalid_json_projection}
      _other -> {:error, :invalid_json_projection}
    end
  rescue
    _ -> {:error, :invalid_json_projection}
  catch
    _, _ -> {:error, :invalid_json_projection}
  end

  @doc "Returns only the canonical lowercase SHA-256 for a durable JSON projection."
  @spec digest(term()) :: {:ok, String.t()} | {:error, atom()}
  def digest(value) do
    case project_and_digest(value) do
      {:ok, %{sha256: digest}} -> {:ok, digest}
      {:error, reason} -> {:error, reason}
    end
  end

  defp encode_projection(value) do
    case Jason.encode(value, maps: :naive) do
      {:ok, encoded} -> {:ok, encoded}
      {:error, %Protocol.UndefinedError{}} -> {:error, :unsupported_payload}
      {:error, _reason} -> {:error, :invalid_json_projection}
    end
  rescue
    _ -> {:error, :invalid_json_projection}
  catch
    _, _ -> {:error, :invalid_json_projection}
  end

  defp canonicalize(%Jason.OrderedObject{values: pairs}) when is_list(pairs) do
    canonicalize_object(pairs, %{}, [])
  end

  defp canonicalize(values) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, [], []}, fn value, {:ok, canonical_acc, projection_acc} ->
      case canonicalize(value) do
        {:ok, canonical, projection} ->
          {:cont, {:ok, [canonical | canonical_acc], [projection | projection_acc]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, canonical, projection} ->
        {:ok, Enum.reverse(canonical), Enum.reverse(projection)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp canonicalize(value)
       when is_binary(value) or is_integer(value) or is_float(value) or is_boolean(value) or
              is_nil(value),
       do: {:ok, value, value}

  defp canonicalize(_value), do: {:error, :invalid_json_projection}

  defp canonicalize_object([], _seen, acc) do
    sorted = Enum.sort_by(acc, fn {key, _canonical, _projection} -> key end)

    canonical =
      sorted
      |> Enum.map(fn {key, value, _projection} -> {key, value} end)
      |> Jason.OrderedObject.new()

    projection = Map.new(sorted, fn {key, _canonical, value} -> {key, value} end)
    {:ok, canonical, projection}
  end

  defp canonicalize_object([{key, value} | rest], seen, acc) when is_binary(key) do
    if Map.has_key?(seen, key) do
      {:error, :duplicate_json_key}
    else
      with {:ok, canonical, projection} <- canonicalize(value) do
        canonicalize_object(rest, Map.put(seen, key, true), [
          {key, canonical, projection} | acc
        ])
      end
    end
  end

  defp canonicalize_object(_pairs, _seen, _acc), do: {:error, :invalid_json_projection}
end
