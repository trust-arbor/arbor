defmodule Arbor.Persistence.Core do
  @moduledoc """
  Generic stores, acknowledged buffering, bounded event logs and checkpoints.

  Product applications retain their own schema, credentials and lifetime composition.
  Authorization is selected through the fail-closed authorization provider port.
  """

  alias Arbor.Persistence.{
    Authorization,
    BufferedStore,
    ContractProviders,
    Event,
    EventLog,
    Filter,
    Record
  }

  alias Arbor.Persistence.Contracts.AppendOperation
  alias Arbor.Persistence.EventLog.BoundedWorker

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

      case Authorization.authorize(agent_id, resource, :write, trace_id: trace_id) do
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

      case Authorization.authorize(agent_id, resource, :read, trace_id: trace_id) do
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

          case Authorization.authorize(agent_id, resource, :write, trace_id: trace_id) do
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

      case Authorization.authorize(agent_id, resource, :read, trace_id: trace_id) do
        {:ok, :authorized} -> read_stream(name, backend, stream_id, opts)
        {:ok, :pending_approval, proposal_id} -> {:ok, :pending_approval, proposal_id}
        {:error, reason} -> {:error, {:unauthorized, reason}}
      end
    end
  end

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
  def query(name, backend, filter, opts \\ []) do
    if owner_validates_filter?(backend) or ContractProviders.filter?(filter),
      do: backend.query(filter, Keyword.put(opts, :name, name)),
      else: {:error, :invalid_filter}
  end

  @doc "Count records matching a Filter."
  @spec count(atom(), module(), Filter.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def count(name, backend, filter, opts \\ []) do
    if owner_validates_filter?(backend) or ContractProviders.filter?(filter),
      do: backend.count(filter, Keyword.put(opts, :name, name)),
      else: {:error, :invalid_filter}
  end

  @doc "Aggregate a numeric field across matching records."
  @spec aggregate(atom(), module(), Filter.t(), atom(), atom(), keyword()) ::
          {:ok, number() | nil} | {:error, term()}
  def aggregate(name, backend, filter, field, operation, opts \\ []) do
    if owner_validates_filter?(backend) or ContractProviders.filter?(filter),
      do: backend.aggregate(filter, field, operation, Keyword.put(opts, :name, name)),
      else: {:error, :invalid_filter}
  end

  # ---------------------------------------------------------------
  # EventLog operations
  # ---------------------------------------------------------------

  @doc "Construct an event through the public persistence boundary; does not append it."
  @spec new_event(String.t(), String.t(), map(), keyword()) :: Event.t()
  def new_event(stream_id, type, data, opts \\ []),
    do: Event.new(stream_id, type, data, opts)

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

  @doc """
  Compute the canonical identity fingerprint for one EventLog event.

  This is the public adapter boundary for components that must construct or
  validate committed append acknowledgements without depending on EventLog
  internals. Invalid stream or event input returns `nil`.
  """
  @spec canonical_event_fingerprint(String.t(), Event.t()) :: String.t() | nil
  def canonical_event_fingerprint(stream_id, event),
    do: EventLog.event_fingerprint(stream_id, event)

  @doc """
  Verify that one positioned committed event is the exact durable
  acknowledgement of a submitted event.

  Assigned positions may differ because the backend owns them. Event identity,
  content, stream, and the backend-reported operation fingerprint must match the
  canonical submitted event.
  """
  @spec committed_event_matches_submission?(String.t(), Event.t(), Event.t()) :: boolean()
  def committed_event_matches_submission?(
        stream_id,
        %Event{id: submitted_id, stream_id: submitted_stream_id} = submitted,
        %Event{
          id: committed_id,
          stream_id: committed_stream_id,
          event_number: event_number,
          global_position: global_position,
          operation_fingerprint: reported_fingerprint
        } = committed
      )
      when submitted_stream_id == stream_id and committed_stream_id == stream_id and
             submitted_id == committed_id and is_integer(event_number) and event_number > 0 and
             is_integer(global_position) and global_position > 0 and
             is_binary(reported_fingerprint) do
    expected_fingerprint = EventLog.event_fingerprint(stream_id, submitted)

    is_binary(expected_fingerprint) and reported_fingerprint == expected_fingerprint and
      EventLog.event_fingerprint_matches?(stream_id, committed, expected_fingerprint)
  rescue
    _ -> false
  end

  def committed_event_matches_submission?(_stream_id, _submitted, _committed), do: false

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

  @doc "Read at most five exact event records and their pinned head, without stream replay."
  def read_event_records(name, backend, stream_id, event_ids, opts \\ []) do
    reader = Arbor.Persistence.EventLog.EventRecords

    with :ok <- validate_store_name(name),
         {:ok, bound} <- reader.validate_request(stream_id, event_ids, opts),
         true <-
           is_atom(backend) and Code.ensure_loaded?(backend) and
             function_exported?(backend, :read_event_records, 3),
         {:ok, result} <-
           backend.read_event_records(stream_id, event_ids, Keyword.put(opts, :name, name)) do
      reader.validate_result(stream_id, event_ids, bound, result)
    else
      false -> {:error, :event_records_not_supported}
      {:error, _} = error -> error
      _ -> {:error, :event_records_invalid}
    end
  rescue
    _ -> {:error, :backend_unavailable}
  catch
    _, _ -> {:error, :backend_unavailable}
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

  @doc """
  Get the authoritative current version of a stream.

  A non-authoritative projection returns
  `{:error, :stream_version_unavailable}`. Use
  `resident_projected_stream_version/4` only when explicitly inspecting
  projection residency.
  """
  @spec stream_version(atom(), module(), String.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def stream_version(name, backend, stream_id, opts \\ []) do
    backend.stream_version(stream_id, Keyword.put(opts, :name, name))
  end

  @doc """
  Return the highest event number currently resident for one projected stream.

  This value is non-authoritative observation only. It returns zero when no
  event for the stream is resident. Unsupported backends return
  `{:error, :projection_not_supported}` and authoritative backends return
  `{:error, :projection_mode_required}`.
  """
  @spec resident_projected_stream_version(atom(), module(), String.t(), keyword()) ::
          {:ok, non_neg_integer()}
          | {:error, EventLog.projection_control_error()}
  def resident_projected_stream_version(name, backend, stream_id, opts \\ []) do
    with :ok <- validate_store_name(name),
         {:ok, normalized_opts} <-
           EventLog.validate_projection_stream_request(stream_id, opts),
         :ok <- validate_backend(backend, :resident_projected_stream_version, 2) do
      backend.resident_projected_stream_version(
        stream_id,
        Keyword.put(normalized_opts, :name, name)
      )
    else
      {:error, :backend_unavailable} -> {:error, :projection_not_supported}
      {:error, _reason} = error -> error
    end
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

  @doc """
  Project events another component already committed durably into a backend.

  This is a **non-authoritative** operation: the caller supplies each event's
  exact `event_number`, `global_position`, and canonical `operation_fingerprint`,
  and the backend assigns nothing. The complete batch is validated before any
  mutation, so a conflict leaves every backend surface unchanged, and
  re-projecting a byte-identical batch is idempotent.

  Backends that do not implement projection return
  `{:error, :projection_not_supported}`; a backend running in its ordinary
  authoritative mode returns `{:error, :projection_mode_required}`. Check
  `supports_projection?/1` first when the backend is not statically known.
  """
  @spec project_committed_events(atom(), module(), [Event.t()], keyword()) ::
          EventLog.projection_result() | {:error, :projection_not_supported}
  def project_committed_events(name, backend, events, opts \\ []) do
    with :ok <- validate_store_name(name),
         :ok <- validate_backend(backend, :project_committed_events, 2),
         {:ok, normalized_opts} <- EventLog.normalize_opts(opts) do
      backend.project_committed_events(events, Keyword.put(normalized_opts, :name, name))
    else
      {:error, :backend_unavailable} -> {:error, :projection_not_supported}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Evict every resident projection surface for exactly one stream.

  This is an idempotent cache operation, not a durable purge. Success reports
  only the number of resident event payloads removed and makes no claim that
  the stream is absent from its authoritative store. Byte-identical events may
  be projected again afterward.

  `:timeout_ms` sets one `1..60_000` millisecond facade deadline (default
  `5_000`) across backend dispatch and reply. The timeout control is consumed
  by this facade and is never passed into the backend's sealed projection opts.
  Timeout or worker failure returns `{:error, :backend_unavailable}`; eviction
  is idempotent and may be retried after that uncertainty.
  """
  @spec evict_projected_stream(atom(), module(), String.t(), keyword()) ::
          EventLog.projection_eviction_result()
  def evict_projected_stream(name, backend, stream_id, opts \\ []) do
    with :ok <- validate_store_name(name),
         {:ok, backend_opts, deadline_mono} <-
           EventLog.prepare_projection_eviction(stream_id, opts),
         :ok <- validate_backend(backend, :evict_projected_stream, 2) do
      case BoundedWorker.run(
             fn ->
               backend.evict_projected_stream(
                 stream_id,
                 Keyword.put(backend_opts, :name, name)
               )
             end,
             deadline_mono
           ) do
        {:ok, result} -> result
        {:error, _uncertain} -> {:error, :backend_unavailable}
      end
    else
      {:error, :backend_unavailable} -> {:error, :projection_not_supported}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  True when the backend module is loaded and exports `project_committed_events/2`.
  """
  @spec supports_projection?(module()) :: boolean()
  def supports_projection?(backend) when is_atom(backend) do
    Code.ensure_loaded?(backend) and function_exported?(backend, :project_committed_events, 2)
  end

  def supports_projection?(_backend), do: false

  # ============================================================================
  # Compatibility callback names
  # ============================================================================

  # -- Store (required) --

  def store_value_by_key_using_backend(name, backend, key, value, opts),
    do: put(name, backend, key, value, opts)

  def retrieve_value_by_key_using_backend(name, backend, key, opts),
    do: get(name, backend, key, opts)

  def delete_value_by_key_using_backend(name, backend, key, opts),
    do: delete(name, backend, key, opts)

  def list_all_keys_using_backend(name, backend, opts),
    do: list(name, backend, opts)

  def check_key_exists_using_backend(name, backend, key, opts),
    do: exists?(name, backend, key, opts)

  def compare_and_swap_value_using_backend(name, backend, key, expected, replacement, opts),
    do: compare_and_swap(name, backend, key, expected, replacement, opts)

  def compare_and_delete_value_using_backend(name, backend, key, expected, opts),
    do: compare_and_delete(name, backend, key, expected, opts)

  def report_backend_durability_class(name, backend, opts),
    do: durability_class(name, backend, opts)

  # -- QueryableStore (optional) --

  def query_records_by_filter_using_backend(name, backend, filter, opts),
    do: query(name, backend, filter, opts)

  def count_records_by_filter_using_backend(name, backend, filter, opts),
    do: count(name, backend, filter, opts)

  def aggregate_field_by_filter_using_backend(name, backend, filter, field, operation, opts),
    do: aggregate(name, backend, filter, field, operation, opts)

  # -- EventLog (optional) --

  def append_events_to_stream_using_backend(name, backend, stream_id, events, opts),
    do: append(name, backend, stream_id, events, opts)

  def reconcile_event_append_using_backend(name, backend, operation, opts),
    do: reconcile_append(name, backend, operation, opts)

  def purge_complete_event_stream_using_backend(name, backend, stream_id, opts),
    do: purge_stream(name, backend, stream_id, opts)

  def check_complete_event_stream_absent_using_backend(name, backend, stream_id, opts),
    do: event_stream_absent?(name, backend, stream_id, opts)

  def read_events_from_stream_using_backend(name, backend, stream_id, opts),
    do: read_stream(name, backend, stream_id, opts)

  def read_current_stream_head_using_backend(name, backend, stream_id, opts),
    do: read_stream_head(name, backend, stream_id, opts)

  def read_all_events_using_backend(name, backend, opts),
    do: read_all(name, backend, opts)

  def check_stream_exists_using_backend(name, backend, stream_id, opts),
    do: stream_exists?(name, backend, stream_id, opts)

  def get_stream_version_using_backend(name, backend, stream_id, opts),
    do: stream_version(name, backend, stream_id, opts)

  def list_all_streams_using_backend(name, backend, opts),
    do: list_streams(name, backend, opts)

  def get_stream_count_using_backend(name, backend, opts),
    do: stream_count(name, backend, opts)

  def get_event_count_using_backend(name, backend, opts),
    do: event_count(name, backend, opts)

  def project_already_committed_events_into_backend(name, backend, events, opts),
    do: project_committed_events(name, backend, events, opts)

  def evict_projected_event_stream_from_backend(name, backend, stream_id, opts),
    do: evict_projected_stream(name, backend, stream_id, opts)

  def get_resident_projected_stream_version_using_backend(name, backend, stream_id, opts),
    do: resident_projected_stream_version(name, backend, stream_id, opts)

  # These backends admit the exact Filter under their selected owner's binding.
  # Avoid checking the current global composition before they can select that owner.
  defp owner_validates_filter?(backend) do
    backend in [
      BufferedStore,
      Arbor.Persistence.QueryableStore.Agent,
      Arbor.Persistence.QueryableStore.ETS
    ]
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
end
