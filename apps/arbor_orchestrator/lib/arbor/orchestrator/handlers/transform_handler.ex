defmodule Arbor.Orchestrator.Handlers.TransformHandler do
  @moduledoc """
  Core handler for pure data transformations with no side effects.

  Canonical type: `transform`

  Performs data mapping, extraction, and formatting operations on context
  values. All operations are pure functions — no I/O, no LLM calls.

  ## Node Attributes

    - `transform` — transformation type: "json_extract", "template", "map",
      "filter", "format", "split", "join"
    - `source_key` — context key to read input from (default: "last_response")
    - `output_key` — context key to write result to (default: "transform.{node_id}")
    - `expression` — transform-specific expression (JSON path, template string, etc.)
  """

  @behaviour Arbor.Orchestrator.Handlers.Handler

  alias Arbor.Orchestrator.Engine.{Context, Outcome}

  @impl true
  def execute(node, context, _graph, _opts) do
    transform = Map.get(node.attrs, "transform", "identity")
    source_key = Map.get(node.attrs, "source_key", "last_response")
    output_key = Map.get(node.attrs, "output_key", "transform.#{node.id}")
    expression = Map.get(node.attrs, "expression")
    input = Context.get(context, source_key)

    case apply_transform(transform, input, expression) do
      {:ok, result} ->
        %Outcome{
          status: :success,
          notes: "Transform #{transform} applied",
          context_updates: %{output_key => result}
        }

      {:error, reason} ->
        %Outcome{
          status: :fail,
          failure_reason: "Transform error: #{reason}"
        }
    end
  rescue
    e ->
      %Outcome{
        status: :fail,
        failure_reason: "transform error: #{Exception.message(e)}"
      }
  end

  @impl true
  def idempotency, do: :idempotent

  # --- Transform implementations ---

  defp apply_transform("identity", input, _expr) do
    {:ok, input}
  end

  defp apply_transform("json_extract", _input, nil) do
    {:error, "json_extract requires 'expression' attribute (JSON path)"}
  end

  defp apply_transform("json_extract", input, path) when is_binary(input) do
    case Jason.decode(input) do
      {:ok, parsed} -> json_path(parsed, path)
      {:error, _} -> {:error, "input is not valid JSON"}
    end
  end

  defp apply_transform("json_extract", input, path) when is_map(input) or is_list(input) do
    json_path(input, path)
  end

  defp apply_transform("template", _input, nil) do
    {:error, "template requires 'expression' attribute (template string)"}
  end

  defp apply_transform("template", input, template) do
    result = String.replace(template, "{value}", to_string(input))
    {:ok, result}
  end

  defp apply_transform("map", input, expression) when is_binary(input) do
    case Jason.decode(input) do
      {:ok, list} when is_list(list) ->
        apply_map(list, expression)

      _ ->
        {:error, "map transform requires JSON array input"}
    end
  end

  defp apply_transform("map", input, expression) when is_list(input) do
    apply_map(input, expression)
  end

  defp apply_transform("filter", _input, nil) do
    {:error, "filter requires 'expression' attribute"}
  end

  defp apply_transform("filter", input, expression) when is_binary(input) do
    case Jason.decode(input) do
      {:ok, list} when is_list(list) ->
        apply_filter(list, expression)

      _ ->
        {:error, "filter transform requires JSON array input"}
    end
  end

  defp apply_transform("filter", input, expression) when is_list(input) do
    apply_filter(input, expression)
  end

  defp apply_transform("format", input, format) do
    formatted =
      case format do
        "json" -> Jason.encode!(input, pretty: true)
        "string" -> to_string(input)
        "inspect" -> inspect(input)
        _ -> to_string(input)
      end

    {:ok, formatted}
  rescue
    _ -> {:ok, to_string(input)}
  end

  defp apply_transform("split", input, delimiter) when is_binary(input) do
    delim = delimiter || ","
    {:ok, String.split(input, delim, trim: true) |> Enum.map(&String.trim/1)}
  end

  defp apply_transform("join", input, delimiter) when is_list(input) do
    delim = delimiter || ","
    {:ok, Enum.join(input, delim)}
  end

  defp apply_transform(unknown, _input, _expr) do
    {:error, "unknown transform type: #{unknown}"}
  end

  # --- Helpers ---

  defp json_path(data, path) do
    keys = String.split(path, ".", trim: true)

    result =
      Enum.reduce_while(keys, data, fn key, acc ->
        cond do
          is_map(acc) and Map.has_key?(acc, key) ->
            {:cont, Map.get(acc, key)}

          is_list(acc) ->
            case Integer.parse(key) do
              {idx, _} -> {:cont, Enum.at(acc, idx)}
              :error -> {:halt, nil}
            end

          true ->
            {:halt, nil}
        end
      end)

    {:ok, result}
  end

  defp apply_map(list, nil) do
    {:ok, Jason.encode!(list)}
  end

  defp apply_map(list, key) when is_binary(key) do
    result =
      Enum.map(list, fn
        item when is_map(item) -> Map.get(item, key)
        item -> item
      end)

    {:ok, result}
  end

  defp apply_filter(list, expression) do
    # Filter by key existence or truthy value
    result =
      Enum.filter(list, fn
        item when is_map(item) -> Map.get(item, expression) not in [nil, false, ""]
        item -> to_string(item) =~ expression
      end)

    {:ok, result}
  end
end
