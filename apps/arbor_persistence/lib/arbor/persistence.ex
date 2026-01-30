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

  alias Arbor.Persistence.{Event, Filter, Record}

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
    resource = "arbor://persistence/write/#{name}"
    {trace_id, opts} = Keyword.pop(opts, :trace_id)

    case Arbor.Security.authorize(agent_id, resource, :write, trace_id: trace_id) do
      {:ok, :authorized} ->
        put(name, backend, key, value, opts)

      {:ok, :pending_approval, proposal_id} ->
        {:ok, :pending_approval, proposal_id}

      {:error, reason} ->
        {:error, {:unauthorized, reason}}
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
    resource = "arbor://persistence/read/#{name}"
    {trace_id, opts} = Keyword.pop(opts, :trace_id)

    case Arbor.Security.authorize(agent_id, resource, :read, trace_id: trace_id) do
      {:ok, :authorized} ->
        get(name, backend, key, opts)

      {:ok, :pending_approval, proposal_id} ->
        {:ok, :pending_approval, proposal_id}

      {:error, reason} ->
        {:error, {:unauthorized, reason}}
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
  @spec authorize_append(String.t(), atom(), module(), String.t(), [Event.t()] | Event.t(), keyword()) ::
          {:ok, [Event.t()]}
          | {:ok, :pending_approval, String.t()}
          | {:error, {:unauthorized, term()} | term()}
  def authorize_append(agent_id, name, backend, stream_id, events, opts \\ []) do
    resource = "arbor://persistence/write/#{name}"
    {trace_id, opts} = Keyword.pop(opts, :trace_id)

    case Arbor.Security.authorize(agent_id, resource, :write, trace_id: trace_id) do
      {:ok, :authorized} ->
        append(name, backend, stream_id, events, opts)

      {:ok, :pending_approval, proposal_id} ->
        {:ok, :pending_approval, proposal_id}

      {:error, reason} ->
        {:error, {:unauthorized, reason}}
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
    resource = "arbor://persistence/read/#{name}"
    {trace_id, opts} = Keyword.pop(opts, :trace_id)

    case Arbor.Security.authorize(agent_id, resource, :read, trace_id: trace_id) do
      {:ok, :authorized} ->
        read_stream(name, backend, stream_id, opts)

      {:ok, :pending_approval, proposal_id} ->
        {:ok, :pending_approval, proposal_id}

      {:error, reason} ->
        {:error, {:unauthorized, reason}}
    end
  end

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
          {:ok, [Event.t()]} | {:error, term()}
  def append(name, backend, stream_id, events, opts \\ []) do
    backend.append(stream_id, events, Keyword.put(opts, :name, name))
  end

  @doc "Read events from a stream."
  @spec read_stream(atom(), module(), String.t(), keyword()) ::
          {:ok, [Event.t()]} | {:error, term()}
  def read_stream(name, backend, stream_id, opts \\ []) do
    backend.read_stream(stream_id, Keyword.put(opts, :name, name))
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
  def read_events_from_stream_using_backend(name, backend, stream_id, opts),
    do: read_stream(name, backend, stream_id, opts)

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
end
