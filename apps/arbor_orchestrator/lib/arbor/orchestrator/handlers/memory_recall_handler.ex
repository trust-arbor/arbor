defmodule Arbor.Orchestrator.Handlers.MemoryRecallHandler do
  @moduledoc """
  Handler for memory.recall nodes that retrieve relevant facts from a
  persistent JSONL memory store.

  This enables pipelines to learn from their own execution history — retrieving
  previously discovered facts, decisions, and patterns.

  Node attributes:
    - `memory_store` - path to JSONL memory file (REQUIRED)
    - `query_key` - context key to use as retrieval query (default: last_response)
    - `strategy` - retrieval strategy: "recent" (default), "keyword", "tag_match"
    - `top_k` - max memories to retrieve (default: 5)
    - `tags` - comma-separated tag filter (only recall memories with these tags)
    - `result_key` - context key to store results (default: recalled_memories)
    - `format` - output format: "text" (default), "json"
    - `include_expired` - whether to include expired memories (default: false)

  Strategies:
    - recent: Return the most recent memories (optionally filtered by tags)
    - keyword: Score memories by keyword overlap with query text
    - tag_match: Return memories matching specified tags, sorted by recency

  Context updates written:
    - last_stage: node ID
    - {result_key}: the recalled memories (formatted text or JSON)
    - memory.{node_id}.count: number of memories recalled
    - memory.{node_id}.strategy: strategy used
    - memory.{node_id}.store_path: path to the memory store
  """

  @behaviour Arbor.Orchestrator.Handlers.Handler

  alias Arbor.Orchestrator.Engine.{Context, Outcome}
  alias Arbor.Orchestrator.Graph.Node

  import Arbor.Orchestrator.Handlers.Helpers

  @impl true
  def execute(%Node{attrs: attrs, id: node_id}, context, _graph, opts) do
    store_path = Map.get(attrs, "memory_store")
    query_key = Map.get(attrs, "query_key", "last_response")
    strategy = Map.get(attrs, "strategy", "recent")
    top_k = parse_int(Map.get(attrs, "top_k", "5"), 5)
    tags_filter = parse_csv(Map.get(attrs, "tags", ""))
    result_key = Map.get(attrs, "result_key", "recalled_memories")
    format = Map.get(attrs, "format", "text")
    include_expired = Map.get(attrs, "include_expired", "false") == "true"

    if is_nil(store_path) or store_path == "" do
      %Outcome{
        status: :fail,
        failure_reason: "memory.recall requires memory_store attribute"
      }
    else
      # Load all memories from JSONL
      memories = load_memories(store_path, include_expired)

      # Get query text for keyword strategy
      query = Context.get(context, query_key) || ""
      query = if is_binary(query), do: query, else: to_string(query)

      # Apply strategy
      selected = apply_strategy(strategy, memories, query, tags_filter, top_k)

      # Format output
      output = format_memories(selected, format)

      # Write to stage dir
      case Keyword.get(opts, :logs_root) do
        nil ->
          :ok

        logs_root ->
          stage_dir = Path.join(logs_root, node_id)
          File.mkdir_p!(stage_dir)
          File.write!(Path.join(stage_dir, "recalled.md"), output)
      end

      %Outcome{
        status: :success,
        context_updates: %{
          "last_stage" => node_id,
          result_key => output,
          "memory.#{node_id}.count" => length(selected),
          "memory.#{node_id}.strategy" => strategy,
          "memory.#{node_id}.store_path" => store_path
        },
        notes: "Recalled #{length(selected)} memories via #{strategy} strategy"
      }
    end
  rescue
    e ->
      %Outcome{
        status: :fail,
        failure_reason: "MemoryRecall handler error: #{Exception.message(e)}"
      }
  end

  @impl true
  def idempotency, do: :read_only

  defp load_memories(path, include_expired) do
    if File.exists?(path) do
      path
      |> File.read!()
      |> String.split("\n")
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&Jason.decode!/1)
      |> then(fn memories ->
        if include_expired do
          memories
        else
          Enum.reject(memories, &expired?/1)
        end
      end)
    else
      []
    end
  end

  defp expired?(%{"expires_at" => nil}), do: false
  defp expired?(%{"expires_at" => ""}), do: false

  defp expired?(%{"expires_at" => expires_at}) when is_binary(expires_at) do
    case DateTime.from_iso8601(expires_at) do
      {:ok, dt, _offset} -> DateTime.compare(dt, DateTime.utc_now()) == :lt
      _ -> false
    end
  end

  defp expired?(_), do: false

  defp apply_strategy("recent", memories, _query, tags_filter, top_k) do
    memories
    |> filter_by_tags(tags_filter)
    |> sort_by_timestamp_desc()
    |> Enum.take(top_k)
  end

  defp apply_strategy("keyword", memories, query, tags_filter, top_k) do
    query_words = tokenize(query)

    memories
    |> filter_by_tags(tags_filter)
    |> Enum.map(fn m ->
      score = keyword_score(m["fact"] || "", query_words)
      {m, score}
    end)
    |> Enum.sort_by(fn {m, score} -> {-score, -timestamp_to_unix(m["timestamp"])} end)
    |> Enum.take(top_k)
    |> Enum.map(fn {m, _score} -> m end)
  end

  defp apply_strategy("tag_match", memories, _query, tags_filter, top_k) do
    memories
    |> Enum.filter(fn m ->
      memory_tags = m["tags"] || []
      Enum.all?(tags_filter, fn tag -> tag in memory_tags end)
    end)
    |> sort_by_timestamp_desc()
    |> Enum.take(top_k)
  end

  defp apply_strategy(_unknown, memories, _query, _tags, top_k) do
    memories
    |> sort_by_timestamp_desc()
    |> Enum.take(top_k)
  end

  defp filter_by_tags(memories, []), do: memories

  defp filter_by_tags(memories, tags_filter) do
    Enum.filter(memories, fn m ->
      memory_tags = m["tags"] || []
      Enum.any?(tags_filter, fn tag -> tag in memory_tags end)
    end)
  end

  defp sort_by_timestamp_desc(memories) do
    Enum.sort_by(memories, &timestamp_to_unix(&1["timestamp"]), :desc)
  end

  defp timestamp_to_unix(nil), do: 0

  defp timestamp_to_unix(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _offset} -> DateTime.to_unix(dt)
      _ -> 0
    end
  end

  defp timestamp_to_unix(_), do: 0

  defp tokenize(text) do
    text
    |> String.downcase()
    |> String.split(~r/\s+/)
    |> Enum.reject(&(String.length(&1) < 3))
    |> Enum.uniq()
  end

  defp keyword_score(fact, query_words) do
    fact_lower = String.downcase(fact)
    Enum.count(query_words, fn word -> String.contains?(fact_lower, word) end)
  end

  defp format_memories([], _format), do: "No memories found."

  defp format_memories(memories, "json") do
    Jason.encode!(memories, pretty: true)
  end

  defp format_memories(memories, _text_format) do
    Enum.map_join(memories, "\n\n---\n\n", fn m ->
      tags = Enum.join(m["tags"] || [], ", ")

      "## Memory: #{m["id"]}\n" <>
        "**Tags:** #{tags}\n" <>
        "**Source:** #{m["source"]}\n" <>
        "**Date:** #{m["timestamp"]}\n\n" <>
        (m["fact"] || "")
    end)
  end
end
