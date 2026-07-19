defmodule Arbor.Common.LogRedactor do
  @moduledoc """
  Logger filter that redacts sensitive values from log output.

  Delegates to `Arbor.Common.SensitiveData.redact/1` for pattern matching,
  which covers both PII and secret patterns.

  Traversal is total and globally bounded:
  - Lists are walked one cons cell at a time (including multi-cons improper tails)
  - Maps use `:maps.iterator` / `:maps.next` (no full `Map.to_list/1`)
  - Tuples use `elem/2` indexing (no full `Tuple.to_list/1`)
  - Struct-tagged maps never invoke Enumerable or `struct/2` callbacks
  - Both map keys and values share one remaining-node budget
  - Binary redaction fails closed to `"[REDACTED]"` on any exception/throw
  """

  alias Arbor.Common.SensitiveData

  # Logger filters must stay cheap. Global walk budget + depth ceiling.
  @max_depth 12
  @max_nodes 256

  # Plain map — never include :__struct__, so Inspect/protocol cannot dispatch.
  @redacted_marker %{redacted: true}
  @redacted_binary "[REDACTED]"

  @doc false
  def filter(%{msg: msg} = log_event, _extra) do
    try do
      case msg do
        {:string, str} when is_binary(str) ->
          %{log_event | msg: {:string, redact_binary(str)}}

        {:report, report} ->
          {redacted, _budget} = walk(report, @max_depth, @max_nodes)
          %{log_event | msg: {:report, redacted}}

        _ ->
          log_event
      end
    rescue
      _ ->
        %{log_event | msg: {:string, @redacted_binary}}
    catch
      _, _ ->
        %{log_event | msg: {:string, @redacted_binary}}
    end
  end

  def filter(log_event, _extra), do: log_event

  # SensitiveData.redact/1 uses Regex/String operations that can raise on
  # invalid UTF-8. Never let that kill the Logger primary filter.
  defp redact_binary(str) when is_binary(str) do
    try do
      SensitiveData.redact(str)
    rescue
      _ -> @redacted_binary
    catch
      _, _ -> @redacted_binary
    end
  end

  # --- Globally bounded term walk -------------------------------------------
  # Each visited term consumes one node from `budget`. Returns {term, budget_left}.

  defp walk(_term, _depth, budget) when budget <= 0, do: {@redacted_marker, 0}

  defp walk(bin, _depth, budget) when is_binary(bin) do
    {redact_binary(bin), budget - 1}
  end

  defp walk(list, depth, budget) when is_list(list) do
    if depth <= 0 do
      {@redacted_marker, budget - 1}
    else
      # One node for the list spine root; walk cons cells without materializing.
      walk_list(list, depth - 1, budget - 1, [])
    end
  end

  defp walk(tuple, depth, budget) when is_tuple(tuple) do
    if depth <= 0 do
      {@redacted_marker, budget - 1}
    else
      # Index elements; never Tuple.to_list/1 (would allocate the full attacker
      # controlled container before the node budget can stop us).
      walk_tuple(tuple, 0, tuple_size(tuple), depth - 1, budget - 1, [])
    end
  end

  # Struct-tagged maps (real modules or forged atoms). Never call struct/2 or
  # mod.__struct__/1 — those can raise or run arbitrary code in a Logger filter.
  defp walk(%{__struct__: mod} = map, depth, budget) when is_atom(mod) do
    if depth <= 0 do
      {@redacted_marker, budget - 1}
    else
      # Drop __struct__ then iterate the plain field map with a bounded iterator.
      fields = Map.delete(map, :__struct__)

      case walk_map_iterator(:maps.next(:maps.iterator(fields)), depth - 1, budget - 1, []) do
        {:complete, pairs, budget_left} ->
          case assemble_pairs(pairs) do
            {:ok, assembled} ->
              {Map.put(assembled, :__struct__, mod), budget_left}

            :collision ->
              {@redacted_marker, budget_left}
          end

        {:incomplete, _pairs, budget_left} ->
          # Partial struct-shaped maps are unsafe for Inspect/protocol dispatch.
          {@redacted_marker, budget_left}
      end
    end
  end

  defp walk(map, depth, budget) when is_map(map) do
    if depth <= 0 do
      {@redacted_marker, budget - 1}
    else
      case walk_map_iterator(:maps.next(:maps.iterator(map)), depth - 1, budget - 1, []) do
        {:complete, pairs, budget_left} ->
          case assemble_pairs(pairs) do
            {:ok, assembled} -> {assembled, budget_left}
            :collision -> {@redacted_marker, budget_left}
          end

        {:incomplete, pairs, budget_left} ->
          case assemble_pairs(pairs) do
            {:ok, assembled} -> {Map.put(assembled, :redacted, true), budget_left}
            :collision -> {@redacted_marker, budget_left}
          end
      end
    end
  end

  defp walk(other, _depth, budget), do: {other, budget - 1}

  # --- List: recursive cons traversal ---------------------------------------
  # Walks proper and improper (multi-cons) lists one cell at a time. When the
  # budget is exhausted, the unvisited remainder — including any improper tail —
  # is replaced with a plain marker and never returned.

  defp walk_list(_rest, _depth, budget, acc) when budget <= 0 do
    {Enum.reverse([@redacted_marker | acc]), 0}
  end

  defp walk_list([], _depth, budget, acc), do: {Enum.reverse(acc), budget}

  defp walk_list([head | tail], depth, budget, acc) do
    {head_redacted, budget_left} = walk(head, depth, budget)

    # is_list/1 is true for improper lists too, so multi-cons improper spines
    # (e.g. [a | [b | secret]]) continue recursively until a non-list tail.
    if is_list(tail) do
      walk_list(tail, depth, budget_left, [head_redacted | acc])
    else
      # True improper non-list tail: must walk (or fail closed) — never leave
      # the original tail attached after a partial walk.
      {tail_redacted, budget_final} = walk(tail, depth, budget_left)
      {finish_improper(acc, head_redacted, tail_redacted), budget_final}
    end
  end

  defp finish_improper(acc, head, tail) do
    Enum.reduce(acc, [head | tail], fn item, rest -> [item | rest] end)
  end

  # --- Tuple: bounded elem/2 indexing ---------------------------------------

  defp walk_tuple(_tuple, index, size, _depth, budget, acc) when index >= size do
    {List.to_tuple(Enum.reverse(acc)), budget}
  end

  defp walk_tuple(_tuple, _index, _size, _depth, budget, _acc) when budget <= 0 do
    # Cannot emit a partial tuple while later elements remain unwalked.
    {@redacted_marker, 0}
  end

  defp walk_tuple(tuple, index, size, depth, budget, acc) do
    {elem_redacted, budget_left} = walk(elem(tuple, index), depth, budget)
    walk_tuple(tuple, index + 1, size, depth, budget_left, [elem_redacted | acc])
  end

  # --- Map: bounded iterator (no Map.to_list/1) -----------------------------

  defp walk_map_iterator(:none, _depth, budget, acc) do
    {:complete, Enum.reverse(acc), budget}
  end

  defp walk_map_iterator(_next, _depth, budget, acc) when budget <= 0 do
    # Stop iterating; unvisited pairs never enter the output.
    {:incomplete, Enum.reverse(acc), 0}
  end

  defp walk_map_iterator({key, value, rest_iterator}, depth, budget, acc) do
    {key_redacted, budget_after_key} = walk(key, depth, budget)
    {value_redacted, budget_left} = walk(value, depth, budget_after_key)

    walk_map_iterator(
      :maps.next(rest_iterator),
      depth,
      budget_left,
      [{key_redacted, value_redacted} | acc]
    )
  end

  # After key redaction, colliding keys must not silently merge secret values.
  # Fail closed with a plain marker rather than emit an ambiguous map.
  defp assemble_pairs(pairs) do
    keys = Enum.map(pairs, fn {key, _value} -> key end)

    if length(keys) == MapSet.size(MapSet.new(keys)) do
      {:ok, Map.new(pairs)}
    else
      :collision
    end
  end
end
