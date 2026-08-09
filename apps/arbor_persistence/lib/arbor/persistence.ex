defmodule Arbor.Persistence do
  @moduledoc """
  Public API facade for Arbor.Persistence.

  Provides a unified interface for persistence operations, delegating
  to configured backend modules. All functions accept a backend module
  and pass options through.

  ## Usage

      # Start a backend under your supervisor
      children = [
        {Arbor.Persistence.Store.ETS, name: :my_store}
      ]

      # Use the facade
      Arbor.Persistence.put(:my_store, Arbor.Persistence.Store.ETS, "key", "value")
      Arbor.Persistence.get(:my_store, Arbor.Persistence.Store.ETS, "key")

  Or use backend modules directly:

      Arbor.Persistence.Store.ETS.put("key", "value", name: :my_store)
  """

  @behaviour Arbor.Contracts.API.Persistence

  alias Arbor.Contracts.Persistence.{AppendOperation, Filter, Record}

  alias Arbor.Persistence.{
    BufferedStore,
    Event,
    EventLog,
    LegacyEmbeddingStore,
    RelationshipStore,
    VectorBoundary
  }

  alias Arbor.Persistence.EventLog.BoundedWorker
  alias Arbor.Persistence.Repo
  alias Arbor.Persistence.Schemas.Session
  alias Arbor.Persistence.SessionStore

  # ---------------------------------------------------------------
  # Validated vector-store boundary (C3G1A0)
  # ---------------------------------------------------------------

  @doc "Execute one canonical vector mutation or bounded atomic batch."
  @spec execute_vector_operation(String.t(), term(), keyword()) ::
          {:ok, Arbor.Contracts.Persistence.VectorReceipt.t()}
          | {:error, Arbor.Contracts.API.Persistence.vector_error()}
  def execute_vector_operation(agent_id, operation, opts \\ []),
    do: VectorBoundary.execute(agent_id, operation, opts)

  @doc "Reconcile an indeterminate mutation using its original canonical operation."
  @spec reconcile_vector_operation(String.t(), term(), keyword()) ::
          {:ok, Arbor.Contracts.Persistence.VectorReceipt.t()}
          | {:ok, :absent}
          | {:error, Arbor.Contracts.API.Persistence.vector_error()}
  def reconcile_vector_operation(agent_id, operation, opts \\ []),
    do: VectorBoundary.reconcile(agent_id, operation, opts)

  @doc "Fetch one row by exact `{agent_id, source_namespace, source_key}` identity."
  @spec fetch_vector_record(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, Arbor.Contracts.Persistence.VectorRecord.t()}
          | {:error, Arbor.Contracts.API.Persistence.vector_error()}
  def fetch_vector_record(agent_id, source_namespace, source_key, opts \\ []),
    do: VectorBoundary.fetch(agent_id, source_namespace, source_key, opts)

  @doc "List a bounded, fully validated tenant-owned vector-record set."
  @spec list_vector_records(String.t(), keyword()) ::
          {:ok, [Arbor.Contracts.Persistence.VectorRecord.t()]}
          | {:error, Arbor.Contracts.API.Persistence.vector_error()}
  def list_vector_records(agent_id, opts \\ []), do: VectorBoundary.list(agent_id, opts)

  @doc """
  Search using a normalized 768-dimensional vector and exact model descriptor.

  Requires `:model_id`, `:dimensions`, and `:encoding`. Optionally accepts
  independent `:category`, `:source_namespace`, and cosine-similarity
  `:threshold` scopes. Default limit is 20; maximum admitted limit is 1000.
  """
  @spec search_vector_records(String.t(), term(), keyword()) ::
          {:ok, [Arbor.Contracts.Persistence.VectorMatch.t()]}
          | {:error, Arbor.Contracts.API.Persistence.vector_error()}
  def search_vector_records(agent_id, vector, opts \\ []),
    do: VectorBoundary.search(agent_id, vector, opts)

  @doc """
  Idempotently destroy exact-agent strict V1 vector rows and operation receipts,
  then close the durable agent fence.
  """
  @spec destroy_vector_agent(String.t(), keyword()) ::
          :ok | {:error, Arbor.Contracts.API.Persistence.vector_error()}
  def destroy_vector_agent(agent_id, opts \\ []),
    do: VectorBoundary.destroy(agent_id, opts)

  # ---------------------------------------------------------------
  # Relationship records (VP-05D2C3I0A)
  #
  # Closed plain-map boundary. agent_id is source-owned from the function
  # argument and cannot be overridden by input data. No schema/Repo/Ecto
  # values cross this facade.
  # ---------------------------------------------------------------

  @doc "Upsert one tenant-scoped relationship record by `{agent_id, name}`."
  @spec put_relationship(String.t(), map()) ::
          {:ok, map()} | {:error, Arbor.Contracts.API.Persistence.relationship_error()}
  def put_relationship(agent_id, attrs), do: RelationshipStore.put(agent_id, attrs)

  @doc "Fetch one tenant-scoped relationship by durable row id."
  @spec fetch_relationship(String.t(), String.t()) ::
          {:ok, map()} | {:error, Arbor.Contracts.API.Persistence.relationship_error()}
  def fetch_relationship(agent_id, relationship_id),
    do: RelationshipStore.fetch(agent_id, relationship_id)

  @doc "Fetch one tenant-scoped relationship by exact name."
  @spec fetch_relationship_by_name(String.t(), String.t()) ::
          {:ok, map()} | {:error, Arbor.Contracts.API.Persistence.relationship_error()}
  def fetch_relationship_by_name(agent_id, name),
    do: RelationshipStore.fetch_by_name(agent_id, name)

  @doc """
  List a bounded page of tenant-owned relationships.

  Options (closed allowlist): `:sort_by`, `:sort_dir`, `:limit`.
  Default limit is 100; maximum is 1000. Absent limit is never unbounded.
  """
  @spec list_relationships(String.t(), keyword()) ::
          {:ok, [map()]} | {:error, Arbor.Contracts.API.Persistence.relationship_error()}
  def list_relationships(agent_id, opts \\ []),
    do: RelationshipStore.list(agent_id, opts)

  @doc "Update fields on one tenant-scoped relationship by durable row id."
  @spec update_relationship(String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, Arbor.Contracts.API.Persistence.relationship_error()}
  def update_relationship(agent_id, relationship_id, changes),
    do: RelationshipStore.update(agent_id, relationship_id, changes)

  @doc "Delete one tenant-scoped relationship by durable row id."
  @spec delete_relationship(String.t(), String.t()) ::
          :ok | {:error, Arbor.Contracts.API.Persistence.relationship_error()}
  def delete_relationship(agent_id, relationship_id),
    do: RelationshipStore.delete(agent_id, relationship_id)

  @doc "Atomically touch access tracking for one tenant-scoped relationship."
  @spec touch_relationship(String.t(), String.t()) ::
          {:ok, map()} | {:error, Arbor.Contracts.API.Persistence.relationship_error()}
  def touch_relationship(agent_id, relationship_id),
    do: RelationshipStore.touch(agent_id, relationship_id)

  @doc "Count tenant-owned relationship rows."
  @spec count_relationships(String.t()) ::
          {:ok, non_neg_integer()}
          | {:error, Arbor.Contracts.API.Persistence.relationship_error()}
  def count_relationships(agent_id), do: RelationshipStore.count(agent_id)

  @doc "Fetch the highest-salience relationship for one tenant."
  @spec fetch_primary_relationship(String.t()) ::
          {:ok, map()} | {:error, Arbor.Contracts.API.Persistence.relationship_error()}
  def fetch_primary_relationship(agent_id), do: RelationshipStore.fetch_primary(agent_id)

  @doc """
  Idempotently delete every relationship row for exactly one agent and verify
  zero remaining rows in the same database transaction.

  Content-only: does not touch provenance, identity, vectors, or other domains.
  """
  @spec delete_all_relationships(String.t()) ::
          :ok | {:error, Arbor.Contracts.API.Persistence.relationship_error()}
  def delete_all_relationships(agent_id), do: RelationshipStore.delete_all(agent_id)

  @doc "Exact standalone absence check for an agent's relationship rows."
  @spec relationships_absent?(String.t()) ::
          {:ok, true}
          | {:ok, false}
          | {:error, Arbor.Contracts.API.Persistence.relationship_error()}
  def relationships_absent?(agent_id), do: RelationshipStore.absent?(agent_id)

  # ---------------------------------------------------------------
  # Legacy memory embeddings
  # ---------------------------------------------------------------

  @doc "Validate and normalize one legacy embedding before any durable dispatch."
  @spec validate_legacy_embedding(String.t(), String.t(), term(), term()) ::
          {:ok, [float()]} | {:error, {:invalid_legacy_embedding, atom()}}
  def validate_legacy_embedding(agent_id, content, embedding, metadata),
    do: LegacyEmbeddingStore.validate(agent_id, content, embedding, metadata)

  @doc "Store or deduplicate one legacy memory embedding."
  def store_legacy_embedding(agent_id, content, embedding, metadata \\ %{}, opts \\ []),
    do: LegacyEmbeddingStore.store(agent_id, content, embedding, metadata, opts)

  @doc "Search tenant-owned legacy memory embeddings by cosine similarity."
  def search_legacy_embeddings(agent_id, query_embedding, opts \\ []),
    do: LegacyEmbeddingStore.search(agent_id, query_embedding, opts)

  @doc "Delete one tenant-owned legacy memory embedding by durable row ID."
  def delete_legacy_embedding(agent_id, embedding_id),
    do: LegacyEmbeddingStore.delete(agent_id, embedding_id)

  @doc "Count tenant-owned legacy memory embeddings."
  def count_legacy_embeddings(agent_id, opts \\ []),
    do: LegacyEmbeddingStore.count(agent_id, opts)

  @doc "Return aggregate statistics for tenant-owned legacy memory embeddings."
  def legacy_embedding_stats(agent_id), do: LegacyEmbeddingStore.stats(agent_id)

  @doc "Store or deduplicate a batch of tenant-owned legacy memory embeddings."
  def store_legacy_embedding_batch(agent_id, entries),
    do: LegacyEmbeddingStore.store_batch(agent_id, entries)

  @doc "Store a legacy embedding batch and return authoritative IDs in input order."
  def store_legacy_embedding_batch_with_ids(agent_id, entries, opts \\ []),
    do: LegacyEmbeddingStore.store_batch_with_ids(agent_id, entries, opts)

  @doc "Fetch one tenant-owned legacy memory embedding by durable row ID."
  def fetch_legacy_embedding(agent_id, embedding_id, opts \\ []),
    do: LegacyEmbeddingStore.get(agent_id, embedding_id, opts)

  @doc "Delete all tenant-owned legacy memory embeddings."
  def delete_all_legacy_embeddings(agent_id, opts \\ []),
    do: LegacyEmbeddingStore.delete_all(agent_id, opts)

  @doc """
  Idempotently destroy exact-agent legacy embedding rows and confirm zero remain.

  Uses the established legacy-row predicate and exact agent equality. Does not
  touch strict V1 vector rows, receipts, or the durable destroy fence.
  """
  @spec destroy_legacy_embeddings(String.t(), keyword()) ::
          :ok | {:error, LegacyEmbeddingStore.legacy_cleanup_error()}
  def destroy_legacy_embeddings(agent_id, opts \\ []),
    do: LegacyEmbeddingStore.destroy_legacy_embeddings(agent_id, opts)

  @doc "Authoritative absence check for exact-agent legacy embedding rows."
  @spec legacy_embeddings_absent?(String.t(), keyword()) ::
          {:ok, true}
          | {:ok, false}
          | {:error, LegacyEmbeddingStore.legacy_cleanup_error()}
  def legacy_embeddings_absent?(agent_id, opts \\ []),
    do: LegacyEmbeddingStore.legacy_embeddings_absent?(agent_id, opts)

  # ---------------------------------------------------------------
  # Session transcript facade (VP-04A)
  #
  # Narrow delegates onto Arbor.Persistence.SessionStore — the canonical public
  # path for a transport (dashboard, voice) to resolve/append/load an agent's
  # session transcript without importing SessionStore or its Ecto schemas
  # directly. Opts are validated as closed-allowlist keyword lists: an unknown
  # or duplicate key is rejected outright, never silently dropped.
  # ---------------------------------------------------------------

  @ensure_session_opts_allowlist [:model, :cwd, :git_branch, :metadata]
  @load_recent_opts_allowlist [:limit, :before_timestamp, :engagement_id]
  @load_limit_max 1000
  @engagement_id_max_bytes 256

  @doc """
  Return the existing session for `session_id`, or create it for `agent_id`.

  See `Arbor.Persistence.SessionStore.ensure_session/3` for the concurrency and
  ownership semantics. `opts` accepts only `:model`, `:cwd`, `:git_branch`, and
  `:metadata` (forwarded to session creation); any other key is rejected.
  """
  @spec ensure_session(String.t(), String.t(), keyword()) ::
          {:ok, Session.t()} | {:error, term()}
  def ensure_session(session_id, agent_id, opts \\ []) do
    with :ok <- validate_opts(opts, @ensure_session_opts_allowlist) do
      SessionStore.ensure_session(session_id, agent_id, opts)
    end
  end

  @doc "Atomically bulk-append session entries. Delegates to SessionStore.append_entries/2."
  @spec append_session_entries(Ecto.UUID.t(), [map()]) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def append_session_entries(session_uuid, entries) do
    SessionStore.append_entries(session_uuid, entries)
  end

  @doc """
  Load recent display-ready session messages, optionally filtered to one
  engagement. `opts` accepts only `:limit` (a positive integer, capped at
  `#{@load_limit_max}`), `:before_timestamp` (a `DateTime` or absent), and
  `:engagement_id` (a nonblank, valid-UTF8 string within
  `#{@engagement_id_max_bytes}` bytes); any other key, or a present key holding
  a value outside those bounds, is rejected.
  """
  @spec load_recent_session_messages(String.t(), keyword()) :: [map()] | {:error, term()}
  def load_recent_session_messages(session_id, opts \\ []) do
    with :ok <- validate_opts(opts, @load_recent_opts_allowlist),
         :ok <- validate_load_opt_values(opts) do
      SessionStore.load_recent_for_display(session_id, opts)
    end
  end

  # ---------------------------------------------------------------
  # Authorized API (for agent callers)
  # ---------------------------------------------------------------

  @doc """
  Store a value with authorization check.

  Verifies the agent has the `arbor://persistence/write/{store}` capability
  before storing. Use this for agent-initiated writes where authorization
  should be enforced.

  ## Parameters

  - `agent_id` - The agent's ID for capability lookup
  - `name` - The store name
  - `backend` - The backend module
  - `key` - The key to store under
  - `value` - The value to store
  - `opts` - Options passed to `put/5`, plus optional `:trace_id` for correlation

  ## Returns

  - `:ok` on success
  - `{:error, {:unauthorized, reason}}` if agent lacks the required capability
  - `{:ok, :pending_approval, proposal_id}` if escalation needed
  - `{:error, reason}` on other errors
  """
  @spec authorize_write(String.t(), atom(), module(), String.t(), term(), keyword()) ::
          :ok
          | {:ok, :pending_approval, String.t()}
          | {:error, {:unauthorized, term()} | term()}
  def authorize_write(agent_id, name, backend, key, value, opts \\ []) do
    with {:ok, opts} <- normalize_authorization_opts(opts),
         :ok <- validate_store_name(name) do
      resource = "arbor://persistence/write/#{name}"
      {trace_id, opts} = Keyword.pop(opts, :trace_id)

      case Arbor.Security.authorize(agent_id, resource, :write, trace_id: trace_id) do
        {:ok, :authorized} -> put(name, backend, key, value, opts)
        {:ok, :pending_approval, proposal_id} -> {:ok, :pending_approval, proposal_id}
        {:error, reason} -> {:error, {:unauthorized, reason}}
      end
    end
  end

  @doc """
  Retrieve a value with authorization check.

  Verifies the agent has the `arbor://persistence/read/{store}` capability
  before reading. Use this for agent-initiated reads where authorization
  should be enforced.

  ## Parameters

  - `agent_id` - The agent's ID for capability lookup
  - `name` - The store name
  - `backend` - The backend module
  - `key` - The key to read
  - `opts` - Options passed to `get/4`, plus optional `:trace_id` for correlation

  ## Returns

  - `{:ok, value}` on success
  - `{:error, {:unauthorized, reason}}` if agent lacks the required capability
  - `{:ok, :pending_approval, proposal_id}` if escalation needed
  - `{:error, :not_found}` if key doesn't exist
  - `{:error, reason}` on other errors
  """
  @spec authorize_read(String.t(), atom(), module(), String.t(), keyword()) ::
          {:ok, term()}
          | {:ok, :pending_approval, String.t()}
          | {:error, {:unauthorized, term()} | :not_found | term()}
  def authorize_read(agent_id, name, backend, key, opts \\ []) do
    with {:ok, opts} <- normalize_authorization_opts(opts),
         :ok <- validate_store_name(name) do
      resource = "arbor://persistence/read/#{name}"
      {trace_id, opts} = Keyword.pop(opts, :trace_id)

      case Arbor.Security.authorize(agent_id, resource, :read, trace_id: trace_id) do
        {:ok, :authorized} -> get(name, backend, key, opts)
        {:ok, :pending_approval, proposal_id} -> {:ok, :pending_approval, proposal_id}
        {:error, reason} -> {:error, {:unauthorized, reason}}
      end
    end
  end

  @doc """
  Append events to a stream with authorization check.

  Verifies the agent has the `arbor://persistence/write/{store}` capability
  before appending. Use this for agent-initiated event writes.

  ## Parameters

  - `agent_id` - The agent's ID for capability lookup
  - `name` - The store name
  - `backend` - The backend module
  - `stream_id` - The stream to append to
  - `events` - Event(s) to append
  - `opts` - Options passed to `append/5`, plus optional `:trace_id` for correlation

  ## Returns

  - `{:ok, events}` on success
  - `{:error, {:unauthorized, reason}}` if agent lacks the required capability
  - `{:ok, :pending_approval, proposal_id}` if escalation needed
  - `{:error, reason}` on other errors
  """
  @spec authorize_append(
          String.t(),
          atom(),
          module(),
          String.t(),
          [Event.t()] | Event.t(),
          keyword()
        ) ::
          {:ok, [Event.t()]}
          | {:ok, :pending_approval, String.t()}
          | {:error, {:unauthorized, term()} | term()}
  def authorize_append(agent_id, name, backend, stream_id, events, opts \\ []) do
    result =
      EventLog.with_operation_deadline(opts, fn normalized_opts, _deadline_mono ->
        with :ok <- validate_store_name(name) do
          resource = "arbor://persistence/write/#{name}"
          {trace_id, append_opts} = Keyword.pop(normalized_opts, :trace_id)

          case Arbor.Security.authorize(agent_id, resource, :write, trace_id: trace_id) do
            {:ok, :authorized} -> append(name, backend, stream_id, events, append_opts)
            {:ok, :pending_approval, proposal_id} -> {:ok, :pending_approval, proposal_id}
            {:error, reason} -> {:error, {:unauthorized, reason}}
          end
        end
      end)

    case result do
      {:error, :invalid_precondition} -> {:error, :invalid_options}
      other -> other
    end
  end

  @doc """
  Read events from a stream with authorization check.

  Verifies the agent has the `arbor://persistence/read/{store}` capability
  before reading. Use this for agent-initiated stream reads.

  ## Parameters

  - `agent_id` - The agent's ID for capability lookup
  - `name` - The store name
  - `backend` - The backend module
  - `stream_id` - The stream to read from
  - `opts` - Options passed to `read_stream/4`, plus optional `:trace_id` for correlation

  ## Returns

  - `{:ok, events}` on success
  - `{:error, {:unauthorized, reason}}` if agent lacks the required capability
  - `{:ok, :pending_approval, proposal_id}` if escalation needed
  - `{:error, reason}` on other errors
  """
  @spec authorize_read_stream(String.t(), atom(), module(), String.t(), keyword()) ::
          {:ok, [Event.t()]}
          | {:ok, :pending_approval, String.t()}
          | {:error, {:unauthorized, term()} | term()}
  def authorize_read_stream(agent_id, name, backend, stream_id, opts \\ []) do
    with {:ok, opts} <- normalize_authorization_opts(opts),
         :ok <- validate_store_name(name) do
      resource = "arbor://persistence/read/#{name}"
      {trace_id, opts} = Keyword.pop(opts, :trace_id)

      case Arbor.Security.authorize(agent_id, resource, :read, trace_id: trace_id) do
        {:ok, :authorized} -> read_stream(name, backend, stream_id, opts)
        {:ok, :pending_approval, proposal_id} -> {:ok, :pending_approval, proposal_id}
        {:error, reason} -> {:error, {:unauthorized, reason}}
      end
    end
  end

  # ---------------------------------------------------------------
  # Eval operations (low-level Postgres)
  # ---------------------------------------------------------------

  alias Arbor.Persistence.Eval.{FileStore, RunIdentity, Store}
  alias Arbor.Persistence.Schemas.{EvalResult, EvalRun}

  @doc "Insert a new eval run (Postgres only)."
  @spec insert_eval_run(map()) :: {:ok, EvalRun.t()} | {:error, Ecto.Changeset.t()}
  def insert_eval_run(attrs) do
    %EvalRun{}
    |> EvalRun.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Update an existing eval run (Postgres only)."
  @spec update_eval_run(String.t(), map()) ::
          {:ok, EvalRun.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def update_eval_run(run_id, attrs) do
    case Repo.get(EvalRun, run_id) do
      nil -> {:error, :not_found}
      run -> run |> EvalRun.changeset(attrs) |> Repo.update()
    end
  end

  @doc "Insert a single eval result (Postgres only)."
  @spec insert_eval_result(map()) :: {:ok, EvalResult.t()} | {:error, Ecto.Changeset.t()}
  def insert_eval_result(attrs) do
    %EvalResult{}
    |> EvalResult.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Batch insert eval results. Returns {count, nil}."
  @spec insert_eval_results_batch([map()]) :: {non_neg_integer(), nil}
  def insert_eval_results_batch(results_attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    entries =
      Enum.map(results_attrs, fn attrs ->
        Map.put_new(attrs, :inserted_at, now)
      end)

    Repo.insert_all(EvalResult, entries, on_conflict: :nothing)
  end

  @doc "List eval runs with optional filters: domain, model, provider, status (Postgres only)."
  @spec list_eval_runs(keyword()) :: {:ok, [EvalRun.t()]}
  def list_eval_runs(filters \\ []) do
    import Ecto.Query

    query = from(r in EvalRun, order_by: [desc: r.inserted_at])
    query = eval_apply_filters(query, filters)
    {:ok, Repo.all(query)}
  end

  @doc "Get a single eval run with preloaded results (Postgres only)."
  @spec get_eval_run(String.t()) :: {:ok, EvalRun.t()} | {:error, :not_found}
  def get_eval_run(run_id) do
    import Ecto.Query

    case Repo.one(from(r in EvalRun, where: r.id == ^run_id, preload: [:results])) do
      nil -> {:error, :not_found}
      run -> {:ok, run}
    end
  end

  @doc "Compare eval runs for models in a given domain (Postgres only)."
  @spec eval_model_comparison(String.t(), [String.t()]) :: {:ok, [EvalRun.t()]}
  def eval_model_comparison(domain, models) do
    import Ecto.Query

    query =
      from(r in EvalRun,
        where: r.domain == ^domain and r.model in ^models and r.status == "completed",
        order_by: [asc: r.model, desc: r.inserted_at]
      )

    {:ok, Repo.all(query)}
  end

  # ---------------------------------------------------------------
  # Eval operations (high-level: backend selection + file fallback)
  # ---------------------------------------------------------------
  #
  # Opts:
  #   :backend  - :auto (default) | :database | :file
  #   :dir      - file-store directory (default: ".arbor/eval_runs")
  #
  # Do not pass executable modules/MFAs; backend selection is atom-only.

  @doc "True when the eval Postgres Repo process is running."
  @spec eval_database_available?() :: boolean()
  def eval_database_available?, do: Store.database_available?()

  @doc "Generate a unique eval run ID from model + domain."
  @spec generate_eval_run_id(String.t(), String.t()) :: String.t()
  def generate_eval_run_id(model, domain), do: Store.generate_run_id(model, domain)

  @doc """
  Create an eval run, capturing run-identity fields.

  Backend selection via opts (`:backend`, `:dir`). Defaults to `:auto`
  (Postgres when available, JSON file fallback otherwise).
  """
  @spec create_eval_run(map(), keyword()) :: {:ok, map() | EvalRun.t()} | {:error, term()}
  def create_eval_run(attrs, opts \\ []), do: Store.create_run(attrs, opts)

  @doc """
  High-level update of an eval run with backend selection.

  Arity-2 is the low-level Postgres update; arity-3 selects backend via opts.
  """
  @spec update_eval_run(String.t(), map(), keyword()) ::
          :ok | {:ok, EvalRun.t()} | {:error, term()}
  def update_eval_run(run_id, attrs, opts), do: Store.update_run(run_id, attrs, opts)

  @doc "Save a single eval result with backend selection."
  @spec save_eval_result(map(), keyword()) :: :ok | {:ok, EvalResult.t()} | {:error, term()}
  def save_eval_result(attrs, opts \\ []), do: Store.save_result(attrs, opts)

  @doc "Batch-save eval results with backend selection."
  @spec save_eval_results_batch([map()], keyword()) ::
          :ok | {non_neg_integer(), nil} | {:error, term()}
  def save_eval_results_batch(results, opts \\ []), do: Store.save_results_batch(results, opts)

  @doc "Mark an eval run completed with final metrics."
  @spec complete_eval_run(
          String.t(),
          map(),
          non_neg_integer(),
          non_neg_integer(),
          keyword()
        ) :: :ok | {:ok, EvalRun.t()} | {:error, term()}
  def complete_eval_run(run_id, metrics, sample_count, duration_ms, opts \\ []) do
    Store.complete_run(run_id, metrics, sample_count, duration_ms, opts)
  end

  @doc "Mark an eval run failed."
  @spec fail_eval_run(String.t(), term(), keyword()) ::
          :ok | {:ok, EvalRun.t()} | {:error, term()}
  def fail_eval_run(run_id, error, opts \\ []), do: Store.fail_run(run_id, error, opts)

  @doc """
  High-level list of eval runs with backend selection.

  Arity-1 is the low-level Postgres list; arity-2 selects backend via opts.
  """
  @spec list_eval_runs(keyword(), keyword()) :: {:ok, [map() | EvalRun.t()]} | {:error, term()}
  def list_eval_runs(filters, opts), do: Store.list_runs(filters, opts)

  @doc """
  High-level get of an eval run with backend selection.

  Arity-1 is the low-level Postgres get; arity-2 selects backend via opts.
  """
  @spec get_eval_run(String.t(), keyword()) ::
          {:ok, map() | EvalRun.t()} | {:error, term()}
  def get_eval_run(run_id, opts), do: Store.get_run(run_id, opts)

  @doc """
  High-level model comparison with backend selection.

  Arity-2 is the low-level Postgres comparison; arity-3 selects backend via opts.
  """
  @spec eval_model_comparison(String.t(), [String.t()], keyword()) ::
          {:ok, [map() | EvalRun.t()]} | {:error, term()}
  def eval_model_comparison(domain, models, opts),
    do: Store.compare_models(domain, models, opts)

  # --- File-store surface ---

  @doc "Save an eval run to the JSON file store."
  @spec save_eval_run_file(String.t(), map(), keyword()) :: :ok | {:error, term()}
  def save_eval_run_file(run_id, run_data, opts \\ []),
    do: FileStore.save_run(run_id, run_data, opts)

  @doc "Load an eval run from the JSON file store."
  @spec load_eval_run_file(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def load_eval_run_file(run_id, opts \\ []), do: FileStore.load_run(run_id, opts)

  @doc "List eval runs from the JSON file store."
  @spec list_eval_run_files(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_eval_run_files(opts \\ []), do: FileStore.list_runs(opts)

  @doc "Latest eval run from the JSON file store."
  @spec latest_eval_run_file(keyword()) :: {:ok, map()} | {:error, :no_runs}
  def latest_eval_run_file(opts \\ []), do: FileStore.latest_run(opts)

  @doc "Compare two file-store eval runs by metrics."
  @spec compare_eval_run_files(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def compare_eval_run_files(run_id_a, run_id_b, opts \\ []),
    do: FileStore.compare_runs(run_id_a, run_id_b, opts)

  # --- Run identity ---

  @doc "Merge best-effort run-identity fields into eval-run attrs."
  @spec capture_eval_run_identity(map()) :: map()
  def capture_eval_run_identity(attrs), do: RunIdentity.capture(attrs)

  @doc "Current git HEAD sha, or nil if unavailable."
  @spec eval_git_sha() :: String.t() | nil
  def eval_git_sha, do: RunIdentity.git_sha()

  @doc "True if the working tree has uncommitted changes, nil if unknown."
  @spec eval_git_dirty() :: boolean() | nil
  def eval_git_dirty, do: RunIdentity.git_dirty()

  @doc "SHA-256 of the dataset file at path, or nil."
  @spec eval_dataset_hash(String.t() | nil) :: String.t() | nil
  def eval_dataset_hash(path), do: RunIdentity.dataset_hash(path)

  @doc "Deterministic SHA-256 fingerprint of a config map."
  @spec eval_config_fingerprint(map() | nil) :: String.t() | nil
  def eval_config_fingerprint(config), do: RunIdentity.config_fingerprint(config)

  @eval_where_filters [:domain, :model, :provider, :status]

  defp eval_apply_filters(query, []), do: query

  defp eval_apply_filters(query, [{field, value} | rest]) when field in @eval_where_filters do
    import Ecto.Query
    eval_apply_filters(from(r in query, where: field(r, ^field) == ^value), rest)
  end

  defp eval_apply_filters(query, [{:limit, n} | rest]) do
    import Ecto.Query
    eval_apply_filters(from(r in query, limit: ^n), rest)
  end

  defp eval_apply_filters(query, [_ | rest]), do: eval_apply_filters(query, rest)

  # ---------------------------------------------------------------
  # Store operations
  # ---------------------------------------------------------------

  @doc """
  Return the code-owned authority mode of a named BufferedStore.

  Callers cannot override whether the store is deliberate ETS-only state or a
  configured backend, nor the backend's durability classification.
  """
  @spec buffered_store_authority_mode(atom()) ::
          {:ok,
           :ephemeral
           | {:backend,
              :volatile | :process_lifetime | :application_restart | :node_restart | :unknown}}
          | {:error, atom()}
  def buffered_store_authority_mode(name) when is_atom(name) do
    BufferedStore.authority_mode(name: name)
  end

  def buffered_store_authority_mode(_name), do: {:error, :invalid_store}

  @doc """
  Return closed startup hydration health for a named BufferedStore.

  Status payload includes only status, loaded_count, configured_limit, and a
  stable reason atom.
  """
  @spec buffered_store_hydration_status(atom()) ::
          {:ok,
           %{
             status: :ready | :failed | :unavailable,
             loaded_count: non_neg_integer(),
             configured_limit: pos_integer(),
             reason: atom()
           }}
          | {:error, atom()}
  def buffered_store_hydration_status(name) when is_atom(name) do
    BufferedStore.hydration_status(name: name)
  end

  def buffered_store_hydration_status(_name), do: {:error, :invalid_store}

  @doc "Authoritatively read a key through a named BufferedStore."
  @spec buffered_store_authoritative_get(atom(), String.t()) ::
          {:ok, term()} | {:error, :not_found | atom()}
  def buffered_store_authoritative_get(name, key) when is_atom(name) and is_binary(key) do
    BufferedStore.authoritative_get(key, name: name)
  end

  def buffered_store_authoritative_get(_name, _key), do: {:error, :invalid_request}

  @doc "Return a bounded deterministic authoritative key inventory from a named BufferedStore."
  @spec buffered_store_authoritative_list(atom()) :: {:ok, [String.t()]} | {:error, atom()}
  def buffered_store_authoritative_list(name) when is_atom(name) do
    BufferedStore.authoritative_list(name: name)
  end

  def buffered_store_authoritative_list(_name), do: {:error, :invalid_store}

  @doc "Return a bounded deterministic authoritative key inventory matching a prefix."
  @spec buffered_store_authoritative_list_by_prefix(atom(), String.t()) ::
          {:ok, [String.t()]} | {:error, atom()}
  def buffered_store_authoritative_list_by_prefix(name, prefix)
      when is_atom(name) and is_binary(prefix) do
    BufferedStore.authoritative_list_by_prefix(prefix, name: name)
  end

  def buffered_store_authoritative_list_by_prefix(_name, _prefix),
    do: {:error, :invalid_request}

  @doc "Return a bounded deterministic authoritative key/value snapshot."
  @spec buffered_store_authoritative_entries(atom()) ::
          {:ok, [{String.t(), term()}]} | {:error, atom()}
  def buffered_store_authoritative_entries(name) when is_atom(name) do
    BufferedStore.authoritative_entries(name: name)
  end

  def buffered_store_authoritative_entries(_name), do: {:error, :invalid_store}

  @doc "Synchronously acknowledge a named BufferedStore put before cache projection."
  @spec buffered_store_acknowledged_put(atom(), String.t(), term()) ::
          {:ok, term()} | {:error, atom()}
  def buffered_store_acknowledged_put(name, key, value)
      when is_atom(name) and is_binary(key) do
    BufferedStore.acknowledged_put(key, value, name: name)
  end

  def buffered_store_acknowledged_put(_name, _key, _value),
    do: {:error, :invalid_request}

  @doc "Synchronously acknowledge a named BufferedStore delete before cache projection."
  @spec buffered_store_acknowledged_delete(atom(), String.t()) :: :ok | {:error, atom()}
  def buffered_store_acknowledged_delete(name, key) when is_atom(name) and is_binary(key) do
    BufferedStore.acknowledged_delete(key, name: name)
  end

  def buffered_store_acknowledged_delete(_name, _key), do: {:error, :invalid_request}

  @doc "Perform acknowledged CAS through a named BufferedStore and update its cache."
  @spec buffered_store_acknowledged_compare_and_swap(
          atom(),
          String.t(),
          :not_found | {:value, term()},
          term()
        ) :: {:ok, term()} | {:error, atom()}
  def buffered_store_acknowledged_compare_and_swap(name, key, expected, replacement)
      when is_atom(name) and is_binary(key) do
    BufferedStore.acknowledged_compare_and_swap(key, expected, replacement, name: name)
  end

  def buffered_store_acknowledged_compare_and_swap(_name, _key, _expected, _replacement),
    do: {:error, :invalid_request}

  @doc "Atomically compare-delete through a named BufferedStore and evict its cache on success."
  @spec buffered_store_acknowledged_compare_and_delete(atom(), String.t(), term()) ::
          :ok | {:error, atom()}
  def buffered_store_acknowledged_compare_and_delete(name, key, expected)
      when is_atom(name) and is_binary(key) do
    BufferedStore.acknowledged_compare_and_delete(key, expected, name: name)
  end

  def buffered_store_acknowledged_compare_and_delete(_name, _key, _expected),
    do: {:error, :invalid_request}

  @doc "Store a value under the given key using the specified backend."
  @spec put(atom(), module(), String.t(), term(), keyword()) :: :ok | {:error, term()}
  def put(name, backend, key, value, opts \\ []) do
    backend.put(key, value, Keyword.put(opts, :name, name))
  end

  @doc "Retrieve a value by key using the specified backend."
  @spec get(atom(), module(), String.t(), keyword()) ::
          {:ok, term()} | {:error, :not_found} | {:error, term()}
  def get(name, backend, key, opts \\ []) do
    backend.get(key, Keyword.put(opts, :name, name))
  end

  @doc "Delete a value by key."
  @spec delete(atom(), module(), String.t(), keyword()) :: :ok | {:error, term()}
  def delete(name, backend, key, opts \\ []) do
    backend.delete(key, Keyword.put(opts, :name, name))
  end

  @doc "List all keys."
  @spec list(atom(), module(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def list(name, backend, opts \\ []) do
    backend.list(Keyword.put(opts, :name, name))
  end

  @doc "Check if a key exists."
  @spec exists?(atom(), module(), String.t(), keyword()) :: boolean()
  def exists?(name, backend, key, opts \\ []) do
    if function_exported?(backend, :exists?, 2) do
      backend.exists?(key, Keyword.put(opts, :name, name))
    else
      case get(name, backend, key, opts) do
        {:ok, _} -> true
        _ -> false
      end
    end
  end

  @doc """
  Atomically compare-and-swap a key via the public facade.

  Delegates only when the backend exports `compare_and_swap/4`. Otherwise
  returns `{:error, :unsupported}`. Consumers must not call backend internals.
  """
  @spec compare_and_swap(
          atom(),
          module(),
          String.t(),
          :not_found | {:value, term()},
          term(),
          keyword()
        ) ::
          {:ok, term()} | {:error, :conflict | :unsupported | term()}
  def compare_and_swap(name, backend, key, expected, replacement, opts \\ []) do
    if supports_compare_and_swap?(backend) do
      backend.compare_and_swap(key, expected, replacement, Keyword.put(opts, :name, name))
    else
      {:error, :unsupported}
    end
  end

  @doc """
  Atomically compare-and-delete a live key via the public facade.

  Delegates only when the backend exports `compare_and_delete/3`. Otherwise
  returns `{:error, :unsupported}`. Structured Records fence on
  generation+revision; ordinary values use exact term equality and retain the
  documented delete/reinsert ABA limitation.
  """
  @spec compare_and_delete(atom(), module(), String.t(), term(), keyword()) ::
          :ok | {:error, :conflict | :unsupported | term()}
  def compare_and_delete(name, backend, key, expected, opts \\ []) do
    if supports_compare_and_delete?(backend) do
      backend.compare_and_delete(key, expected, Keyword.put(opts, :name, name))
    else
      {:error, :unsupported}
    end
  end

  @doc """
  Report a backend's code-owned durability class via the public facade.

  Returns `{:ok, class}` when the backend exports `durability_class/1`, else
  `{:error, :unsupported}`.
  """
  @spec durability_class(atom(), module(), keyword()) ::
          {:ok, :volatile | :process_lifetime | :application_restart | :node_restart}
          | {:error, :unsupported}
  def durability_class(name, backend, opts \\ []) do
    if supports_durability_class?(backend) do
      callback_opts =
        opts
        |> Keyword.drop([:durability_class, :durability])
        |> Keyword.put(:name, name)

      class = backend.durability_class(callback_opts)
      {:ok, class}
    else
      {:error, :unsupported}
    end
  end

  @doc """
  True when the backend module is loaded and exports linearizable `compare_and_swap/4`.
  """
  @spec supports_compare_and_swap?(module()) :: boolean()
  def supports_compare_and_swap?(backend) when is_atom(backend) do
    Code.ensure_loaded?(backend) and function_exported?(backend, :compare_and_swap, 4)
  end

  def supports_compare_and_swap?(_backend), do: false

  @doc """
  True when the backend module is loaded and exports linearizable
  `compare_and_delete/3`.
  """
  @spec supports_compare_and_delete?(module()) :: boolean()
  def supports_compare_and_delete?(backend) when is_atom(backend) do
    Code.ensure_loaded?(backend) and function_exported?(backend, :compare_and_delete, 3)
  end

  def supports_compare_and_delete?(_backend), do: false

  @doc """
  True when the backend module is loaded and exports `durability_class/1`.
  """
  @spec supports_durability_class?(module()) :: boolean()
  def supports_durability_class?(backend) when is_atom(backend) do
    Code.ensure_loaded?(backend) and function_exported?(backend, :durability_class, 1)
  end

  def supports_durability_class?(_backend), do: false

  # ---------------------------------------------------------------
  # QueryableStore operations
  # ---------------------------------------------------------------

  @doc "Query records using a Filter."
  @spec query(atom(), module(), Filter.t(), keyword()) ::
          {:ok, [Record.t()]} | {:error, term()}
  def query(name, backend, %Filter{} = filter, opts \\ []) do
    backend.query(filter, Keyword.put(opts, :name, name))
  end

  @doc "Count records matching a Filter."
  @spec count(atom(), module(), Filter.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def count(name, backend, %Filter{} = filter, opts \\ []) do
    backend.count(filter, Keyword.put(opts, :name, name))
  end

  @doc "Aggregate a numeric field across matching records."
  @spec aggregate(atom(), module(), Filter.t(), atom(), atom(), keyword()) ::
          {:ok, number() | nil} | {:error, term()}
  def aggregate(name, backend, %Filter{} = filter, field, operation, opts \\ []) do
    backend.aggregate(filter, field, operation, Keyword.put(opts, :name, name))
  end

  # ---------------------------------------------------------------
  # EventLog operations
  # ---------------------------------------------------------------

  @doc "Append events to a stream."
  @spec append(atom(), module(), String.t(), [Event.t()] | Event.t(), keyword()) ::
          EventLog.append_result()
  def append(name, backend, stream_id, events, opts \\ []) do
    EventLog.with_operation_deadline(opts, fn normalized_opts, deadline_mono ->
      with :ok <- validate_store_name(name),
           :ok <- validate_backend(backend, :append, 3),
           backend_opts = Keyword.put(normalized_opts, :name, name),
           {:ok, events, _preconditions, operation, ^deadline_mono} <-
             EventLog.prepare_append(stream_id, events, backend_opts) do
        case dispatch_backend(fn -> backend.append(stream_id, events, backend_opts) end) do
          {:ok, result} ->
            EventLog.accept_completion(
              result,
              operation,
              deadline_mono,
              System.monotonic_time(:millisecond)
            )

          {:error, :dispatch_uncertain} ->
            EventLog.indeterminate(operation)
        end
      end
    end)
  end

  @doc "Reconcile an indeterminate append by exact event identity."
  @spec reconcile_append(atom(), module(), AppendOperation.t(), keyword()) ::
          EventLog.append_reconciliation()
  def reconcile_append(name, backend, operation, opts \\ []) do
    EventLog.with_operation_deadline(opts, fn normalized_opts, deadline_mono ->
      with :ok <- validate_store_name(name),
           {:ok, operation} <- EventLog.validate_operation(operation),
           :ok <- validate_backend(backend, :reconcile_append, 2),
           backend_opts = Keyword.put(normalized_opts, :name, name) do
        case dispatch_backend(fn -> backend.reconcile_append(operation, backend_opts) end) do
          {:ok, result} ->
            EventLog.accept_completion(
              result,
              operation,
              deadline_mono,
              System.monotonic_time(:millisecond)
            )

          {:error, :dispatch_uncertain} ->
            EventLog.indeterminate(operation)
        end
      else
        {:error, :backend_unavailable} -> {:error, :reconciliation_not_supported}
        {:error, _reason} = error -> error
      end
    end)
  end

  @doc """
  Permanently purge one complete EventLog stream.

  The supported backend must prove that its event, version, identity, and
  operation-fence surfaces no longer retain the stream before returning `:ok`.
  Timeout or worker failure after dispatch returns
  `{:error, {:purge_indeterminate, stream_id}}`; retrying is idempotent.
  """
  @spec purge_stream(atom(), module(), String.t(), keyword()) :: EventLog.purge_result()
  def purge_stream(name, backend, stream_id, opts \\ []) do
    EventLog.with_operation_deadline(opts, :purge, fn normalized_opts, deadline_mono ->
      backend_opts = Keyword.put(normalized_opts, :name, name)

      with :ok <- validate_store_name(name),
           {:ok, backend_opts, ^deadline_mono} <-
             EventLog.prepare_purge(stream_id, backend_opts),
           :ok <- validate_backend(backend, :purge_stream, 2) do
        case BoundedWorker.run(
               fn ->
                 EventLog.with_inherited_deadline(deadline_mono, fn ->
                   backend.purge_stream(stream_id, backend_opts)
                   |> EventLog.stamp_completion()
                 end)
               end,
               deadline_mono
             ) do
          {:ok, completion} ->
            EventLog.accept_purge_completion(completion, stream_id, deadline_mono)

          {:error, _uncertain} ->
            EventLog.purge_indeterminate(stream_id)
        end
      else
        {:error, :backend_unavailable} -> {:error, :purge_not_supported}
        {:error, _reason} = error -> error
      end
    end)
  end

  @doc """
  Prove whether one complete EventLog stream is absent.

  Read-only authority for every backend-owned event, version, identity,
  subscriber, and operation-fence surface on the exact stream. Returns
  `{:ok, true}` only after a serialized complete-state check proves absence,
  `{:ok, false}` when retained state is observed, and a closed error for
  unsupported backends or post-dispatch uncertainty.
  """
  @spec event_stream_absent?(atom(), module(), String.t(), keyword()) :: EventLog.absence_result()
  def event_stream_absent?(name, backend, stream_id, opts \\ []) do
    EventLog.with_operation_deadline(opts, :absence, fn normalized_opts, deadline_mono ->
      backend_opts = Keyword.put(normalized_opts, :name, name)

      with :ok <- validate_store_name(name),
           {:ok, backend_opts, ^deadline_mono} <-
             EventLog.prepare_absence(stream_id, backend_opts),
           :ok <- validate_backend(backend, :stream_absent, 2) do
        case BoundedWorker.run(
               fn ->
                 EventLog.with_inherited_deadline(deadline_mono, fn ->
                   backend.stream_absent(stream_id, backend_opts)
                   |> EventLog.stamp_completion()
                 end)
               end,
               deadline_mono
             ) do
          {:ok, completion} ->
            EventLog.accept_absence_completion(completion, stream_id, deadline_mono)

          {:error, _uncertain} ->
            EventLog.absence_indeterminate(stream_id)
        end
      else
        {:error, :backend_unavailable} -> {:error, :absence_not_supported}
        {:error, _reason} = error -> error
      end
    end)
  end

  @doc "Read events from a stream."
  @spec read_stream(atom(), module(), String.t(), keyword()) ::
          {:ok, [Event.t()]} | {:error, term()}
  def read_stream(name, backend, stream_id, opts \\ []) do
    backend.read_stream(stream_id, Keyword.put(opts, :name, name))
  end

  @doc "Read a bounded page from an inclusive stream event-number range."
  @spec read_stream_range(atom(), module(), String.t(), keyword()) ::
          {:ok, [Event.t()]} | {:error, term()}
  def read_stream_range(name, backend, stream_id, opts \\ []) do
    with :ok <- validate_store_name(name),
         :ok <- validate_backend(backend, :read_stream_range, 2),
         {:ok, _range} <- EventLog.validate_stream_range(stream_id, opts) do
      backend.read_stream_range(stream_id, Keyword.put(opts, :name, name))
    end
  end

  @doc "Read one stream-scoped immutable event fingerprint by exact ID."
  @spec event_identity(atom(), module(), String.t(), String.t(), keyword()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def event_identity(name, backend, stream_id, event_id, opts \\ []) do
    with :ok <- validate_store_name(name),
         :ok <- validate_backend(backend, :event_identity, 3),
         {:ok, _max_event_number} <- EventLog.validate_identity_read(stream_id, event_id, opts) do
      backend.event_identity(stream_id, event_id, Keyword.put(opts, :name, name))
    end
  end

  @doc "Read the current stream head, optionally bounded by backend-owned freshness."
  @spec read_stream_head(atom(), module(), String.t(), keyword()) ::
          {:ok, Event.t() | nil} | {:error, term()}
  def read_stream_head(name, backend, stream_id, opts \\ []) do
    backend_opts = Keyword.put(opts, :name, name)

    with {:ok, _max_current_age_ms} <- EventLog.validate_head_read(stream_id, backend_opts) do
      backend.read_stream_head(stream_id, backend_opts)
    end
  end

  @doc "Read all events across all streams."
  @spec read_all(atom(), module(), keyword()) :: {:ok, [Event.t()]} | {:error, term()}
  def read_all(name, backend, opts \\ []) do
    backend.read_all(Keyword.put(opts, :name, name))
  end

  @doc "Check if a stream exists."
  @spec stream_exists?(atom(), module(), String.t(), keyword()) :: boolean()
  def stream_exists?(name, backend, stream_id, opts \\ []) do
    backend.stream_exists?(stream_id, Keyword.put(opts, :name, name))
  end

  @doc "Get the current version of a stream."
  @spec stream_version(atom(), module(), String.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def stream_version(name, backend, stream_id, opts \\ []) do
    backend.stream_version(stream_id, Keyword.put(opts, :name, name))
  end

  @doc "List all known stream IDs."
  @spec list_streams(atom(), module(), keyword()) :: {:ok, [String.t()]}
  def list_streams(name, backend, opts \\ []) do
    backend.list_streams(Keyword.put(opts, :name, name))
  end

  @doc "Get the number of distinct streams."
  @spec stream_count(atom(), module(), keyword()) :: {:ok, non_neg_integer()}
  def stream_count(name, backend, opts \\ []) do
    backend.stream_count(Keyword.put(opts, :name, name))
  end

  @doc "Get the total number of events across all streams."
  @spec event_count(atom(), module(), keyword()) :: {:ok, non_neg_integer()}
  def event_count(name, backend, opts \\ []) do
    backend.event_count(Keyword.put(opts, :name, name))
  end

  # ============================================================================
  # Contract Callbacks (Arbor.Contracts.API.Persistence)
  # ============================================================================

  # -- Store (required) --

  @impl Arbor.Contracts.API.Persistence
  def store_value_by_key_using_backend(name, backend, key, value, opts),
    do: put(name, backend, key, value, opts)

  @impl Arbor.Contracts.API.Persistence
  def retrieve_value_by_key_using_backend(name, backend, key, opts),
    do: get(name, backend, key, opts)

  @impl Arbor.Contracts.API.Persistence
  def delete_value_by_key_using_backend(name, backend, key, opts),
    do: delete(name, backend, key, opts)

  @impl Arbor.Contracts.API.Persistence
  def list_all_keys_using_backend(name, backend, opts),
    do: list(name, backend, opts)

  @impl Arbor.Contracts.API.Persistence
  def check_key_exists_using_backend(name, backend, key, opts),
    do: exists?(name, backend, key, opts)

  @impl Arbor.Contracts.API.Persistence
  def compare_and_swap_value_using_backend(name, backend, key, expected, replacement, opts),
    do: compare_and_swap(name, backend, key, expected, replacement, opts)

  @impl Arbor.Contracts.API.Persistence
  def compare_and_delete_value_using_backend(name, backend, key, expected, opts),
    do: compare_and_delete(name, backend, key, expected, opts)

  @impl Arbor.Contracts.API.Persistence
  def report_backend_durability_class(name, backend, opts),
    do: durability_class(name, backend, opts)

  # -- QueryableStore (optional) --

  @impl Arbor.Contracts.API.Persistence
  def query_records_by_filter_using_backend(name, backend, filter, opts),
    do: query(name, backend, filter, opts)

  @impl Arbor.Contracts.API.Persistence
  def count_records_by_filter_using_backend(name, backend, filter, opts),
    do: count(name, backend, filter, opts)

  @impl Arbor.Contracts.API.Persistence
  def aggregate_field_by_filter_using_backend(name, backend, filter, field, operation, opts),
    do: aggregate(name, backend, filter, field, operation, opts)

  # -- EventLog (optional) --

  @impl Arbor.Contracts.API.Persistence
  def append_events_to_stream_using_backend(name, backend, stream_id, events, opts),
    do: append(name, backend, stream_id, events, opts)

  @impl Arbor.Contracts.API.Persistence
  def reconcile_event_append_using_backend(name, backend, operation, opts),
    do: reconcile_append(name, backend, operation, opts)

  @impl Arbor.Contracts.API.Persistence
  def purge_complete_event_stream_using_backend(name, backend, stream_id, opts),
    do: purge_stream(name, backend, stream_id, opts)

  @impl Arbor.Contracts.API.Persistence
  def check_complete_event_stream_absent_using_backend(name, backend, stream_id, opts),
    do: event_stream_absent?(name, backend, stream_id, opts)

  @impl Arbor.Contracts.API.Persistence
  def read_events_from_stream_using_backend(name, backend, stream_id, opts),
    do: read_stream(name, backend, stream_id, opts)

  @impl Arbor.Contracts.API.Persistence
  def read_current_stream_head_using_backend(name, backend, stream_id, opts),
    do: read_stream_head(name, backend, stream_id, opts)

  @impl Arbor.Contracts.API.Persistence
  def read_all_events_using_backend(name, backend, opts),
    do: read_all(name, backend, opts)

  @impl Arbor.Contracts.API.Persistence
  def check_stream_exists_using_backend(name, backend, stream_id, opts),
    do: stream_exists?(name, backend, stream_id, opts)

  @impl Arbor.Contracts.API.Persistence
  def get_stream_version_using_backend(name, backend, stream_id, opts),
    do: stream_version(name, backend, stream_id, opts)

  @impl Arbor.Contracts.API.Persistence
  def list_all_streams_using_backend(name, backend, opts),
    do: list_streams(name, backend, opts)

  @impl Arbor.Contracts.API.Persistence
  def get_stream_count_using_backend(name, backend, opts),
    do: stream_count(name, backend, opts)

  @impl Arbor.Contracts.API.Persistence
  def get_event_count_using_backend(name, backend, opts),
    do: event_count(name, backend, opts)

  # -- VectorStore (optional) --

  @impl Arbor.Contracts.API.Persistence
  def execute_validated_vector_operation_for_agent(agent_id, operation, opts),
    do: execute_vector_operation(agent_id, operation, opts)

  @impl Arbor.Contracts.API.Persistence
  def reconcile_validated_vector_operation_for_agent(agent_id, operation, opts),
    do: reconcile_vector_operation(agent_id, operation, opts)

  @impl Arbor.Contracts.API.Persistence
  def retrieve_vector_record_by_logical_identity_for_agent(
        agent_id,
        source_namespace,
        source_key,
        opts
      ),
      do: fetch_vector_record(agent_id, source_namespace, source_key, opts)

  @impl Arbor.Contracts.API.Persistence
  def list_vector_records_for_agent(agent_id, opts),
    do: list_vector_records(agent_id, opts)

  @impl Arbor.Contracts.API.Persistence
  def search_vector_records_by_exact_descriptor_for_agent(agent_id, vector, opts),
    do: VectorBoundary.search_exact_category(agent_id, vector, opts)

  @impl Arbor.Contracts.API.Persistence
  def search_vector_records_by_exact_model_descriptor_and_scope_for_agent(agent_id, vector, opts),
    do: VectorBoundary.search(agent_id, vector, opts)

  @impl Arbor.Contracts.API.Persistence
  def delete_all_strict_vector_records_and_operation_receipts_for_agent(agent_id, opts),
    do: destroy_vector_agent(agent_id, opts)

  # -- Relationships (optional) --
  #
  # Trailing `opts` on long-form callbacks are closed allowlists. Fetch/update/
  # delete/touch/count/primary/delete_all/absence admit only the empty keyword
  # list; list admits the RelationshipStore list allowlist. Unknown, duplicate,
  # non-keyword, or non-list opts return {:error, :invalid_options}.

  @relationship_empty_opts_allowlist []
  @relationship_list_opts_allowlist [:sort_by, :sort_dir, :limit]

  @impl Arbor.Contracts.API.Persistence
  def upsert_tenant_relationship_record_for_agent(agent_id, attrs),
    do: put_relationship(agent_id, attrs)

  @impl Arbor.Contracts.API.Persistence
  def retrieve_tenant_relationship_record_by_id_for_agent(agent_id, relationship_id, opts) do
    with :ok <- validate_relationship_opts(opts, @relationship_empty_opts_allowlist) do
      fetch_relationship(agent_id, relationship_id)
    end
  end

  @impl Arbor.Contracts.API.Persistence
  def retrieve_tenant_relationship_record_by_name_for_agent(agent_id, name, opts) do
    with :ok <- validate_relationship_opts(opts, @relationship_empty_opts_allowlist) do
      fetch_relationship_by_name(agent_id, name)
    end
  end

  @impl Arbor.Contracts.API.Persistence
  def list_tenant_relationship_records_for_agent(agent_id, opts) do
    with :ok <- validate_relationship_opts(opts, @relationship_list_opts_allowlist) do
      list_relationships(agent_id, opts)
    end
  end

  @impl Arbor.Contracts.API.Persistence
  def update_tenant_relationship_record_for_agent(agent_id, relationship_id, changes, opts) do
    with :ok <- validate_relationship_opts(opts, @relationship_empty_opts_allowlist) do
      update_relationship(agent_id, relationship_id, changes)
    end
  end

  @impl Arbor.Contracts.API.Persistence
  def delete_tenant_relationship_record_for_agent(agent_id, relationship_id, opts) do
    with :ok <- validate_relationship_opts(opts, @relationship_empty_opts_allowlist) do
      delete_relationship(agent_id, relationship_id)
    end
  end

  @impl Arbor.Contracts.API.Persistence
  def touch_tenant_relationship_record_for_agent(agent_id, relationship_id, opts) do
    with :ok <- validate_relationship_opts(opts, @relationship_empty_opts_allowlist) do
      touch_relationship(agent_id, relationship_id)
    end
  end

  @impl Arbor.Contracts.API.Persistence
  def count_tenant_relationship_records_for_agent(agent_id, opts) do
    with :ok <- validate_relationship_opts(opts, @relationship_empty_opts_allowlist) do
      count_relationships(agent_id)
    end
  end

  @impl Arbor.Contracts.API.Persistence
  def retrieve_primary_tenant_relationship_record_for_agent(agent_id, opts) do
    with :ok <- validate_relationship_opts(opts, @relationship_empty_opts_allowlist) do
      fetch_primary_relationship(agent_id)
    end
  end

  @impl Arbor.Contracts.API.Persistence
  def delete_all_tenant_relationship_records_for_agent(agent_id, opts) do
    with :ok <- validate_relationship_opts(opts, @relationship_empty_opts_allowlist) do
      delete_all_relationships(agent_id)
    end
  end

  @impl Arbor.Contracts.API.Persistence
  def check_tenant_relationship_records_absent_for_agent(agent_id, opts) do
    with :ok <- validate_relationship_opts(opts, @relationship_empty_opts_allowlist) do
      relationships_absent?(agent_id)
    end
  end

  defp validate_relationship_opts(opts, allowlist) do
    cond do
      not is_list(opts) ->
        {:error, :invalid_options}

      not Keyword.keyword?(opts) ->
        {:error, :invalid_options}

      length(Keyword.keys(opts)) != length(Enum.uniq(Keyword.keys(opts))) ->
        {:error, :invalid_options}

      Enum.any?(Keyword.keys(opts), &(&1 not in allowlist)) ->
        {:error, :invalid_options}

      true ->
        :ok
    end
  end

  defp normalize_authorization_opts(opts) do
    case EventLog.normalize_opts(opts) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, _reason} -> {:error, :invalid_options}
    end
  end

  defp validate_store_name(name) when is_atom(name) and not is_nil(name), do: :ok
  defp validate_store_name(_name), do: {:error, :invalid_precondition}

  defp validate_backend(backend, function, arity) when is_atom(backend) do
    if Code.ensure_loaded?(backend) and function_exported?(backend, function, arity),
      do: :ok,
      else: {:error, :backend_unavailable}
  end

  defp validate_backend(_backend, _function, _arity), do: {:error, :backend_unavailable}

  defp dispatch_backend(fun) do
    {:ok, fun.()}
  rescue
    _error -> {:error, :dispatch_uncertain}
  catch
    _kind, _reason -> {:error, :dispatch_uncertain}
  end

  # Closed-allowlist keyword validation for the session transcript facade above.
  # Rejects anything outside `allowlist` instead of silently filtering it out.
  defp validate_opts(opts, allowlist) do
    cond do
      not Keyword.keyword?(opts) ->
        {:error, {:invalid_opts, :not_a_keyword_list}}

      has_duplicate_keys?(opts) ->
        {:error, {:invalid_opts, :duplicate_keys}}

      true ->
        case Enum.reject(Keyword.keys(opts), &(&1 in allowlist)) do
          [] -> :ok
          unknown -> {:error, {:invalid_opts, {:unknown_keys, unknown}}}
        end
    end
  end

  defp has_duplicate_keys?(opts) do
    keys = Keyword.keys(opts)
    length(keys) != length(Enum.uniq(keys))
  end

  # Value bounds for load_recent_session_messages/2's opts — allowlisting the
  # KEYS above is not itself a bound; a present key must also hold a value
  # inside its own contract or it is rejected outright, not passed through to
  # the query.
  defp validate_load_opt_values(opts) do
    with :ok <- validate_limit_opt(Keyword.get(opts, :limit)),
         :ok <- validate_before_timestamp_opt(Keyword.get(opts, :before_timestamp)) do
      validate_engagement_id_opt(Keyword.get(opts, :engagement_id))
    end
  end

  defp validate_limit_opt(nil), do: :ok

  defp validate_limit_opt(limit)
       when is_integer(limit) and limit > 0 and limit <= @load_limit_max,
       do: :ok

  defp validate_limit_opt(limit), do: {:error, {:invalid_opt_value, :limit, limit}}

  defp validate_before_timestamp_opt(nil), do: :ok
  defp validate_before_timestamp_opt(%DateTime{}), do: :ok

  defp validate_before_timestamp_opt(value),
    do: {:error, {:invalid_opt_value, :before_timestamp, value}}

  defp validate_engagement_id_opt(nil), do: :ok

  defp validate_engagement_id_opt(v) when is_binary(v) do
    # Byte-size checked before String.valid?/1 / String.trim/1 — bounds an
    # oversized untrusted value on a cheap byte_size/1 call before either scan
    # walks it.
    cond do
      byte_size(v) > @engagement_id_max_bytes ->
        {:error, {:invalid_opt_value, :engagement_id, :too_large}}

      not String.valid?(v) ->
        {:error, {:invalid_opt_value, :engagement_id, :not_utf8}}

      String.trim(v) == "" ->
        {:error, {:invalid_opt_value, :engagement_id, :blank}}

      true ->
        :ok
    end
  end

  defp validate_engagement_id_opt(v), do: {:error, {:invalid_opt_value, :engagement_id, v}}
end
