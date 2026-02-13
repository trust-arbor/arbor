defmodule Arbor.Orchestrator.Handlers.MapHandler do
  @moduledoc """
  Handler that iterates over a collection, applying a handler to each item
  and collecting results. The batch processing primitive.

  Node attributes:
    - `source_key` - context key with the collection (required)
    - `item_key` - context key for current item (default: "map.current_item")
    - `index_key` - context key for current index (default: "map.current_index")
    - `result_key` - context key to extract per-item result (default: "last_response")
    - `collect_key` - context key to store all results (default: "map.results")
    - `max_concurrency` - parallel items, "1" = sequential (default: "1")
    - `on_item_error` - "skip", "fail", "collect_nil" (default: "skip")
    - `handler_type` - type of handler to apply per item (for inline mode)
    - `handler_attrs` - JSON string of attrs for the per-item handler
  """

  @behaviour Arbor.Orchestrator.Handlers.Handler

  alias Arbor.Orchestrator.Engine.{Context, Outcome}
  alias Arbor.Orchestrator.Graph.Node

  @impl true
  def execute(node, context, graph, opts) do
    try do
      source_key = Map.get(node.attrs, "source_key")

      unless source_key do
        raise "map handler requires 'source_key' attribute"
      end

      raw = Context.get(context, source_key)

      unless raw do
        raise "source key '#{source_key}' not found in context"
      end

      collection = parse_collection(raw)

      item_key = Map.get(node.attrs, "item_key", "map.current_item")
      index_key = Map.get(node.attrs, "index_key", "map.current_index")
      result_key = Map.get(node.attrs, "result_key", "last_response")
      collect_key = Map.get(node.attrs, "collect_key", "map.results")
      max_concurrency = parse_int(Map.get(node.attrs, "max_concurrency"), 1)
      on_error = Map.get(node.attrs, "on_item_error", "skip")

      item_handler = resolve_item_handler(node, opts)

      results =
        process_items(
          collection,
          item_handler,
          context,
          graph,
          opts,
          %{
            item_key: item_key,
            index_key: index_key,
            result_key: result_key,
            max_concurrency: max_concurrency
          }
        )

      {collected, stats} = collect_results(results, on_error)

      if on_error == "fail" and stats.error_count > 0 do
        first_error = Enum.find(results, fn {status, _, _} -> status == :error end)
        reason = if first_error, do: elem(first_error, 2), else: "item processing failed"

        %Outcome{
          status: :fail,
          failure_reason: "map failed on item: #{reason}",
          context_updates: build_updates(collected, stats, collect_key, node)
        }
      else
        %Outcome{
          status: :success,
          notes:
            "Processed #{stats.total} items (#{stats.success_count} ok, #{stats.error_count} errors)",
          context_updates: build_updates(collected, stats, collect_key, node)
        }
      end
    rescue
      e ->
        %Outcome{
          status: :fail,
          failure_reason: "map handler error: #{Exception.message(e)}"
        }
    end
  end

  @impl true
  def idempotency, do: :side_effecting

  # --- Collection parsing ---

  defp parse_collection(list) when is_list(list), do: list

  defp parse_collection(str) when is_binary(str) do
    case Jason.decode(str) do
      {:ok, list} when is_list(list) ->
        list

      _ ->
        lines = str |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

        if length(lines) > 1,
          do: lines,
          else: raise("cannot parse '#{String.slice(str, 0, 50)}' as collection")
    end
  end

  defp parse_collection(other) do
    raise "expected list or parseable string, got: #{inspect(other)}"
  end

  # --- Item handler resolution ---

  defp resolve_item_handler(node, opts) do
    cond do
      handler_fn = Keyword.get(opts, :item_handler) ->
        handler_fn

      handler_type = Map.get(node.attrs, "handler_type") ->
        handler_attrs =
          case Map.get(node.attrs, "handler_attrs") do
            nil ->
              %{}

            str when is_binary(str) ->
              case Jason.decode(str) do
                {:ok, map} when is_map(map) -> map
                _ -> %{}
              end

            map when is_map(map) ->
              map
          end

        fn _item, child_context, graph, child_opts ->
          child_node = %Node{
            id: "#{node.id}_item",
            attrs: Map.merge(handler_attrs, %{"type" => handler_type})
          }

          handler_module = Arbor.Orchestrator.Handlers.Registry.resolve(child_node)
          handler_module.execute(child_node, child_context, graph, child_opts)
        end

      true ->
        raise "map handler requires 'handler_type' attribute or :item_handler opt"
    end
  end

  # --- Item processing ---

  defp process_items(collection, handler, context, graph, opts, config) do
    indexed = Enum.with_index(collection)

    if config.max_concurrency <= 1 do
      Enum.map(indexed, fn {item, idx} ->
        process_single_item(item, idx, handler, context, graph, opts, config)
      end)
    else
      indexed
      |> Task.async_stream(
        fn {item, idx} ->
          process_single_item(item, idx, handler, context, graph, opts, config)
        end,
        max_concurrency: config.max_concurrency,
        ordered: true
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, reason} -> {:error, nil, inspect(reason)}
      end)
    end
  end

  defp process_single_item(item, idx, handler, context, graph, opts, config) do
    child_context =
      context
      |> Context.set(config.item_key, item)
      |> Context.set(config.index_key, to_string(idx))

    try do
      case handler.(item, child_context, graph, opts) do
        %Outcome{status: :success} = outcome ->
          result = Map.get(outcome.context_updates, config.result_key, item)
          {:ok, result, nil}

        %Outcome{status: :fail} = outcome ->
          {:error, nil, outcome.failure_reason || "failed"}

        other ->
          {:ok, other, nil}
      end
    rescue
      e -> {:error, nil, Exception.message(e)}
    end
  end

  # --- Result collection ---

  defp collect_results(results, on_error) do
    total = length(results)

    {collected, errors} =
      Enum.reduce(results, {[], []}, fn
        {:ok, value, _}, {acc, errs} ->
          {acc ++ [value], errs}

        {:error, _, reason}, {acc, errs} ->
          case on_error do
            "collect_nil" -> {acc ++ [nil], errs ++ [reason]}
            "skip" -> {acc, errs ++ [reason]}
            "fail" -> {acc, errs ++ [reason]}
            _ -> {acc, errs ++ [reason]}
          end
      end)

    stats = %{
      total: total,
      success_count: total - length(errors),
      error_count: length(errors),
      errors: errors
    }

    {collected, stats}
  end

  # --- Outcome building ---

  defp build_updates(collected, stats, collect_key, node) do
    error_entries =
      stats.errors
      |> Enum.with_index()
      |> Enum.map(fn {reason, idx} -> %{index: idx, error: reason} end)

    %{
      collect_key => Jason.encode!(collected),
      "map.#{node.id}.count" => to_string(stats.total),
      "map.#{node.id}.success_count" => to_string(stats.success_count),
      "map.#{node.id}.error_count" => to_string(stats.error_count),
      "map.#{node.id}.errors" => Jason.encode!(error_entries)
    }
  end

  # --- Helpers ---

  defp parse_int(nil, default), do: default

  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {int, _} -> int
      :error -> default
    end
  end

  defp parse_int(val, _default) when is_integer(val), do: val
  defp parse_int(_, default), do: default
end
