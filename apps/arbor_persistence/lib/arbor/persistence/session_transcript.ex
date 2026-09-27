defmodule Arbor.Persistence.SessionTranscript do
  @moduledoc false

  alias Arbor.Contracts.Security.TaintEnvelope

  @maximum 9_223_372_036_854_775_807
  @entry_bytes 262_144
  @page_bytes 8_388_608

  def options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and
         length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))) and
         Enum.all?(Keyword.keys(opts), &(&1 in [:after, :through, :limit])) do
      after_cursor = Keyword.get(opts, :after)
      through = Keyword.get(opts, :through)
      limit = Keyword.get(opts, :limit, 1_000)

      if (is_nil(after_cursor) or cursor?(after_cursor)) and
           (is_nil(through) or cursor?(through)) and is_integer(limit) and limit in 1..1_000 do
        {:ok, %{after: after_cursor, through: through, limit: limit}}
      else
        {:error, :invalid_transcript_options}
      end
    else
      {:error, :invalid_transcript_options}
    end
  end

  def options(_), do: {:error, :invalid_transcript_options}

  def head(maximum, bounds) do
    head = bounds.through || maximum

    if cursor?(maximum) and cursor?(head) and head <= maximum and
         (is_nil(bounds.after) or bounds.after <= head),
       do: {:ok, head},
       else: {:error, :transcript_cursor_invalid}
  end

  def project(rows, scope, bounds, head) do
    more? = length(rows) > bounds.limit
    selected = Enum.take(rows, bounds.limit)
    selected = if is_nil(bounds.after), do: Enum.reverse(selected), else: selected

    with {:ok, entries, _bytes} <- project_entries(selected, scope.engagement_id) do
      {:ok,
       Map.merge(scope, %{
         entries: entries,
         head: head,
         cursor:
           if(more? and not is_nil(bounds.after),
             do: List.last(entries).entry_ordinal,
             else: head
           ),
         has_more: more? and not is_nil(bounds.after),
         truncated: more? and is_nil(bounds.after)
       })}
    end
  end

  defp project_entries(rows, engagement_id) do
    Enum.reduce_while(rows, {:ok, [], 0}, fn row, {:ok, entries, bytes} ->
      case project_entry(row, engagement_id) do
        {:ok, entry, size} when bytes + size <= @page_bytes ->
          {:cont, {:ok, [entry | entries], bytes + size}}

        _ ->
          {:halt, {:error, :invalid_transcript}}
      end
    end)
    |> case do
      {:ok, entries, bytes} -> {:ok, Enum.reverse(entries), bytes}
      error -> error
    end
  end

  defp project_entry(row, engagement_id) do
    with true <- is_binary(row.id) and byte_size(row.id) == 36,
         true <- row.role in ["user", "assistant"] and row.entry_type == row.role,
         true <- cursor?(row.entry_ordinal) and row.entry_ordinal > 0,
         %DateTime{} <- row.timestamp,
         true <- is_list(row.content) and Enum.all?(row.content, &is_map/1),
         true <- is_map(row.metadata) and row.metadata["engagement_id"] == engagement_id,
         false <- Map.has_key?(row.metadata, :taint),
         {:ok, encoded} <- Jason.encode([row.content, row.metadata]),
         true <- byte_size(encoded) <= @entry_bytes,
         {:ok, taint, status} <-
           TaintEnvelope.resolve(Map.get(row.metadata, "taint", :missing), row.content),
         true <- status in [:verified, :legacy_unlabeled] do
      {:ok,
       %{
         id: row.id,
         entry_ordinal: row.entry_ordinal,
         role: row.role,
         content: row.content,
         metadata: row.metadata,
         timestamp: row.timestamp,
         model: row.model,
         token_usage: row.token_usage,
         taint: taint,
         taint_status: status
       }, byte_size(encoded)}
    else
      _ -> {:error, :invalid_transcript}
    end
  end

  defp cursor?(n), do: is_integer(n) and n >= 0 and n <= @maximum
end
