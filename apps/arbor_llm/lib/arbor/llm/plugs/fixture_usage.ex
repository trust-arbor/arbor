defmodule Arbor.LLM.Plugs.FixtureUsage do
  @moduledoc false

  # The pinned ReqLLM.Usage.{Tool,Image,Cost} / Billing producer schemas.
  # Nested map keys carry an atom/string tag so replay preserves the exact
  # adapter-visible shape without creating atoms from fixture input.
  @tool_names [:web_search, :web_search_preview, :file_search, :mcp, :x_search]
  @max_count 1_000_000_000
  @max_cost 1_000_000.0
  @max_items 128
  @max_label_bytes 256

  def encode(field, value), do: transform(value, schema(field), :encode)
  def decode(field, value), do: transform(value, schema(field), :decode)

  defp schema(:tool_usage) do
    entry = {:map, %{count: :count, unit: {:enum, [:call, :source, :query]}}, [:count, :unit]}
    {:map, Map.new(@tool_names, &{&1, entry}), []}
  end

  defp schema(:image_usage),
    do: {:map, %{generated: {:map, %{count: :count, size_class: :label}, [:count]}}, []}

  defp schema(:cost) do
    item =
      {:map,
       %{
         id: :label,
         count: :count,
         cost: :cost,
         kind: {:enum, [:tokens, :tools, :images, :storage]},
         component: :label,
         quantity: :count
       }, [:id, :count, :cost, :kind, :component, :quantity]}

    fields = %{
      tokens: :cost,
      tools: :cost,
      images: :cost,
      storage: :cost,
      total: :cost,
      input_cost: :cost,
      output_cost: :cost,
      reasoning_cost: :cost,
      line_items: {:list, item}
    }

    {:map, fields, Map.keys(fields)}
  end

  defp transform(value, {:map, fields, required}, mode)
       when is_map(value) and not is_struct(value) and map_size(value) <= @max_items do
    with :ok <- required_fields(value, required, mode) do
      transform_map(value, fields, mode)
    end
  end

  defp transform(value, {:list, item_schema}, mode) when is_list(value),
    do: transform_list(value, item_schema, mode, [], 0)

  defp transform(value, :count, _mode)
       when is_number(value) and value >= 0 and value <= @max_count,
       do: {:ok, value}

  defp transform(value, :cost, _mode)
       when is_number(value) and value >= 0 and value <= @max_cost,
       do: {:ok, value}

  defp transform(value, :label, _mode)
       when is_binary(value) and byte_size(value) <= @max_label_bytes do
    if String.valid?(value), do: {:ok, value}, else: :error
  end

  defp transform(value, {:enum, allowed}, :encode) when is_atom(value) do
    if value in allowed,
      do: {:ok, %{"atom" => Atom.to_string(value)}},
      else: :error
  end

  defp transform(%{"atom" => name} = value, {:enum, allowed}, :decode)
       when map_size(value) == 1 and is_binary(name) do
    case Enum.find(allowed, &(Atom.to_string(&1) == name)) do
      nil -> :error
      atom -> {:ok, atom}
    end
  end

  defp transform(value, {:enum, allowed}, _mode) when is_binary(value) do
    if Enum.any?(allowed, &(Atom.to_string(&1) == value)), do: {:ok, value}, else: :error
  end

  defp transform(_value, _schema, _mode), do: :error

  defp transform_map(value, fields, mode) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, item}, {:ok, acc} ->
      with {:ok, field, output_key} <- map_key(key, fields, mode),
           {:ok, output} <- transform(item, Map.fetch!(fields, field), mode) do
        {:cont, {:ok, Map.put(acc, output_key, output)}}
      else
        :error -> {:halt, :error}
      end
    end)
  end

  defp transform_list([], _schema, _mode, acc, _count), do: {:ok, Enum.reverse(acc)}

  defp transform_list([item | rest], schema, mode, acc, count) when count < @max_items do
    with {:ok, output} <- transform(item, schema, mode) do
      transform_list(rest, schema, mode, [output | acc], count + 1)
    end
  end

  defp transform_list(_items, _schema, _mode, _acc, _count), do: :error

  defp map_key(key, fields, :encode) when is_atom(key) do
    if Map.has_key?(fields, key), do: {:ok, key, "a:" <> Atom.to_string(key)}, else: :error
  end

  defp map_key(key, fields, :encode) when is_binary(key) do
    with {:ok, field} <- known_field(key, fields) do
      {:ok, field, "s:" <> key}
    end
  end

  defp map_key("a:" <> name, fields, :decode) do
    with {:ok, field} <- known_field(name, fields), do: {:ok, field, field}
  end

  defp map_key("s:" <> name, fields, :decode) do
    with {:ok, field} <- known_field(name, fields), do: {:ok, field, name}
  end

  defp map_key(_key, _fields, _mode), do: :error

  defp required_fields(value, required, mode) do
    if Enum.all?(required, &present_field?(value, &1, mode)), do: :ok, else: :error
  end

  defp present_field?(value, field, :encode),
    do: Map.has_key?(value, field) or Map.has_key?(value, Atom.to_string(field))

  defp present_field?(value, field, :decode),
    do:
      Map.has_key?(value, "a:" <> Atom.to_string(field)) or
        Map.has_key?(value, "s:" <> Atom.to_string(field))

  defp known_field(name, fields) do
    case Enum.find(Map.keys(fields), &(Atom.to_string(&1) == name)) do
      nil -> :error
      field -> {:ok, field}
    end
  end
end
