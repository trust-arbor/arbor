defmodule Arbor.Contracts.Persistence.Store do
  @moduledoc """
  Unified behaviour for pluggable storage backends.

  Provides basic CRUD operations that every backend must implement, plus
  optional query operations for backends that support filtering, counting,
  and aggregation.

  ## Optional compare-and-swap (CAS)

  Backends may implement linearizable `compare_and_swap/4` for recovery
  fencing and single-winner claims:

  - `compare_and_swap(key, :not_found, replacement, opts)` — insert exactly once
    only when the key is absent (or only a structured-record tombstone remains).
  - `compare_and_swap(key, {:value, expected}, replacement, opts)` — atomically
    replace only when the current logical version/value equals `expected`.

  Exactly one concurrent claimant may succeed. Losers return
  `{:error, :conflict}` — never last-write-wins. On success the backend returns
  `{:ok, stored}` with the value actually retained (including any backend-owned
  generation/revision advancement).

  ### Structured `Record` values (ABA-safe)

  For `%Arbor.Contracts.Persistence.Record{}` values, backends treat the pair
  `(generation, revision)` as the fencing token. CAS matches **both** tokens.
  Delete leaves a backend-owned generation tombstone so delete→reinsert cannot
  revive a stale expected generation+revision. Callers cannot roll either token
  backward; backends own advancement on every successful put and CAS.

  Identity rules for structured Records (all backends):

  - Logical `Record.id` is preserved separately from physical storage identity.
  - Physical identity is the store key (Postgres: true `(namespace, key)` pair —
    never a `namespace <> ":" <> key` concatenation that collides on embedded
    delimiters).
  - `Record.key` must equal the store key on put/CAS; mismatches are rejected.
  - On update of a live record, backends preserve the stored logical id and
    generation and advance revision.

  ### Ordinary unversioned values (not ABA-safe)

  For non-Record terms, `{:value, expected}` CAS uses **term equality only**.
  That is honest last-observed-value fencing: if a key is deleted and later
  reinserted with the same term, a stale CAS expecting that term may succeed.
  Callers that need delete/reinsert fencing must use structured Records (or
  embed their own incarnation token in the value).

  ## Optional durability classification

  `durability_class/1` is a code-owned backend capability (not a module-name
  heuristic or operator force flag). It returns exactly one of:

  - `:volatile` — may be lost without process death (e.g. pure in-memory buffer)
  - `:process_lifetime` — survives only while the owner process lives
  - `:application_restart` — survives process restarts within the application
  - `:node_restart` — survives full node restarts (durable storage)

  ## Implementing a Store

  Minimal (CRUD only):

      defmodule MyFileStore do
        @behaviour Arbor.Contracts.Persistence.Store

        @impl true
        def put(key, value, _opts), do: ...

        @impl true
        def get(key, _opts), do: ...

        @impl true
        def delete(key, _opts), do: ...

        @impl true
        def list(_opts), do: ...
      end

  With query support:

      defmodule MyEctoStore do
        @behaviour Arbor.Contracts.Persistence.Store

        # ... CRUD callbacks ...

        @impl true
        def query(filter, _opts), do: ...

        @impl true
        def count(filter, _opts), do: ...

        @impl true
        def aggregate(filter, field, op, _opts), do: ...
      end

  ## Usage

  Any library can accept a store backend via configuration:

      config :arbor_security, storage_backend: MyFileStore

  The same backend module can plug into security, checkpoints, memory,
  or any other system that persists data.
  """

  alias Arbor.Contracts.Persistence.Filter

  @type key :: String.t()
  @type value :: term()
  @type opts :: keyword()

  @typedoc """
  Expected state for compare-and-swap.

  - `:not_found` — key must be absent (or only a structured-record tombstone)
  - `{:value, expected}` — current value must match `expected` (for Records,
    generation **and** revision of the observed record)
  """
  @type cas_expected :: :not_found | {:value, value()}

  @typedoc """
  Backend-owned durability class. Not configurable by callers.
  """
  @type durability_class ::
          :volatile | :process_lifetime | :application_restart | :node_restart

  # --- Required: CRUD operations ---

  @doc "Store a value under the given key. Overwrites existing values."
  @callback put(key(), value(), opts()) :: :ok | {:error, term()}

  @doc "Retrieve a value by key. Returns {:ok, value} or {:error, :not_found}."
  @callback get(key(), opts()) :: {:ok, value()} | {:error, :not_found | term()}

  @doc "Delete a value by key. Returns :ok even if key doesn't exist."
  @callback delete(key(), opts()) :: :ok | {:error, term()}

  @doc "List all keys. Returns {:ok, [key]} or {:error, reason}."
  @callback list(opts()) :: {:ok, [key()]} | {:error, term()}

  # --- Optional: existence check ---

  @doc "Check if a key exists."
  @callback exists?(key(), opts()) :: boolean()

  # --- Optional: query operations ---

  @doc "Query values using a Filter. Returns matching values."
  @callback query(Filter.t(), opts()) :: {:ok, [value()]} | {:error, term()}

  @doc "Count values matching a Filter."
  @callback count(Filter.t(), opts()) :: {:ok, non_neg_integer()} | {:error, term()}

  @doc """
  Aggregate a numeric field across matching values.

  Supported operations: :sum, :avg, :min, :max
  """
  @callback aggregate(Filter.t(), atom(), atom(), opts()) ::
              {:ok, number() | nil} | {:error, term()}

  # --- Optional: linearizable CAS and durability ---

  @doc """
  Atomically compare-and-swap a key.

  See module docs for `:not_found` vs `{:value, expected}` semantics, structured
  Record generation+revision fencing, and the honest ABA limit for unversioned
  values. Returns `{:ok, stored}` on success or `{:error, :conflict}` when the
  expectation does not hold. Never last-write-wins under contention.
  """
  @callback compare_and_swap(key(), cas_expected(), value(), opts()) ::
              {:ok, value()} | {:error, :conflict | term()}

  @doc """
  Return this backend's code-owned durability class.

  Must return exactly one of `:volatile`, `:process_lifetime`,
  `:application_restart`, or `:node_restart`.
  """
  @callback durability_class(opts()) :: durability_class()

  @optional_callbacks [
    exists?: 2,
    query: 2,
    count: 2,
    aggregate: 4,
    compare_and_swap: 4,
    durability_class: 1
  ]
end
