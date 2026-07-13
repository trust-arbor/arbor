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
  alias Arbor.Persistence.{Event, EventLog}
  alias Arbor.Persistence.Repo

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
  Report a backend's code-owned durability class via the public facade.

  Returns `{:ok, class}` when the backend exports `durability_class/1`, else
  `{:error, :unsupported}`.
  """
  @spec durability_class(atom(), module(), keyword()) ::
          {:ok, :volatile | :process_lifetime | :application_restart | :node_restart}
          | {:error, :unsupported}
  def durability_class(name, backend, opts \\ []) do
    if supports_durability_class?(backend) do
      class = backend.durability_class(Keyword.put(opts, :name, name))
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

  @doc "Read events from a stream."
  @spec read_stream(atom(), module(), String.t(), keyword()) ::
          {:ok, [Event.t()]} | {:error, term()}
  def read_stream(name, backend, stream_id, opts \\ []) do
    backend.read_stream(stream_id, Keyword.put(opts, :name, name))
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
end
