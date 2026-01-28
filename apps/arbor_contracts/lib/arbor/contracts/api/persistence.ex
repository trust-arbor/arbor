defmodule Arbor.Contracts.API.Persistence do
  @moduledoc """
  Public API contract for the Arbor.Persistence library.

  Defines the facade interface for a meta-persistence layer that delegates
  to pluggable backend modules. Every callback accepts a `store_name` (which
  identifies the backend process) and a `backend` module (which implements
  the actual storage logic).

  ## Storage Paradigms

  | Paradigm | Purpose | Required? |
  |----------|---------|-----------|
  | **Store** | Key-value put/get/delete/list/exists | Yes |
  | **QueryableStore** | Filtered queries, counts, aggregates | Optional |
  | **EventLog** | Append-only event streams | Optional |

  ## Quick Start

      # Start a backend under your supervisor
      children = [
        {Arbor.Persistence.Store.ETS, name: :my_store}
      ]

      # Use the facade
      Arbor.Persistence.put(:my_store, Arbor.Persistence.Store.ETS, "key", "value")
      Arbor.Persistence.get(:my_store, Arbor.Persistence.Store.ETS, "key")

  @version "1.0.0"
  """

  # ===========================================================================
  # Types
  # ===========================================================================

  @typedoc "Atom identifying a named backend process."
  @type store_name :: atom()

  @typedoc "Module implementing the backend storage behaviour."
  @type backend :: module()

  @typedoc "String key used to identify a stored value."
  @type key :: String.t()

  @typedoc "String identifying an event stream."
  @type stream_id :: String.t()

  @typedoc "A composable query filter struct (Arbor.Persistence.Filter)."
  @type filter :: map()

  @typedoc "A structured record returned by QueryableStore operations."
  @type record :: map()

  @typedoc "An immutable event log entry."
  @type event :: map()

  @typedoc "Name of a field to aggregate over."
  @type field_name :: atom()

  @typedoc "Aggregation operation to perform."
  @type aggregate_operation :: atom()

  @typedoc "Options keyword list passed through to backends."
  @type opts :: keyword()

  # ===========================================================================
  # Store Operations (required)
  # ===========================================================================

  @doc """
  Store a value under the given key using the specified backend.

  The backend process is identified by `store_name` and the storage
  implementation by `backend`. Returns `:ok` on success.
  """
  @callback store_value_by_key_using_backend(
              store_name(),
              backend(),
              key(),
              value :: term(),
              opts()
            ) :: :ok | {:error, term()}

  @doc """
  Retrieve a value by key using the specified backend.

  Returns `{:ok, value}` when the key exists, or `{:error, :not_found}`
  when no entry matches the given key.
  """
  @callback retrieve_value_by_key_using_backend(
              store_name(),
              backend(),
              key(),
              opts()
            ) :: {:ok, term()} | {:error, :not_found} | {:error, term()}

  @doc """
  Delete a value by key using the specified backend.

  Returns `:ok` on success, even if the key did not exist.
  """
  @callback delete_value_by_key_using_backend(
              store_name(),
              backend(),
              key(),
              opts()
            ) :: :ok | {:error, term()}

  @doc """
  List all keys in the store using the specified backend.

  Returns `{:ok, keys}` with a list of string keys currently stored.
  """
  @callback list_all_keys_using_backend(
              store_name(),
              backend(),
              opts()
            ) :: {:ok, [String.t()]} | {:error, term()}

  @doc """
  Check whether a key exists in the store using the specified backend.

  Returns `true` if the key is present, `false` otherwise.
  """
  @callback check_key_exists_using_backend(
              store_name(),
              backend(),
              key(),
              opts()
            ) :: boolean()

  # ===========================================================================
  # QueryableStore Operations (optional)
  # ===========================================================================

  @doc """
  Query records matching a filter using the specified backend.

  The filter is a composable query struct supporting conditions, time ranges,
  ordering, limit, and offset. Returns matching records.
  """
  @callback query_records_by_filter_using_backend(
              store_name(),
              backend(),
              filter(),
              opts()
            ) :: {:ok, [record()]} | {:error, term()}

  @doc """
  Count records matching a filter using the specified backend.

  Returns the number of records that satisfy the filter conditions.
  """
  @callback count_records_by_filter_using_backend(
              store_name(),
              backend(),
              filter(),
              opts()
            ) :: {:ok, non_neg_integer()} | {:error, term()}

  @doc """
  Aggregate a numeric field across records matching a filter.

  Applies the given `aggregate_operation` (e.g., `:sum`, `:avg`, `:min`,
  `:max`) to the specified `field_name` for all records matching the filter.
  Returns `nil` when no records match.
  """
  @callback aggregate_field_by_filter_using_backend(
              store_name(),
              backend(),
              filter(),
              field_name(),
              aggregate_operation(),
              opts()
            ) :: {:ok, number() | nil} | {:error, term()}

  # ===========================================================================
  # EventLog Operations (optional)
  # ===========================================================================

  @doc """
  Append one or more events to a stream using the specified backend.

  Events are immutable and ordered within their stream. Returns the
  persisted events with assigned event numbers and global positions.
  """
  @callback append_events_to_stream_using_backend(
              store_name(),
              backend(),
              stream_id(),
              events :: [event()] | event(),
              opts()
            ) :: {:ok, [event()]} | {:error, term()}

  @doc """
  Read all events from a specific stream using the specified backend.

  Returns events ordered by event number within the stream.
  """
  @callback read_events_from_stream_using_backend(
              store_name(),
              backend(),
              stream_id(),
              opts()
            ) :: {:ok, [event()]} | {:error, term()}

  @doc """
  Read all events across all streams using the specified backend.

  Returns events ordered by global position.
  """
  @callback read_all_events_using_backend(
              store_name(),
              backend(),
              opts()
            ) :: {:ok, [event()]} | {:error, term()}

  @doc """
  Check whether a stream exists using the specified backend.

  Returns `true` if the stream has at least one event, `false` otherwise.
  """
  @callback check_stream_exists_using_backend(
              store_name(),
              backend(),
              stream_id(),
              opts()
            ) :: boolean()

  @doc """
  Get the current version (latest event number) of a stream.

  Returns `{:ok, version}` where version is the event number of the
  most recent event in the stream.
  """
  @callback get_stream_version_using_backend(
              store_name(),
              backend(),
              stream_id(),
              opts()
            ) :: {:ok, non_neg_integer()} | {:error, term()}

  @doc """
  List all known stream IDs using the specified backend.

  Returns a list of stream identifiers that have at least one event.
  """
  @callback list_all_streams_using_backend(
              store_name(),
              backend(),
              opts()
            ) :: {:ok, [String.t()]}

  @doc """
  Get the number of distinct streams using the specified backend.
  """
  @callback get_stream_count_using_backend(
              store_name(),
              backend(),
              opts()
            ) :: {:ok, non_neg_integer()}

  @doc """
  Get the total number of events across all streams using the specified backend.
  """
  @callback get_event_count_using_backend(
              store_name(),
              backend(),
              opts()
            ) :: {:ok, non_neg_integer()}

  # ===========================================================================
  # Optional Callbacks
  # ===========================================================================

  @optional_callbacks [
    # QueryableStore operations
    query_records_by_filter_using_backend: 4,
    count_records_by_filter_using_backend: 4,
    aggregate_field_by_filter_using_backend: 6,
    # EventLog operations
    append_events_to_stream_using_backend: 5,
    read_events_from_stream_using_backend: 4,
    read_all_events_using_backend: 3,
    check_stream_exists_using_backend: 4,
    get_stream_version_using_backend: 4,
    list_all_streams_using_backend: 3,
    get_stream_count_using_backend: 3,
    get_event_count_using_backend: 3
  ]
end
