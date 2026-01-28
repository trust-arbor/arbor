defmodule Arbor.Common.Pagination.Cursor do
  @moduledoc """
  Low-level cursor-based pagination utilities.

  Provides consistent cursor generation, parsing, and filtering logic
  for event stores and repositories across Arbor applications.

  For higher-level pagination helpers (response building, record-based
  cursor generation), see `Arbor.Common.Pagination`.

  ## Cursor Format

  Cursors are encoded as `"timestamp_ms:id"` where:
  - `timestamp_ms` is the Unix timestamp in milliseconds
  - `id` is the event/record ID

  ## Usage

      # Parse a cursor
      {:ok, {timestamp_ms, id}} = Cursor.parse("1705123456789:evt_123")

      # Generate a cursor from a record
      cursor = Cursor.generate(event.timestamp, event.id)

      # Filter records in memory
      filtered = Cursor.filter_records(records, cursor, :desc,
        timestamp_fn: & &1.timestamp,
        id_fn: & &1.id
      )

      # Check if a record passes the cursor filter
      passes? = Cursor.passes_filter?(record_ts_ms, record_id, cursor, :desc)
  """

  @doc """
  Parse a cursor string into {timestamp_ms, id}.

  ## Examples

      iex> Cursor.parse("1705123456789:evt_123")
      {:ok, {1705123456789, "evt_123"}}

      iex> Cursor.parse("invalid")
      :error
  """
  @spec parse(String.t()) :: {:ok, {integer(), String.t()}} | :error
  def parse(cursor) when is_binary(cursor) do
    case String.split(cursor, ":", parts: 2) do
      [timestamp_str, id] ->
        case Integer.parse(timestamp_str) do
          {timestamp_ms, ""} -> {:ok, {timestamp_ms, id}}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  def parse(_), do: :error

  @doc """
  Parse a cursor string into {DateTime, id} with specified precision.

  ## Options
  - `:precision` - :millisecond (default) or :microsecond

  ## Examples

      iex> Cursor.parse_datetime("1705123456789:evt_123", precision: :millisecond)
      {:ok, {~U[2024-01-13 06:04:16.789Z], "evt_123"}}
  """
  @spec parse_datetime(String.t(), keyword()) :: {:ok, {DateTime.t(), String.t()}} | :error
  def parse_datetime(cursor, opts \\ []) when is_binary(cursor) do
    precision = Keyword.get(opts, :precision, :millisecond)

    case String.split(cursor, ":", parts: 2) do
      [timestamp_str, id] ->
        case Integer.parse(timestamp_str) do
          {timestamp_int, ""} ->
            case DateTime.from_unix(timestamp_int, precision) do
              {:ok, datetime} -> {:ok, {datetime, id}}
              _ -> :error
            end

          _ ->
            :error
        end

      _ ->
        :error
    end
  end

  @doc """
  Generate a cursor from a timestamp and ID.

  The timestamp can be a DateTime or integer milliseconds.

  ## Examples

      iex> Cursor.generate(~U[2024-01-13 12:00:00Z], "evt_123")
      "1705147200000:evt_123"

      iex> Cursor.generate(1705147200000, "evt_123")
      "1705147200000:evt_123"
  """
  @spec generate(DateTime.t() | integer(), String.t()) :: String.t()
  def generate(%DateTime{} = timestamp, id) do
    timestamp_ms = DateTime.to_unix(timestamp, :millisecond)
    "#{timestamp_ms}:#{id}"
  end

  def generate(timestamp_ms, id) when is_integer(timestamp_ms) do
    "#{timestamp_ms}:#{id}"
  end

  @doc """
  Check if a record passes the cursor filter.

  This is the core comparison logic that can be used by both Ecto queries
  and in-memory filtering.

  ## Parameters
  - record_ts_ms: The record's timestamp in milliseconds
  - record_id: The record's ID
  - cursor_ts_ms: The cursor's timestamp in milliseconds
  - cursor_id: The cursor's ID
  - order: :asc or :desc

  ## Returns
  `true` if the record should be included, `false` otherwise.
  """
  @spec passes_filter?(integer(), String.t(), integer(), String.t(), :asc | :desc) :: boolean()
  def passes_filter?(record_ts_ms, record_id, cursor_ts_ms, cursor_id, order) do
    cond do
      record_ts_ms == cursor_ts_ms ->
        if order == :desc, do: record_id < cursor_id, else: record_id > cursor_id

      record_ts_ms < cursor_ts_ms ->
        order == :desc

      true ->
        order == :asc
    end
  end

  @doc """
  Filter a list of records by cursor in memory.

  ## Options
  - `:timestamp_fn` - Function to extract timestamp from record (required)
  - `:id_fn` - Function to extract ID from record (required)

  ## Examples

      records = [%{timestamp: ~U[...], id: "1"}, ...]
      filtered = Cursor.filter_records(records, cursor, :desc,
        timestamp_fn: & &1.timestamp,
        id_fn: & &1.id
      )
  """
  @spec filter_records(list(), String.t() | nil, :asc | :desc, keyword()) :: list()
  def filter_records(records, nil, _order, _opts), do: records

  def filter_records(records, cursor, order, opts) do
    timestamp_fn = Keyword.fetch!(opts, :timestamp_fn)
    id_fn = Keyword.fetch!(opts, :id_fn)

    case parse(cursor) do
      {:ok, {cursor_timestamp_ms, cursor_id}} ->
        Enum.filter(records, fn record ->
          record_ts_ms = DateTime.to_unix(timestamp_fn.(record), :millisecond)

          cond do
            record_ts_ms == cursor_timestamp_ms ->
              if order == :desc, do: id_fn.(record) < cursor_id, else: id_fn.(record) > cursor_id

            record_ts_ms < cursor_timestamp_ms ->
              order == :desc

            true ->
              order == :asc
          end
        end)

      :error ->
        records
    end
  end

  @doc """
  Filter records using DateTime comparison (for microsecond precision cursors).

  This variant uses DateTime.compare instead of converting to milliseconds,
  preserving full timestamp precision for stores that use microseconds.

  ## Options
  - `:timestamp_fn` - Function to extract timestamp (DateTime) from record (required)
  - `:id_fn` - Function to extract ID from record (required)
  - `:precision` - :millisecond (default) or :microsecond for cursor parsing

  ## Examples

      records = [%{timestamp: ~U[...], id: "1"}, ...]
      filtered = Cursor.filter_records_datetime(records, cursor, :desc,
        timestamp_fn: & &1.timestamp,
        id_fn: & &1.id,
        precision: :microsecond
      )
  """
  @spec filter_records_datetime(list(), String.t() | nil, :asc | :desc, keyword()) :: list()
  def filter_records_datetime(records, nil, _order, _opts), do: records

  def filter_records_datetime(records, cursor, order, opts) do
    timestamp_fn = Keyword.fetch!(opts, :timestamp_fn)
    id_fn = Keyword.fetch!(opts, :id_fn)
    precision = Keyword.get(opts, :precision, :millisecond)

    case parse_datetime(cursor, precision: precision) do
      {:ok, {cursor_timestamp, cursor_id}} ->
        Enum.filter(records, fn record ->
          record_timestamp = timestamp_fn.(record)
          record_id = id_fn.(record)

          case DateTime.compare(record_timestamp, cursor_timestamp) do
            :eq ->
              if order == :desc, do: record_id < cursor_id, else: record_id > cursor_id

            :lt ->
              order == :desc

            :gt ->
              order == :asc
          end
        end)

      :error ->
        records
    end
  end
end
