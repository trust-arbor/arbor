defmodule Arbor.Common.LogRedactor do
  @moduledoc """
  Logger filter that redacts sensitive values from log output.

  Delegates to `Arbor.Common.SensitiveData.redact/1` for pattern matching,
  which covers both PII and secret patterns.

  Traversal is total and globally bounded:
  - Lists are peeled one cons cell at a time (proper and improper multi-cons)
    without using `is_list/1` to decide whether to continue the spine
  - Maps use `:maps.iterator` / `:maps.next` (no `Map.to_list/1`, no full copy)
  - Tuples use `tuple_size/1` + `elem/2` (no `Tuple.to_list/1`)
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

  # List guard is only for *entering* list mode. Spine continuation never uses
  # is_list/1 — see continue_list_tail/5, which peels cons by pattern match.
  defp walk(list, depth, budget) when is_list(list) do
    if depth <= 0 do
      {@redacted_marker, budget - 1}
    else
      walk_list(list, depth - 1, budget - 1, [])
    end
  end

  defp walk(tuple, depth, budget) when is_tuple(tuple) do
    if depth <= 0 do
      {@redacted_marker, budget - 1}
    else
      # Index only; never Tuple.to_list/1 (full attacker-controlled allocation).
      walk_tuple(tuple, 0, tuple_size(tuple), depth - 1, budget - 1, [])
    end
  end

  # Struct-tagged maps (real modules or forged atoms). Never call struct/2 or
  # mod.__struct__/1. Iterate in place — never Map.delete/Map.to_list the whole
  # struct (that would allocate O(size) before the node budget can stop us).
  defp walk(%{__struct__: mod} = map, depth, budget) when is_atom(mod) do
    if depth <= 0 do
      {@redacted_marker, budget - 1}
    else
      case walk_map_iterator(
             :maps.next(:maps.iterator(map)),
             depth - 1,
             budget - 1,
             [],
             _skip_struct? = true
           ) do
        {:complete, pairs, budget_left} ->
          case assemble_pairs(pairs) do
            {:ok, assembled} ->
              {Map.put(assembled, :__struct__, mod), budget_left}

            :collision ->
              {@redacted_marker, budget_left}
          end

        {:incomplete, _pairs, budget_left} ->
          {@redacted_marker, budget_left}
      end
    end
  end

  defp walk(map, depth, budget) when is_map(map) do
    if depth <= 0 do
      {@redacted_marker, budget - 1}
    else
      case walk_map_iterator(
             :maps.next(:maps.iterator(map)),
             depth - 1,
             budget - 1,
             [],
             _skip_struct? = false
           ) do
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

  # --- List: recursive cons peel (no is_list/1 on the remainder) ------------
  #
  # Multi-cons improper lists such as [safe, "secret..." | tail] are stored as
  # [safe | ["secret..." | tail]]. Each cons is peeled by [head | tail] match.
  # Continuation decides by pattern match on the remainder:
  #   []              -> proper terminator
  #   [_ | _] = cons  -> another spine cell (proper or improper)
  #   other           -> true improper non-list tail (must walk as a term)
  #
  # Never pass a multi-cell improper remainder wholesale to walk/3's generic
  # `other` clause — that would preserve secret-bearing list spines unredacted.

  defp walk_list(_rest, _depth, budget, acc) when budget <= 0 do
    # Drop unvisited remainder (including any improper secret tail).
    {Enum.reverse([@redacted_marker | acc]), 0}
  end

  defp walk_list([], _depth, budget, acc), do: {Enum.reverse(acc), budget}

  defp walk_list([head | tail], depth, budget, acc) do
    {head_redacted, budget_left} = walk(head, depth, budget)
    continue_list_tail(tail, depth, budget_left, head_redacted, acc)
  end

  # Proper end of list.
  defp continue_list_tail([], depth, budget, head_redacted, acc) do
    walk_list([], depth, budget, [head_redacted | acc])
  end

  # Another cons cell — covers proper *and* improper multi-cons spines.
  # Pattern `[_ | _]` matches improper lists; does not use is_list/1.
  defp continue_list_tail([_ | _] = next_cons, depth, budget, head_redacted, acc) do
    walk_list(next_cons, depth, budget, [head_redacted | acc])
  end

  # True improper non-list tail (binary, tuple, map, atom, ...). Walk it.
  defp continue_list_tail(non_list_tail, depth, budget, head_redacted, acc) do
    {tail_redacted, budget_final} = walk(non_list_tail, depth, budget)
    {finish_improper(acc, head_redacted, tail_redacted), budget_final}
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

  defp walk_map_iterator(:none, _depth, budget, acc, _skip_struct?) do
    {:complete, Enum.reverse(acc), budget}
  end

  defp walk_map_iterator(_next, _depth, budget, acc, _skip_struct?) when budget <= 0 do
    {:incomplete, Enum.reverse(acc), 0}
  end

  defp walk_map_iterator({key, value, rest_iterator}, depth, budget, acc, skip_struct?) do
    if skip_struct? and key == :__struct__ do
      # Skip the tag without charging budget; never copy the whole map first.
      walk_map_iterator(:maps.next(rest_iterator), depth, budget, acc, skip_struct?)
    else
      {key_redacted, budget_after_key} = walk(key, depth, budget)
      {value_redacted, budget_left} = walk(value, depth, budget_after_key)

      walk_map_iterator(
        :maps.next(rest_iterator),
        depth,
        budget_left,
        [{key_redacted, value_redacted} | acc],
        skip_struct?
      )
    end
  end

  # After key redaction, colliding keys must not silently merge secret values.
  defp assemble_pairs(pairs) do
    keys = Enum.map(pairs, fn {key, _value} -> key end)

    if length(keys) == MapSet.size(MapSet.new(keys)) do
      {:ok, Map.new(pairs)}
    else
      :collision
    end
  end
end
