defmodule Arbor.Persistence.ConversationWindow do
  @moduledoc false

  alias Arbor.Persistence.ConversationPage

  @maximum 9_223_372_036_854_775_807
  @page_bytes 1_048_512
  @keys [:before, :after, :through, :limit]
  @assistant_statuses ~w(complete interrupted cancelled failed streaming)

  def normalize_options(opts) do
    if Keyword.keyword?(opts) do
      keys = Keyword.keys(opts)
      before = Keyword.get(opts, :before)
      after_cursor = Keyword.get(opts, :after)
      through = Keyword.get(opts, :through)
      limit = Keyword.get(opts, :limit, 20)

      valid =
        length(keys) == length(Enum.uniq(keys)) and Enum.all?(keys, &(&1 in @keys)) and
          not (Keyword.has_key?(opts, :before) and Keyword.has_key?(opts, :after)) and
          optional_ordinal?(opts, :before, before, 1) and
          optional_ordinal?(opts, :after, after_cursor, 0) and
          optional_ordinal?(opts, :through, through, 0) and
          is_integer(limit) and limit in 1..100 and
          (is_nil(through) or
             ((is_nil(before) or before <= through) and
                (is_nil(after_cursor) or after_cursor <= through)))

      if valid,
        do: {:ok, %{before: before, after: after_cursor, through: through, limit: limit}},
        else: {:error, :invalid_options}
    else
      {:error, :invalid_options}
    end
  end

  def pinned_head(current, bounds) do
    head = bounds.through || current

    if ordinal?(current, 0) and ordinal?(head, 0) and head <= current and
         (is_nil(bounds.before) or bounds.before <= head) and
         (is_nil(bounds.after) or bounds.after <= head),
       do: {:ok, head},
       else: {:error, :invalid_cursor}
  end

  def project(rows, head, has_older, has_newer) do
    with {:ok, entries} <- ConversationPage.project_entries(rows),
         {:ok, entries} <- project_statuses(rows, entries) do
      window = %{
        entries: entries,
        head: head,
        first: if(entries == [], do: 0, else: hd(entries).entry_ordinal),
        last: if(entries == [], do: 0, else: List.last(entries).entry_ordinal),
        has_older: has_older,
        has_newer: has_newer
      }

      if byte_size(Jason.encode!(window)) <= @page_bytes,
        do: {:ok, window},
        else: {:error, :page_too_large}
    end
  end

  # Window readers need the persisted assistant completion state. The legacy
  # replay projection remains unchanged, and no other metadata crosses here.
  defp project_statuses(rows, entries) do
    Enum.zip(rows, entries)
    |> Enum.reduce_while({:ok, []}, fn {row, entry}, {:ok, acc} ->
      case project_status(row, entry) do
        {:ok, projected} -> {:cont, {:ok, [projected | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, projected} -> {:ok, Enum.reverse(projected)}
      error -> error
    end
  end

  defp project_status(%{role: "assistant", metadata: %{"status" => status}}, entry)
       when status in @assistant_statuses,
       do: {:ok, Map.put(entry, :status, status)}

  defp project_status(%{role: "assistant", metadata: %{"status" => _}}, _entry),
    do: {:error, :invalid_transcript}

  defp project_status(_row, entry), do: {:ok, entry}

  defp optional_ordinal?(opts, key, value, minimum),
    do: not Keyword.has_key?(opts, key) or ordinal?(value, minimum)

  defp ordinal?(value, minimum),
    do: is_integer(value) and value >= minimum and value <= @maximum
end
