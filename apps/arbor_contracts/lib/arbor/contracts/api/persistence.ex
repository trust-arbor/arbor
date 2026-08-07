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
  @type record_t :: map()

  @typedoc "An immutable event log entry whose data and metadata are canonical string-key JSON maps."
  @type event :: map()

  @typedoc "Stable exact-ID identity for reconciling an EventLog append."
  @type append_operation :: Arbor.Contracts.Persistence.AppendOperation.t()

  @typedoc "Closed public failures for permanent whole-stream EventLog purge."
  @type event_stream_purge_error ::
          :backend_unavailable
          | :invalid_precondition
          | :invalid_stream_id
          | :purge_not_supported
          | :purge_verification_failed

  @typedoc "Result of proving that one complete EventLog stream is absent."
  @type event_stream_purge_result ::
          :ok
          | {:error, {:purge_indeterminate, stream_id()}}
          | {:error, event_stream_purge_error()}

  @typedoc "Canonical vector mutation or bounded atomic batch."
  @type vector_operation :: Arbor.Contracts.Persistence.VectorOperation.t()

  @typedoc "Immutable vector mutation result bound to its original operation."
  @type vector_receipt :: Arbor.Contracts.Persistence.VectorReceipt.t()

  @typedoc "Validated transport-only vector row."
  @type vector_record :: Arbor.Contracts.Persistence.VectorRecord.t()

  @typedoc "Validated vector search result."
  @type vector_match :: Arbor.Contracts.Persistence.VectorMatch.t()

  @typedoc "Closed public vector-boundary failures."
  @type vector_error ::
          :backend_failure
          | :conflict
          | :indeterminate
          | :invalid_backend_result
          | :invalid_request
          | :not_found
          | :tenant_mismatch
          | :unsupported

  @typedoc "Closed content-free relationship-boundary failures."
  @type relationship_error ::
          :invalid_request
          | :invalid_options
          | :not_found
          | :validation_failed
          | :backend_failure
          | :indeterminate

  @typedoc "Bounded plain relationship record (atom keys only; no agent_id field)."
  @type relationship_record :: map()

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

  @typedoc """
  Expected state for compare-and-swap fencing.

  - `:not_found` — insert only when absent (or only a structured-record tombstone)
  - `{:value, expected}` — replace only when the current logical version/value matches
    (for Records: generation **and** revision; for plain values: term equality)
  """
  @type cas_expected :: :not_found | {:value, term()}

  @typedoc """
  Code-owned durability class reported by a backend.
  """
  @type durability_class ::
          :volatile | :process_lifetime | :application_restart | :node_restart

  @doc """
  Atomically compare-and-swap a key using the specified backend.

  Inserts when `expected` is `:not_found` and the key is absent (or only a
  structured-record tombstone remains), or replaces when `expected` is
  `{:value, current}` and the stored fencing token/value matches.

  Structured Records fence on `(generation, revision)` and survive delete/reinsert
  ABA via backend-owned generation tombstones. Ordinary unversioned values use
  term equality only and do **not** prevent delete/reinsert ABA.

  Exactly one concurrent claimant may succeed; conflicts return
  `{:error, :conflict}`. Backends without CAS return `{:error, :unsupported}`.
  """
  @callback compare_and_swap_value_using_backend(
              store_name(),
              backend(),
              key(),
              cas_expected(),
              replacement :: term(),
              opts()
            ) :: {:ok, term()} | {:error, :conflict | :unsupported | term()}

  @doc """
  Atomically delete a live key only when its current logical value/version
  matches `expected`.

  Structured Records fence on generation+revision and retain their generation
  tombstone after deletion. Ordinary values use exact term equality and retain
  the documented delete/reinsert ABA limitation. Unsupported backends return
  `{:error, :unsupported}`.
  """
  @callback compare_and_delete_value_using_backend(
              store_name(),
              backend(),
              key(),
              expected :: term(),
              opts()
            ) :: :ok | {:error, :conflict | :unsupported | term()}

  @doc """
  Report the backend's code-owned durability class.

  Returns `{:ok, class}` for backends that implement durability classification,
  or `{:error, :unsupported}` when the backend does not expose it.
  """
  @callback report_backend_durability_class(
              store_name(),
              backend(),
              opts()
            ) :: {:ok, durability_class()} | {:error, :unsupported}

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
            ) :: {:ok, [record_t()]} | {:error, term()}

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

  Events are immutable and ordered within their stream. Event types are bounded
  domain strings, not Elixir module names. Returns the persisted events with
  assigned event numbers and global positions; data and metadata use canonical
  string-key JSON maps consistently for append, retry, reconciliation, and read.
  """
  @callback append_events_to_stream_using_backend(
              store_name(),
              backend(),
              stream_id(),
              events :: [event()] | event(),
              opts()
            ) :: {:ok, [event()]} | {:error, term()}

  @doc """
  Reconcile an indeterminate append using its exact submitted event identity.

  A committed result includes the exact persisted events in submission order;
  `:absent` proves no submitted event committed. Backends fail closed when only a
  partial or unavailable observation is possible.
  """
  @callback reconcile_event_append_using_backend(
              store_name(),
              backend(),
              append_operation(),
              opts()
            ) ::
              {:ok, {:committed, [event()]}}
              | {:ok, :absent}
              | {:error, :event_identity_conflict | term()}

  @doc """
  Permanently purge one complete event stream using the specified backend.

  Success proves that every backend-owned event, version, identity, and
  operation-fence surface for the stream is absent. An indeterminate result
  means dispatch occurred but absence could not be proved; retrying the same
  stream is idempotent.
  """
  @callback purge_complete_event_stream_using_backend(
              store_name(),
              backend(),
              stream_id(),
              opts()
            ) :: event_stream_purge_result()

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
  Read at most the current head event from a stream using the specified backend.

  Backends may accept a bounded freshness requirement through `opts`. Returns
  `{:ok, nil}` when the stream is empty or its head does not satisfy that
  requirement. A metadata-only cache that knows the stream is nonempty must
  return an unavailable error or fall through to durable storage; it must not
  report the stream as empty.
  """
  @callback read_current_stream_head_using_backend(
              store_name(),
              backend(),
              stream_id(),
              opts()
            ) :: {:ok, event() | nil} | {:error, term()}

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
  # VectorStore Operations (optional)
  # ===========================================================================

  @doc "Execute a canonical vector operation only for its bound tenant."
  @callback execute_validated_vector_operation_for_agent(
              agent_id :: String.t(),
              vector_operation(),
              opts()
            ) :: {:ok, vector_receipt()} | {:error, vector_error()}

  @doc "Reconcile using the original canonical operation, not a fingerprint alone."
  @callback reconcile_validated_vector_operation_for_agent(
              agent_id :: String.t(),
              vector_operation(),
              opts()
            ) ::
              {:ok, vector_receipt()} | {:ok, :absent} | {:error, vector_error()}

  @doc "Retrieve one validated row by its exact tenant-owned logical identity."
  @callback retrieve_vector_record_by_logical_identity_for_agent(
              agent_id :: String.t(),
              source_namespace :: String.t(),
              source_key :: String.t(),
              opts()
            ) :: {:ok, vector_record()} | {:error, vector_error()}

  @doc "List a bounded, fully validated set of rows owned by one tenant."
  @callback list_vector_records_for_agent(agent_id :: String.t(), opts()) ::
              {:ok, [vector_record()]} | {:error, vector_error()}

  @doc "Search with an exact model/dimension/encoding/category descriptor."
  @callback search_vector_records_by_exact_descriptor_for_agent(
              agent_id :: String.t(),
              normalized_vector :: [float()],
              opts()
            ) :: {:ok, [vector_match()]} | {:error, vector_error()}

  @doc "Search with an exact model descriptor and optional category, namespace, and threshold scopes."
  @callback search_vector_records_by_exact_model_descriptor_and_scope_for_agent(
              agent_id :: String.t(),
              normalized_vector :: [float()],
              opts()
            ) :: {:ok, [vector_match()]} | {:error, vector_error()}

  # ===========================================================================
  # Relationship operations (optional)
  # ===========================================================================

  @doc "Upsert one tenant-scoped relationship record by {agent_id, name}."
  @callback upsert_tenant_relationship_record_for_agent(
              agent_id :: String.t(),
              relationship_record()
            ) :: {:ok, relationship_record()} | {:error, relationship_error()}

  @doc "Retrieve one tenant-scoped relationship by durable row id."
  @callback retrieve_tenant_relationship_record_by_id_for_agent(
              agent_id :: String.t(),
              relationship_id :: String.t(),
              opts()
            ) :: {:ok, relationship_record()} | {:error, relationship_error()}

  @doc "Retrieve one tenant-scoped relationship by exact name."
  @callback retrieve_tenant_relationship_record_by_name_for_agent(
              agent_id :: String.t(),
              name :: String.t(),
              opts()
            ) :: {:ok, relationship_record()} | {:error, relationship_error()}

  @doc "List a bounded page of tenant-owned relationship records."
  @callback list_tenant_relationship_records_for_agent(agent_id :: String.t(), opts()) ::
              {:ok, [relationship_record()]} | {:error, relationship_error()}

  @doc "Update fields on one tenant-scoped relationship by durable row id."
  @callback update_tenant_relationship_record_for_agent(
              agent_id :: String.t(),
              relationship_id :: String.t(),
              changes :: map(),
              opts()
            ) :: {:ok, relationship_record()} | {:error, relationship_error()}

  @doc "Delete one tenant-scoped relationship by durable row id."
  @callback delete_tenant_relationship_record_for_agent(
              agent_id :: String.t(),
              relationship_id :: String.t(),
              opts()
            ) :: :ok | {:error, relationship_error()}

  @doc "Atomically touch access tracking for one tenant-scoped relationship."
  @callback touch_tenant_relationship_record_for_agent(
              agent_id :: String.t(),
              relationship_id :: String.t(),
              opts()
            ) :: {:ok, relationship_record()} | {:error, relationship_error()}

  @doc "Count tenant-owned relationship rows."
  @callback count_tenant_relationship_records_for_agent(agent_id :: String.t(), opts()) ::
              {:ok, non_neg_integer()} | {:error, relationship_error()}

  @doc "Retrieve the highest-salience relationship for one tenant."
  @callback retrieve_primary_tenant_relationship_record_for_agent(
              agent_id :: String.t(),
              opts()
            ) :: {:ok, relationship_record()} | {:error, relationship_error()}

  @doc """
  Idempotently delete every relationship row for exactly one agent and verify
  zero remaining rows in the same database transaction.
  """
  @callback delete_all_tenant_relationship_records_for_agent(agent_id :: String.t(), opts()) ::
              :ok | {:error, relationship_error()}

  @doc "Exact standalone absence check for an agent's relationship rows."
  @callback check_tenant_relationship_records_absent_for_agent(agent_id :: String.t(), opts()) ::
              {:ok, true} | {:ok, false} | {:error, relationship_error()}

  # ===========================================================================
  # Optional Callbacks
  # ===========================================================================

  @optional_callbacks [
    # CAS / durability (optional — third-party backends need not implement)
    compare_and_swap_value_using_backend: 6,
    compare_and_delete_value_using_backend: 5,
    report_backend_durability_class: 3,
    # QueryableStore operations
    query_records_by_filter_using_backend: 4,
    count_records_by_filter_using_backend: 4,
    aggregate_field_by_filter_using_backend: 6,
    # EventLog operations
    append_events_to_stream_using_backend: 5,
    reconcile_event_append_using_backend: 4,
    purge_complete_event_stream_using_backend: 4,
    read_events_from_stream_using_backend: 4,
    read_current_stream_head_using_backend: 4,
    read_all_events_using_backend: 3,
    check_stream_exists_using_backend: 4,
    get_stream_version_using_backend: 4,
    list_all_streams_using_backend: 3,
    get_stream_count_using_backend: 3,
    get_event_count_using_backend: 3,
    # VectorStore operations
    execute_validated_vector_operation_for_agent: 3,
    reconcile_validated_vector_operation_for_agent: 3,
    retrieve_vector_record_by_logical_identity_for_agent: 4,
    list_vector_records_for_agent: 2,
    search_vector_records_by_exact_descriptor_for_agent: 3,
    search_vector_records_by_exact_model_descriptor_and_scope_for_agent: 3,
    # Relationship operations
    upsert_tenant_relationship_record_for_agent: 2,
    retrieve_tenant_relationship_record_by_id_for_agent: 3,
    retrieve_tenant_relationship_record_by_name_for_agent: 3,
    list_tenant_relationship_records_for_agent: 2,
    update_tenant_relationship_record_for_agent: 4,
    delete_tenant_relationship_record_for_agent: 3,
    touch_tenant_relationship_record_for_agent: 3,
    count_tenant_relationship_records_for_agent: 2,
    retrieve_primary_tenant_relationship_record_for_agent: 2,
    delete_all_tenant_relationship_records_for_agent: 2,
    check_tenant_relationship_records_absent_for_agent: 2
  ]
end
