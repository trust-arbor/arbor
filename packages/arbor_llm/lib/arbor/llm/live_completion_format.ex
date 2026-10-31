defmodule Arbor.LLM.LiveCompletionFormat do
  @moduledoc false

  alias Arbor.LLM.ResponseBudget

  # A small JSON-schema subset for tool-free completion. No references,
  # dynamic schemas, extension keywords, or provider controls are admitted.
  def valid?(options) when options == %{}, do: true

  def valid?(%{response_format: format} = options) when map_size(options) == 1 do
    with :ok <-
           ResponseBudget.validate(format,
             max_bytes: 16_384,
             max_nodes: 1024,
             max_depth: 12,
             max_map_keys: 256,
             max_list_items: 512
           ),
         %{"type" => "json_schema", "json_schema" => definition} when map_size(format) == 2 <-
           format,
         %{"name" => name, "strict" => true, "schema" => schema} when map_size(definition) == 3 <-
           definition,
         true <- is_binary(name) and Regex.match?(~r/\A[A-Za-z][A-Za-z0-9_-]{0,63}\z/, name),
         true <- schema?(schema),
         {:ok, encoded} <- Jason.encode(format),
         true <- byte_size(encoded) <= 16_384 do
      true
    else
      _ -> false
    end
  end

  def valid?(_options), do: false

  # ReqLLM's pinned NimbleOptions map type requires atom wrapper keys.
  # Convert only admitted, fixed names; arbitrary schema/property names stay data.
  def req_options(options) when options == %{}, do: %{}

  def req_options(%{
        response_format: %{
          "type" => type,
          "json_schema" => %{
            "name" => name,
            "strict" => strict,
            "schema" => schema
          }
        }
      }) do
    %{response_format: %{type: type, json_schema: %{name: name, strict: strict, schema: schema}}}
  end

  defp schema?(
         %{
           "type" => "object",
           "properties" => properties,
           "required" => required,
           "additionalProperties" => false
         } = schema
       )
       when map_size(schema) == 4 and is_map(properties) and is_list(required) do
    Enum.all?(properties, fn {key, value} -> is_binary(key) and schema?(value) end) and
      Enum.sort(required) == Enum.sort(Map.keys(properties))
  end

  defp schema?(
         %{"type" => "array", "items" => items, "minItems" => minimum, "maxItems" => maximum} =
           schema
       )
       when map_size(schema) == 4 do
    is_integer(minimum) and is_integer(maximum) and minimum >= 0 and
      maximum >= minimum and maximum <= 512 and schema?(items)
  end

  defp schema?(%{"type" => "string", "enum" => values} = schema)
       when map_size(schema) == 2 and is_list(values) and values != [] do
    Enum.all?(values, &is_binary/1) and length(Enum.uniq(values)) == length(values)
  end

  defp schema?(%{"type" => type} = schema) when map_size(schema) == 1,
    do: type in ["string", "number", "integer", "boolean", "null"]

  defp schema?(_schema), do: false
end
