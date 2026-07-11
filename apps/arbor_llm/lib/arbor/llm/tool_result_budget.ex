defmodule Arbor.LLM.ToolResultBudget do
  @moduledoc false

  alias Arbor.LLM.ResponseBudget

  @limits [
    max_bytes: 16_777_216,
    max_nodes: 100_000,
    max_depth: 32,
    max_map_keys: 10_000,
    max_list_items: 100_000
  ]
  @aggregate_maxima %{
    bytes: 16_777_216,
    nodes: 100_000,
    map_keys: 10_000,
    list_items: 100_000
  }
  @aggregate_keys [:bytes, :nodes, :map_keys, :list_items]

  @type state :: %{
          bytes: non_neg_integer(),
          nodes: non_neg_integer(),
          map_keys: non_neg_integer(),
          list_items: non_neg_integer()
        }

  @spec new() :: state()
  def new, do: %{bytes: 0, nodes: 0, map_keys: 0, list_items: 0}

  @spec encode(term(), state()) :: {:ok, binary(), state()} | {:error, term()}
  def encode(value, aggregate) do
    with {:ok, aggregate} <- validate_state(aggregate),
         {:ok, measured} <- ResponseBudget.measure(value, @limits),
         {:ok, encoded} <- encode_json(value),
         {:ok, next} <- add_measurements(aggregate, measured, byte_size(encoded)) do
      {:ok, encoded, next}
    else
      {:error, reason} -> {:error, {:invalid_tool_result, reason}}
    end
  end

  @spec account(term(), state()) :: {:ok, state()} | {:error, term()}
  def account(value, aggregate) do
    with {:ok, aggregate} <- validate_state(aggregate),
         {:ok, measured} <- ResponseBudget.measure(value, @limits),
         {:ok, next} <- add_measurements(aggregate, measured, measured.bytes) do
      {:ok, next}
    else
      {:error, reason} -> {:error, {:invalid_tool_result, reason}}
    end
  end

  defp add_measurements(aggregate, measured, appended_bytes) do
    next = %{
      bytes: aggregate.bytes + appended_bytes,
      nodes: aggregate.nodes + measured.nodes,
      map_keys: aggregate.map_keys + measured.map_keys,
      list_items: aggregate.list_items + measured.list_items
    }

    case Enum.find(@aggregate_keys, fn key ->
           Map.fetch!(next, key) > Map.fetch!(@aggregate_maxima, key)
         end) do
      nil -> {:ok, next}
      key -> {:error, {:tool_result_aggregate_exceeded, key, Map.fetch!(@aggregate_maxima, key)}}
    end
  end

  defp validate_state(state) when is_map(state) do
    if map_size(state) == length(@aggregate_keys) and
         Enum.all?(@aggregate_keys, fn key ->
           case Map.fetch(state, key) do
             {:ok, value} ->
               is_integer(value) and value >= 0 and value <= Map.fetch!(@aggregate_maxima, key)

             :error ->
               false
           end
         end) do
      {:ok, state}
    else
      {:error, :invalid_tool_result_budget}
    end
  end

  defp validate_state(_state), do: {:error, :invalid_tool_result_budget}

  defp encode_json(value) do
    case Jason.encode(value) do
      {:ok, encoded} -> {:ok, encoded}
      {:error, _reason} -> {:error, :tool_result_must_be_json_compatible}
    end
  rescue
    _exception -> {:error, :tool_result_must_be_json_compatible}
  end
end
