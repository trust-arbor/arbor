defmodule Arbor.Common.LogRedactor do
  @moduledoc """
  Logger filter that redacts sensitive values from log output.

  Delegates to `Arbor.Common.SensitiveData.redact/1` for pattern matching,
  which covers both PII and secret patterns.

  Traversal is total and globally bounded: nested maps, lists, and tuples are
  walked without requiring Enumerable and without invoking struct module
  callbacks (Logger crash reports often embed non-Enumerable or forged
  struct-tagged maps). Both map keys and values are walked under one remaining
  node budget. Binary redaction fails closed to `"[REDACTED]"` on any exception
  or throw so the primary Logger filter is never removed by a bad term.
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
      walk_list(list, depth - 1, budget - 1, [])
    end
  end

  defp walk(tuple, depth, budget) when is_tuple(tuple) do
    if depth <= 0 do
      {@redacted_marker, budget - 1}
    else
      {elems, budget_left} = walk_list(Tuple.to_list(tuple), depth - 1, budget - 1, [])
      {List.to_tuple(elems), budget_left}
    end
  end

  # Struct-tagged maps (real modules or forged atoms). Never call struct/2 or
  # mod.__struct__/1 — those can raise or run arbitrary code in a Logger filter.
  defp walk(%{__struct__: mod} = map, depth, budget) when is_atom(mod) do
    if depth <= 0 do
      {@redacted_marker, budget - 1}
    else
      # Map.delete yields a plain map; never Enum over the struct-tagged term.
      fields = Map.delete(map, :__struct__)

      case walk_pairs(Map.to_list(fields), depth - 1, budget - 1, []) do
        {:complete, pairs, budget_left} ->
          case assemble_pairs(pairs) do
            {:ok, assembled} ->
              # Restore the original __struct__ key only after a complete field walk.
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
      case walk_pairs(Map.to_list(map), depth - 1, budget - 1, []) do
        {:complete, pairs, budget_left} ->
          case assemble_pairs(pairs) do
            {:ok, assembled} -> {assembled, budget_left}
            :collision -> {@redacted_marker, budget_left}
          end

        {:incomplete, pairs, budget_left} ->
          # Unvisited keys omitted (not emitted); mark exhaustion plainly.
          case assemble_pairs(pairs) do
            {:ok, assembled} -> {Map.put(assembled, :redacted, true), budget_left}
            :collision -> {@redacted_marker, budget_left}
          end
      end
    end
  end

  defp walk(other, _depth, budget), do: {other, budget - 1}

  defp walk_list([], _depth, budget, acc), do: {Enum.reverse(acc), budget}

  defp walk_list(_rest, _depth, budget, acc) when budget <= 0 do
    {Enum.reverse([@redacted_marker | acc]), 0}
  end

  defp walk_list([head | tail], depth, budget, acc) when is_list(tail) do
    {head_redacted, budget_left} = walk(head, depth, budget)
    walk_list(tail, depth, budget_left, [head_redacted | acc])
  end

  # Improper list: walk head and non-list tail without Enumerable.
  defp walk_list([head | tail], depth, budget, acc) do
    {head_redacted, budget_after_head} = walk(head, depth, budget)
    {tail_redacted, budget_left} = walk(tail, depth, budget_after_head)
    {finish_improper(acc, head_redacted, tail_redacted), budget_left}
  end

  defp finish_improper(acc, head, tail) do
    Enum.reduce(acc, [head | tail], fn item, rest -> [item | rest] end)
  end

  defp walk_pairs([], _depth, budget, acc), do: {:complete, Enum.reverse(acc), budget}

  defp walk_pairs(rest, _depth, budget, acc) when budget <= 0 and rest != [] do
    {:incomplete, Enum.reverse(acc), 0}
  end

  # Keys and values both participate in the report surface and the node budget.
  defp walk_pairs([{key, value} | rest], depth, budget, acc) do
    {key_redacted, budget_after_key} = walk(key, depth, budget)
    {value_redacted, budget_left} = walk(value, depth, budget_after_key)
    walk_pairs(rest, depth, budget_left, [{key_redacted, value_redacted} | acc])
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
