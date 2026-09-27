defmodule Arbor.Persistence.ConversationPage do
  @moduledoc false

  @max_ordinal 9_223_372_036_854_775_807
  @max_entry_bytes 262_144
  # Reserve 64 bytes for Comms' canonical 36-byte engagement_id JSON member
  # (55 bytes including punctuation), keeping the public envelope <= 1 MiB.
  @max_page_bytes 1_048_512
  @keys [:after, :through, :limit]

  def normalize_options(opts) do
    if Keyword.keyword?(opts) do
      keys = Keyword.keys(opts)
      after_ordinal = Keyword.get(opts, :after, 0)
      through = Keyword.get(opts, :through)
      limit = Keyword.get(opts, :limit, 50)

      valid =
        length(keys) == length(Enum.uniq(keys)) and Enum.all?(keys, &(&1 in @keys)) and
          ordinal?(after_ordinal) and is_integer(limit) and limit in 1..100 and
          (not Keyword.has_key?(opts, :through) or
             (ordinal?(through) and through >= after_ordinal))

      if valid,
        do: {:ok, %{after: after_ordinal, through: through, limit: limit}},
        else: {:error, :invalid_options}
    else
      {:error, :invalid_options}
    end
  end

  def validate_identifiers(agent_id, engagement_id) do
    if identifier?(agent_id) and identifier?(engagement_id) and
         Regex.match?(~r/\Aeng_[0-9a-f]{32}\z/, engagement_id) do
      :ok
    else
      {:error, :invalid_identifier}
    end
  end

  def pinned_head(current_head, %{after: after_ordinal, through: through}) do
    head = through || current_head

    if ordinal?(current_head) and head <= current_head and after_ordinal <= head,
      do: {:ok, head},
      else: {:error, :invalid_cursor}
  end

  def project(rows, bounds, head) do
    has_more = length(rows) > bounds.limit
    selected = Enum.take(rows, bounds.limit)

    with {:ok, entries} <- project_entries(selected) do
      cursor = if has_more, do: List.last(entries).entry_ordinal, else: head
      page = %{entries: entries, cursor: cursor, head: head, has_more: has_more}

      if byte_size(Jason.encode!(page)) <= @max_page_bytes,
        do: {:ok, page},
        else: {:error, :page_too_large}
    end
  end

  defp project_entries(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
      case project_entry(row) do
        {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  defp project_entry(row) do
    with true <- identifier?(row.id),
         true <- row.entry_type in ["user", "assistant"],
         true <- row.role == row.entry_type,
         true <- ordinal?(row.entry_ordinal) and row.entry_ordinal > 0,
         %DateTime{} <- row.timestamp,
         {:ok, content} <- text_content(row.content) do
      {:ok,
       %{
         id: row.id,
         role: row.role,
         content: content,
         timestamp: DateTime.to_iso8601(row.timestamp),
         entry_ordinal: row.entry_ordinal
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_transcript}
    end
  end

  defp text_content(blocks) when is_list(blocks) do
    Enum.reduce_while(blocks, {:ok, [], 0}, fn
      %{"type" => "text", "text" => text}, {:ok, acc, size} when is_binary(text) ->
        bytes = size + byte_size(text) + if(acc == [], do: 0, else: 1)

        cond do
          not String.valid?(text) -> {:halt, {:error, :invalid_transcript}}
          bytes > @max_entry_bytes -> {:halt, {:error, :page_too_large}}
          true -> {:cont, {:ok, [text | acc], bytes}}
        end

      %{"type" => type}, acc when is_binary(type) and type != "text" ->
        {:cont, acc}

      _, _ ->
        {:halt, {:error, :invalid_transcript}}
    end)
    |> case do
      {:ok, texts, _} -> {:ok, texts |> Enum.reverse() |> Enum.join("\n")}
      error -> error
    end
  end

  defp text_content(_), do: {:error, :invalid_transcript}

  defp identifier?(value) when is_binary(value),
    do: byte_size(value) in 1..256 and String.valid?(value) and String.trim(value) != ""

  defp identifier?(_), do: false

  defp ordinal?(value),
    do: is_integer(value) and value >= 0 and value <= @max_ordinal
end
