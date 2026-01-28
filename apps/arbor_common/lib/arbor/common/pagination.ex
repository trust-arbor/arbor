defmodule Arbor.Common.Pagination do
  @moduledoc """
  Cursor-based pagination utilities.

  Provides consistent cursor generation and parsing for paginating
  time-ordered data across Arbor applications.

  ## Cursor Format

  Cursors use the format `"timestamp_ms:id"` where:
  - `timestamp_ms` - Unix timestamp in milliseconds
  - `id` - Unique identifier of the record

  This format allows efficient pagination of time-ordered data while
  handling records with identical timestamps via the ID tiebreaker.

  ## Examples

      # Generate cursor from a record
      cursor = Arbor.Common.Pagination.generate_cursor(%{
        timestamp: ~U[2026-01-26 17:00:00Z],
        id: "evt_123"
      })
      # => "1737910800000:evt_123"

      # Parse cursor back to components
      {:ok, {timestamp, id}} = Arbor.Common.Pagination.parse_cursor(cursor)

      # Build paginated response
      response = Arbor.Common.Pagination.build_response(items, limit)
      # => %{items: [...], next_cursor: "...", has_more: true}
  """

  @type cursor :: String.t()
  @type cursor_components :: {DateTime.t(), String.t()}

  @doc """
  Generate a cursor string from a record with timestamp and id.

  The record must have `:timestamp` (DateTime) and `:id` (String) fields.

  ## Examples

      iex> record = %{timestamp: ~U[2026-01-26 17:00:00Z], id: "evt_123"}
      iex> Arbor.Common.Pagination.generate_cursor(record)
      "1737910800000:evt_123"

      iex> Arbor.Common.Pagination.generate_cursor(nil)
      nil
  """
  @spec generate_cursor(map() | nil) :: cursor() | nil
  def generate_cursor(%{timestamp: %DateTime{} = timestamp, id: id}) when is_binary(id) do
    timestamp_ms = DateTime.to_unix(timestamp, :millisecond)
    "#{timestamp_ms}:#{id}"
  end

  def generate_cursor(%{timestamp: timestamp, id: id})
      when is_integer(timestamp) and is_binary(id) do
    "#{timestamp}:#{id}"
  end

  def generate_cursor(_), do: nil

  @doc """
  Parse a cursor string back to its components.

  Returns `{:ok, {timestamp, id}}` on success, `:error` on failure.

  ## Examples

      iex> Arbor.Common.Pagination.parse_cursor("1737910800000:evt_123")
      {:ok, {~U[2026-01-26 17:00:00.000Z], "evt_123"}}

      iex> Arbor.Common.Pagination.parse_cursor("invalid")
      :error

      iex> Arbor.Common.Pagination.parse_cursor(nil)
      :error
  """
  @spec parse_cursor(cursor() | nil) :: {:ok, cursor_components()} | :error
  def parse_cursor(cursor) when is_binary(cursor) do
    case String.split(cursor, ":", parts: 2) do
      [timestamp_str, id] when byte_size(id) > 0 ->
        parse_timestamp_and_id(timestamp_str, id)

      _ ->
        :error
    end
  end

  def parse_cursor(_), do: :error

  defp parse_timestamp_and_id(timestamp_str, id) do
    case Integer.parse(timestamp_str) do
      {timestamp_ms, ""} ->
        convert_unix_to_cursor(timestamp_ms, id)

      _ ->
        :error
    end
  end

  defp convert_unix_to_cursor(timestamp_ms, id) do
    case DateTime.from_unix(timestamp_ms, :millisecond) do
      {:ok, timestamp} -> {:ok, {timestamp, id}}
      _ -> :error
    end
  end

  @doc """
  Parse cursor and return components or nil values.

  Convenience function that returns `{timestamp, id}` or `{nil, nil}`.

  ## Examples

      iex> Arbor.Common.Pagination.parse_cursor!("1737910800000:evt_123")
      {~U[2026-01-26 17:00:00.000Z], "evt_123"}

      iex> Arbor.Common.Pagination.parse_cursor!(nil)
      {nil, nil}
  """
  @spec parse_cursor!(cursor() | nil) :: {DateTime.t() | nil, String.t() | nil}
  def parse_cursor!(cursor) do
    case parse_cursor(cursor) do
      {:ok, {timestamp, id}} -> {timestamp, id}
      :error -> {nil, nil}
    end
  end

  @doc """
  Filter items by cursor for forward pagination (descending order - newest first).

  Drops items until finding one older than the cursor, then takes remaining.

  ## Examples

      iex> items = [%{timestamp: t3, id: "3"}, %{timestamp: t2, id: "2"}, %{timestamp: t1, id: "1"}]
      iex> Arbor.Common.Pagination.filter_after_cursor(items, cursor, :desc)
  """
  @spec filter_after_cursor(list(map()), cursor() | nil, :asc | :desc) :: list(map())
  def filter_after_cursor(items, nil, _order), do: items

  def filter_after_cursor(items, cursor, order) do
    case parse_cursor(cursor) do
      {:ok, {cursor_timestamp, cursor_id}} ->
        do_filter_after_cursor(items, cursor_timestamp, cursor_id, order)

      :error ->
        items
    end
  end

  defp do_filter_after_cursor(items, cursor_timestamp, cursor_id, :desc) do
    cursor_ms = DateTime.to_unix(cursor_timestamp, :millisecond)

    Enum.drop_while(items, fn item ->
      item_ms = DateTime.to_unix(item.timestamp, :millisecond)

      cond do
        item_ms > cursor_ms -> true
        item_ms == cursor_ms and item.id >= cursor_id -> true
        true -> false
      end
    end)
  end

  defp do_filter_after_cursor(items, cursor_timestamp, cursor_id, :asc) do
    cursor_ms = DateTime.to_unix(cursor_timestamp, :millisecond)

    Enum.drop_while(items, fn item ->
      item_ms = DateTime.to_unix(item.timestamp, :millisecond)

      cond do
        item_ms < cursor_ms -> true
        item_ms == cursor_ms and item.id <= cursor_id -> true
        true -> false
      end
    end)
  end

  @doc """
  Build a standard paginated response.

  Takes a list of items and limit, returns a map with:
  - `:items` - The items for this page (up to limit)
  - `:next_cursor` - Cursor for the next page (nil if no more)
  - `:has_more` - Boolean indicating if there are more items

  ## Examples

      iex> items = [%{timestamp: t1, id: "1"}, %{timestamp: t2, id: "2"}, %{timestamp: t3, id: "3"}]
      iex> Arbor.Common.Pagination.build_response(items, 2)
      %{items: [item1, item2], next_cursor: "...:2", has_more: true}
  """
  @spec build_response(list(map()), pos_integer()) :: map()
  def build_response(items, limit) when is_list(items) and is_integer(limit) and limit > 0 do
    has_more = length(items) > limit
    page_items = Enum.take(items, limit)
    last_item = List.last(page_items)

    next_cursor =
      if has_more and last_item do
        generate_cursor(last_item)
      else
        nil
      end

    %{
      items: page_items,
      next_cursor: next_cursor,
      has_more: has_more
    }
  end

  @doc """
  Build response with custom item key name.

  ## Examples

      iex> Arbor.Common.Pagination.build_response(events, 10, :events)
      %{events: [...], next_cursor: "...", has_more: false}
  """
  @spec build_response(list(map()), pos_integer(), atom()) :: map()
  def build_response(items, limit, key) when is_atom(key) do
    response = build_response(items, limit)
    Map.put(response, key, Map.get(response, :items)) |> Map.delete(:items)
  end
end
