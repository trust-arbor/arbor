defmodule Arbor.Voice.Session.JsonTerm do
  @moduledoc false
  # Pure strict JSON-term validation for tool arguments and router results.
  # Accepts only nil, booleans, finite numbers, valid UTF-8 binaries, lists,
  # and maps with valid UTF-8 string keys. Rejects structs, arbitrary atoms,
  # PIDs/refs/funs, and containers past depth/node ceilings.

  @max_depth 8
  @max_nodes 256
  @max_encoded_bytes 8192

  @doc "Max nesting depth."
  @spec max_depth() :: pos_integer()
  def max_depth, do: @max_depth

  @doc "Max nodes visited during walk (breadth bound)."
  @spec max_nodes() :: pos_integer()
  def max_nodes, do: @max_nodes

  @doc "Max Jason-encoded byte size."
  @spec max_encoded_bytes() :: pos_integer()
  def max_encoded_bytes, do: @max_encoded_bytes

  @doc "Return `:ok` if `term` is a strict bounded JSON term, else `:error`."
  @spec validate(term()) :: :ok | :error
  def validate(term) do
    case walk(term, 0, 0) do
      {:ok, _nodes} ->
        case Jason.encode(term) do
          {:ok, encoded}
          when is_binary(encoded) and byte_size(encoded) <= @max_encoded_bytes ->
            if String.valid?(encoded), do: :ok, else: :error

          _ ->
            :error
        end

      :error ->
        :error
    end
  end

  @doc "Boolean wrapper around validate/1."
  @spec valid?(term()) :: boolean()
  def valid?(term), do: validate(term) == :ok

  # ---------------------------------------------------------------------------
  # Walk with depth + node ceilings (reduce_while stops early on huge containers)
  # ---------------------------------------------------------------------------

  defp walk(_term, depth, _nodes) when depth > @max_depth, do: :error
  defp walk(_term, _depth, nodes) when nodes >= @max_nodes, do: :error

  defp walk(nil, _depth, nodes), do: {:ok, nodes + 1}
  defp walk(v, _depth, nodes) when is_boolean(v), do: {:ok, nodes + 1}

  defp walk(v, _depth, nodes) when is_integer(v), do: {:ok, nodes + 1}

  defp walk(v, _depth, nodes) when is_float(v), do: {:ok, nodes + 1}

  defp walk(v, _depth, nodes) when is_binary(v) do
    if byte_size(v) <= @max_encoded_bytes and String.valid?(v) do
      {:ok, nodes + 1}
    else
      :error
    end
  end

  defp walk(list, depth, nodes) when is_list(list) do
    nodes = nodes + 1

    if nodes > @max_nodes do
      :error
    else
      walk_list(list, depth + 1, nodes)
    end
  end

  defp walk(map, depth, nodes) when is_map(map) do
    # Structs are maps; reject them explicitly.
    if is_struct(map) or Map.has_key?(map, :__struct__) do
      :error
    else
      walk_map(map, depth + 1, nodes + 1)
    end
  end

  defp walk(_other, _depth, _nodes), do: :error

  defp walk_list([], _depth, nodes), do: {:ok, nodes}

  defp walk_list([item | rest], depth, nodes) do
    case walk(item, depth, nodes) do
      {:ok, next_nodes} -> walk_list(rest, depth, next_nodes)
      :error -> :error
    end
  end

  defp walk_list(_improper_tail, _depth, _nodes), do: :error

  defp walk_map(_map, _depth, nodes) when nodes > @max_nodes, do: :error

  defp walk_map(map, depth, nodes) do
    Enum.reduce_while(map, {:ok, nodes}, fn pair, acc ->
      walk_map_entry(pair, acc, depth)
    end)
  end

  defp walk_map_entry({key, value}, {:ok, nodes}, depth) when is_binary(key) do
    with true <- byte_size(key) <= @max_encoded_bytes,
         true <- String.valid?(key),
         {:ok, next_nodes} <- walk(value, depth, nodes) do
      {:cont, {:ok, next_nodes}}
    else
      _ -> {:halt, :error}
    end
  end

  # Atom keys and non-string keys are not JSON object keys.
  defp walk_map_entry(_pair, _acc, _depth), do: {:halt, :error}
end
