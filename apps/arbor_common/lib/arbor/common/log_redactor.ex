defmodule Arbor.Common.LogRedactor do
  @moduledoc """
  Logger filter that redacts sensitive values from log output.

  Delegates to `Arbor.Common.SensitiveData.redact/1` for pattern matching,
  which covers both PII and secret patterns.

  Traversal is total and bounded: nested maps, lists, and tuples are walked
  without requiring Enumerable on opaque structs (Logger crash reports often
  embed non-Enumerable struct terms). Depth/entry limits fail closed rather
  than leaving potentially sensitive nested binaries intact.
  """

  alias Arbor.Common.SensitiveData

  # Logger filters must stay cheap. Bound walk cost; fail closed beyond budget.
  @max_depth 12
  @max_entries 256

  @doc false
  def filter(%{msg: msg} = log_event, _extra) do
    case msg do
      {:string, str} when is_binary(str) ->
        %{log_event | msg: {:string, redact_binary(str)}}

      {:report, report} ->
        %{log_event | msg: {:report, redact_term(report, @max_depth)}}

      _ ->
        log_event
    end
  end

  def filter(log_event, _extra), do: log_event

  defp redact_binary(str) when is_binary(str), do: SensitiveData.redact(str)

  # --- Bounded term walk ----------------------------------------------------

  defp redact_term(bin, _depth) when is_binary(bin), do: redact_binary(bin)

  defp redact_term(term, depth) when depth <= 0, do: fail_closed(term)

  defp redact_term(list, depth) when is_list(list) do
    redact_list(list, depth, @max_entries)
  end

  defp redact_term(tuple, depth) when is_tuple(tuple) do
    size = tuple_size(tuple)

    if size > @max_entries do
      fail_closed(tuple)
    else
      tuple
      |> Tuple.to_list()
      |> Enum.map(&redact_term(&1, depth - 1))
      |> List.to_tuple()
    end
  end

  # Structs are maps (`is_map/1`) but often do not implement Enumerable.
  # Never call Map.new/2 or Enum over a struct — use Map.from_struct/1.
  defp redact_term(%{__struct__: mod} = struct, depth) do
    redact_struct(struct, mod, depth)
  end

  defp redact_term(map, depth) when is_map(map) do
    if map_size(map) > @max_entries do
      fail_closed(map)
    else
      # Plain maps implement Enumerable; rebuild without mutating identity.
      Map.new(map, fn {k, v} -> {k, redact_term(v, depth - 1)} end)
    end
  end

  defp redact_term(other, _depth), do: other

  defp redact_struct(struct, mod, depth) do
    fields = Map.from_struct(struct)

    if map_size(fields) > @max_entries do
      fail_closed(struct)
    else
      redacted_fields =
        Map.new(fields, fn {k, v} -> {k, redact_term(v, depth - 1)} end)

      # Prefer preserving struct shape when the module can rebuild safely.
      try do
        struct(mod, redacted_fields)
      rescue
        ArgumentError ->
          Map.put(redacted_fields, :__struct__, mod)
      end
    end
  end

  defp redact_list(_rest, _depth, 0), do: [:redacted]
  defp redact_list([], _depth, _remaining), do: []

  defp redact_list([head | tail], depth, remaining) when is_list(tail) do
    [redact_term(head, depth - 1) | redact_list(tail, depth, remaining - 1)]
  end

  # Improper list: redact the non-list tail as a term, not via Enumerable.
  defp redact_list([head | tail], depth, _remaining) do
    [redact_term(head, depth - 1) | redact_term(tail, depth - 1)]
  end

  # Fail closed: replace containers that may still hold secrets; leave scalars.
  defp fail_closed(bin) when is_binary(bin), do: redact_binary(bin)
  defp fail_closed(list) when is_list(list), do: [:redacted]
  defp fail_closed(tuple) when is_tuple(tuple), do: {:redacted}

  defp fail_closed(%{__struct__: mod}) do
    %{__struct__: mod, __redacted__: true}
  end

  defp fail_closed(map) when is_map(map), do: %{__redacted__: true}
  defp fail_closed(other), do: other
end
