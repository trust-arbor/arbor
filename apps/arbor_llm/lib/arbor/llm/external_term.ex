defmodule Arbor.LLM.ExternalTerm do
  @moduledoc false

  alias Arbor.LLM.ResponseBudget

  @max_binary_bytes 256
  @max_depth 4
  @max_items 16
  @max_nodes 24
  @signed_64_max 9_223_372_036_854_775_807
  @signed_64_min -9_223_372_036_854_775_808
  @max_float_magnitude 1.0e100

  @spec sanitize(term()) :: term()
  def sanitize(value) do
    {bounded, _remaining} = bound(value, @max_depth, @max_nodes)
    bounded
  end

  @spec exception(term()) :: term()
  def exception(%{__struct__: module, message: message}) when is_binary(message),
    do: {module, bounded_binary(message)}

  def exception(%{__struct__: module}) when is_atom(module), do: module
  def exception(_exception), do: :exception

  @spec exception_message(term()) :: String.t()
  def exception_message(%{message: message}) when is_binary(message), do: bounded_string(message)

  def exception_message(%{__struct__: module}) when is_atom(module),
    do: "external exception: " <> Atom.to_string(module)

  def exception_message(_exception), do: "external exception"

  @spec inspect(term()) :: String.t()
  def inspect(value) do
    value
    |> sanitize()
    |> Kernel.inspect(limit: 32, printable_limit: 1_024, width: 80)
  end

  defp bound(_value, _depth, remaining) when remaining <= 0, do: {:truncated, 0}
  defp bound(_value, 0, remaining), do: {:max_depth, remaining - 1}

  defp bound(value, _depth, remaining)
       when is_atom(value) or is_boolean(value) or is_nil(value),
       do: {value, remaining - 1}

  defp bound(value, _depth, remaining) when is_integer(value) do
    bounded =
      if value >= @signed_64_min and value <= @signed_64_max,
        do: value,
        else: :integer_out_of_range

    {bounded, remaining - 1}
  end

  defp bound(value, _depth, remaining) when is_float(value) do
    bounded =
      if ResponseBudget.finite_number?(value) and abs(value) <= @max_float_magnitude,
        do: value,
        else: :float_out_of_range

    {bounded, remaining - 1}
  end

  defp bound(value, _depth, remaining) when is_binary(value),
    do: {bounded_binary(value), remaining - 1}

  defp bound(%{__struct__: module}, _depth, remaining) when is_atom(module),
    do: {module, remaining - 1}

  defp bound(value, depth, remaining) when is_tuple(value) do
    {items, remaining} =
      bound_tuple(value, 0, min(tuple_size(value), @max_items), depth - 1, remaining - 1, [])

    items = if tuple_size(value) > @max_items, do: items ++ [:truncated], else: items
    {List.to_tuple(items), remaining}
  end

  defp bound(value, depth, remaining) when is_list(value),
    do: bound_list(value, depth - 1, @max_items, remaining - 1, [])

  defp bound(value, depth, remaining) when is_map(value),
    do: bound_map(:maps.iterator(value), depth - 1, @max_items, remaining - 1, %{})

  defp bound(value, _depth, remaining) when is_pid(value), do: {:pid, remaining - 1}
  defp bound(value, _depth, remaining) when is_reference(value), do: {:reference, remaining - 1}
  defp bound(value, _depth, remaining) when is_function(value), do: {:function, remaining - 1}
  defp bound(value, _depth, remaining) when is_port(value), do: {:port, remaining - 1}
  defp bound(_value, _depth, remaining), do: {:external_term, remaining - 1}

  defp bound_tuple(_tuple, index, count, _depth, remaining, acc)
       when index >= count or remaining <= 0,
       do: {Enum.reverse(acc), remaining}

  defp bound_tuple(tuple, index, count, depth, remaining, acc) do
    {item, remaining} = bound(elem(tuple, index), depth, remaining)
    bound_tuple(tuple, index + 1, count, depth, remaining, [item | acc])
  end

  defp bound_list([], _depth, _items, remaining, acc), do: {Enum.reverse(acc), remaining}

  defp bound_list(_list, _depth, 0, remaining, acc),
    do: {Enum.reverse([:truncated | acc]), remaining}

  defp bound_list(_list, _depth, _items, remaining, acc) when remaining <= 0,
    do: {Enum.reverse([:truncated | acc]), remaining}

  defp bound_list([head | tail], depth, items, remaining, acc) do
    {head, remaining} = bound(head, depth, remaining)
    bound_list(tail, depth, items - 1, remaining, [head | acc])
  end

  defp bound_list(_improper, _depth, _items, remaining, acc),
    do: {Enum.reverse([:improper_tail | acc]), remaining}

  defp bound_map(_iterator, _depth, _items, remaining, acc) when remaining <= 0,
    do: {Map.put(acc, :__truncated__, true), remaining}

  defp bound_map(iterator, depth, items, remaining, acc) do
    case :maps.next(iterator) do
      :none ->
        {acc, remaining}

      {_key, _value, _next} when items <= 0 ->
        {Map.put(acc, :__truncated__, true), remaining}

      {key, value, next} ->
        {key, remaining} = bound(key, depth, remaining)
        {value, remaining} = bound(value, depth, remaining)
        bound_map(next, depth, items - 1, remaining, Map.put(acc, key, value))
    end
  end

  defp bounded_binary(value) when byte_size(value) <= @max_binary_bytes,
    do: String.replace_invalid(value, "")

  defp bounded_binary(value) do
    prefix = value |> binary_part(0, @max_binary_bytes) |> String.replace_invalid("")
    {:truncated_binary, prefix, byte_size(value)}
  end

  defp bounded_string(value) do
    value
    |> binary_part(0, min(byte_size(value), @max_binary_bytes))
    |> String.replace_invalid("")
  end
end
