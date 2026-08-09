defmodule Arbor.Persistence.BufferedStore do
  @moduledoc """
  ETS-cached persistence with pluggable durable backend.

  A GenServer that keeps a public ETS table as a compatibility read projection,
  with writes flowing through to a configurable backend implementing
  `Arbor.Contracts.Persistence.Store`.

  ## Design

  - **Reads**: Direct ETS lookup — bypass GenServer for maximum throughput
  - **Writes**: Serialized through GenServer, then ETS + backend
  - **Init**: Atomically hydrates a bounded backend inventory into ETS (failure → empty ETS + explicit status)
  - **Graceful degradation**: Cache-acknowledged backend failures are logged but don't crash
  - **Backend acknowledgement**: Critical stores can require backend success before cache mutation
  - **Hydration limit**: Trusted per-instance startup bound (default 10_000), distinct from the public authoritative snapshot cap

  ## Options

      {BufferedStore,
        name:             :my_store,              # required — GenServer + ETS table name
        backend:          QueryableStore.Postgres, # nil = ETS-only
        backend_opts:     [repo: Repo],           # extra opts passed to backend calls
        write_mode:       :async,                 # :async | :sync
        ack_mode:         :cache,                 # :cache | :backend
        collection:       "my_collection",        # passed as name: to backend
        hydration_limit:  10_000,                 # trusted startup bound (default 10_000)
        distributed:      true}                   # enable cross-node cache invalidation

  ## Usage

  Functions accept a `name:` option to target a specific instance:

      BufferedStore.put("key", record, name: :my_store)
      BufferedStore.get("key", name: :my_store)
  """

  use GenServer

  require Logger

  alias Arbor.Contracts.Persistence.{Filter, Record}
  alias Arbor.Persistence.Store.Revision

  @behaviour Arbor.Contracts.Persistence.Store

  @max_authoritative_keys 10_000
  @max_prefix_bytes 1_024

  # ===========================================================================
  # Client API — Store behaviour callbacks
  # ===========================================================================

  @impl true
  def put(key, value, opts \\ []) do
    # Structured Records must bind physical store key == Record.key.
    # Reject before any ETS/backend mutation (same invariant as Store.ETS/Agent).
    if Revision.key_mismatch?(key, value) do
      {:error, :key_mismatch}
    else
      store = store_name!(opts)
      GenServer.call(store, {:put, key, value})
    end
  end

  @impl true
  def get(key, opts \\ []) do
    table = ets_table!(opts)

    case :ets.lookup(table, key) do
      [{^key, value}] -> {:ok, value}
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def delete(key, opts \\ []) do
    store = store_name!(opts)
    GenServer.call(store, {:delete, key})
  end

  @impl true
  def list(opts \\ []) do
    table = ets_table!(opts)

    keys =
      :ets.foldl(
        fn {key, _value}, acc -> [key | acc] end,
        [],
        table
      )

    {:ok, Enum.sort(keys)}
  end

  @impl true
  def exists?(key, opts \\ []) do
    table = ets_table!(opts)
    :ets.member(table, key)
  end

  @impl true
  def query(%Filter{} = filter, opts \\ []) do
    table = ets_table!(opts)

    records =
      :ets.foldl(
        fn {_key, value}, acc -> [value | acc] end,
        [],
        table
      )

    {:ok, Filter.apply(filter, records)}
  end

  @impl true
  def count(%Filter{} = filter, opts \\ []) do
    case query(filter, opts) do
      {:ok, results} -> {:ok, length(results)}
      error -> error
    end
  end

  @impl true
  def aggregate(%Filter{} = filter, field, operation, opts \\ [])
      when operation in [:sum, :avg, :min, :max] do
    case query(filter, opts) do
      {:ok, results} ->
        values =
          results
          |> Enum.map(&get_numeric_field(&1, field))
          |> Enum.reject(&is_nil/1)

        result =
          case {operation, values} do
            {_, []} -> nil
            {:sum, vals} -> Enum.sum(vals)
            {:avg, vals} -> Enum.sum(vals) / length(vals)
            {:min, vals} -> Enum.min(vals)
            {:max, vals} -> Enum.max(vals)
          end

        {:ok, result}

      error ->
        error
    end
  end

  # Buffered/async stores cannot preserve synchronous linearizable CAS across
  # the cache + durable backend boundary. Do not implement compare_and_swap/4;
  # the facade reports {:error, :unsupported}.

  @impl true
  def durability_class(_opts), do: :process_lifetime

  # ===========================================================================
  # GenServer start
  # ===========================================================================

  @doc """
  Start a BufferedStore instance.

  ## Required Options

  - `:name` — atom name for both GenServer registration and ETS table

  ## Optional

  - `:backend` — module implementing Store behaviour (nil = ETS-only)
  - `:backend_opts` — extra opts merged into backend calls
  - `:write_mode` — `:async` (default) or `:sync`
  - `:ack_mode` — `:cache` (default) or `:backend`; backend acknowledgement
    requires synchronous writes and mutates ETS only after backend success
  - `:collection` — string passed as `name:` to backend (defaults to stringified name)
  - `:hydration_limit` — trusted positive integer startup inventory bound
    (defaults to 10_000). Not a Store list/query option for untrusted callers.
  """
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Probe whether the backend is currently reachable.

  Returns `true` when:
  - The store has no backend configured (`backend: nil` — ETS-only)
  - The backend's `list/1` returns a successful response (`{:ok, _}` or `{:error, _}`
    with a non-crashing reason)

  Returns `false` when the backend crashes (raises, exits, or throws) when
  probed. Mirrors the resilience contract: failures are observed without
  propagating.

  Useful in tests that want to skip backend-dependent assertions when the
  Repo / Sandbox / external service isn't reachable, without coupling to
  the specific backend implementation.

      iex> BufferedStore.backend_healthy?(name: :my_store)
      true
  """
  @spec backend_healthy?(keyword()) :: boolean()
  def backend_healthy?(opts) do
    store = store_name!(opts)
    GenServer.call(store, :backend_healthy?)
  end

  @doc """
  Return closed startup hydration health for a named store.

  Fields are status, loaded_count, configured_limit, and a stable reason atom
  only — never paths, payloads, exceptions, credentials, or signatures.
  """
  @spec hydration_status(keyword()) ::
          {:ok,
           %{
             status: :ready | :failed | :unavailable,
             loaded_count: non_neg_integer(),
             configured_limit: pos_integer(),
             reason: atom()
           }}
          | {:error, atom()}
  def hydration_status(opts) do
    store = store_name!(opts)
    authority_call(store, :hydration_status, :read)
  end

  @doc """
  Return the code-owned authority mode for a named store.

  `:ephemeral` means the store was deliberately configured without a backend;
  acknowledged operations are serialized against owner-private state and then
  projected to ETS.
  `{:backend, class}` means acknowledged operations bypass cache-ack settings
  and synchronously use the configured backend. The durability class comes
  from the backend callback and cannot be supplied by callers.
  """
  @spec authority_mode(keyword()) ::
          {:ok,
           :ephemeral
           | {:backend,
              :volatile | :process_lifetime | :application_restart | :node_restart | :unknown}}
          | {:error, atom()}
  def authority_mode(opts) do
    store = store_name!(opts)
    authority_call(store, :authority_mode, :read)
  end

  @doc """
  Read the configured backend authoritatively, or owner-private state in
  ephemeral mode.

  A configured backend error never falls back to the cache.
  """
  @spec authoritative_get(String.t(), keyword()) ::
          {:ok, term()} | {:error, :not_found | atom()}
  def authoritative_get(key, opts \\ []) do
    store = store_name!(opts)
    authority_call(store, {:authoritative_get, key}, :read)
  end

  @doc "Return a deterministic, bounded authoritative key inventory."
  @spec authoritative_list(keyword()) :: {:ok, [String.t()]} | {:error, atom()}
  def authoritative_list(opts \\ []) do
    store = store_name!(opts)
    authority_call(store, {:authoritative_list, nil}, :read)
  end

  @doc "Return a deterministic, bounded authoritative key inventory by prefix."
  @spec authoritative_list_by_prefix(String.t(), keyword()) ::
          {:ok, [String.t()]} | {:error, atom()}
  def authoritative_list_by_prefix(prefix, opts \\ [])

  def authoritative_list_by_prefix(prefix, opts)
      when is_binary(prefix) and byte_size(prefix) <= @max_prefix_bytes do
    store = store_name!(opts)
    authority_call(store, {:authoritative_list, prefix}, :read)
  end

  def authoritative_list_by_prefix(_prefix, _opts), do: {:error, :invalid_prefix}

  @doc "Return a deterministic bounded authoritative key/value snapshot."
  @spec authoritative_entries(keyword()) ::
          {:ok, [{String.t(), term()}]} | {:error, atom()}
  def authoritative_entries(opts \\ []) do
    store = store_name!(opts)
    authority_call(store, :authoritative_entries, :read)
  end

  @doc """
  Perform an acknowledged put and then update the named store cache.

  Configured backends are called synchronously regardless of the store's
  compatibility `write_mode`/`ack_mode`. Ephemeral stores serialize the put in
  the owner process and return the exact retained value.
  """
  @spec acknowledged_put(String.t(), term(), keyword()) ::
          {:ok, term()} | {:error, atom()}
  def acknowledged_put(key, value, opts \\ []) do
    if Revision.key_mismatch?(key, value) do
      {:error, :key_mismatch}
    else
      store = store_name!(opts)
      authority_call(store, {:acknowledged_put, key, value}, :mutation)
    end
  end

  @doc """
  Perform an acknowledged delete before removing the named store cache entry.
  """
  @spec acknowledged_delete(String.t(), keyword()) :: :ok | {:error, atom()}
  def acknowledged_delete(key, opts \\ []) do
    store = store_name!(opts)
    authority_call(store, {:acknowledged_delete, key}, :mutation)
  end

  @doc """
  Perform an acknowledged structured compare-and-swap.

  Configured backends must export `compare_and_swap/4`. Ephemeral stores use
  the same `Record` generation/revision matching inside the owner process. This
  API does not make BufferedStore a Store-behaviour CAS backend; it is a narrow
  named-store authority primitive that also updates the local projection.
  """
  @spec acknowledged_compare_and_swap(
          String.t(),
          :not_found | {:value, term()},
          term(),
          keyword()
        ) :: {:ok, term()} | {:error, atom()}
  def acknowledged_compare_and_swap(key, expected, replacement, opts \\ []) do
    if Revision.cas_operands_key_mismatch?(key, expected, replacement) do
      {:error, :key_mismatch}
    else
      store = store_name!(opts)

      authority_call(
        store,
        {:acknowledged_compare_and_swap, key, expected, replacement},
        :mutation
      )
    end
  end

  @doc """
  Atomically delete an observed value and only then evict the named-store cache.

  Configured backends must export `compare_and_delete/3`. Ephemeral stores
  compare structured `Record` generation/revision in the owner process;
  reinsertion receives a BEAM-monotonic generation for ABA fencing without
  retaining unbounded tombstones.
  """
  @spec acknowledged_compare_and_delete(String.t(), term(), keyword()) ::
          :ok | {:error, atom()}
  def acknowledged_compare_and_delete(key, expected, opts \\ []) do
    if Revision.key_mismatch?(key, expected) do
      {:error, :key_mismatch}
    else
      store = store_name!(opts)
      authority_call(store, {:acknowledged_compare_and_delete, key, expected}, :mutation)
    end
  end

  # ===========================================================================
  # GenServer callbacks
  # ===========================================================================

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    backend = Keyword.get(opts, :backend)
    backend_opts = Keyword.get(opts, :backend_opts, [])
    write_mode = Keyword.get(opts, :write_mode, :async)
    ack_mode = Keyword.get(opts, :ack_mode, :cache)
    collection = Keyword.get(opts, :collection, to_string(name))
    distributed = Keyword.get(opts, :distributed, false)

    validate_write_options!(write_mode, ack_mode)

    case parse_hydration_limit(Keyword.get(opts, :hydration_limit)) do
      {:ok, hydration_limit} ->
        # Create ETS table — public for direct reads from any process
        table =
          :ets.new(name, [:named_table, :public, :set, {:read_concurrency, true}])

        state = %{
          table: table,
          backend: backend,
          backend_opts: backend_opts,
          write_mode: write_mode,
          ack_mode: ack_mode,
          collection: collection,
          distributed: distributed,
          ephemeral_authority: %{},
          hydration_limit: hydration_limit,
          hydration: hydration_ready(0, hydration_limit)
        }

        state = hydrate_from_backend(state)

        if distributed do
          subscribe_to_distributed_signals(collection)
        end

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(
        {:put, key, value},
        _from,
        %{backend: nil, ack_mode: :cache} = state
      ) do
    if Revision.key_mismatch?(key, value) do
      {:reply, {:error, :key_mismatch}, state}
    else
      case put_ephemeral_authority(state, key, value) do
        {:ok, stored, state} ->
          true = :ets.insert(state.table, {key, stored})
          emit_distributed_signal(state, :cache_put, key)
          {:reply, :ok, state}

        {:error, _reason} = error ->
          {:reply, error, converge_ephemeral_projection(state, key)}
      end
    end
  end

  def handle_call({:put, key, value}, _from, state) do
    # Defense in depth: client put/3 already rejects mismatches; never mutate
    # the public projection or durable backend on key mismatch.
    if Revision.key_mismatch?(key, value) do
      {:reply, {:error, :key_mismatch}, state}
    else
      case state.ack_mode do
        :cache ->
          :ets.insert(state.table, {key, value})
          backend_put(state, key, value)
          emit_distributed_signal(state, :cache_put, key)
          {:reply, :ok, state}

        :backend ->
          case backend_put(state, key, value) do
            :ok ->
              :ets.insert(state.table, {key, value})
              emit_distributed_signal(state, :cache_put, key)
              {:reply, :ok, state}

            {:error, _reason} = error ->
              {:reply, error, state}
          end
      end
    end
  end

  @impl true
  def handle_call({:delete, key}, _from, %{backend: nil, ack_mode: :cache} = state) do
    state = delete_ephemeral_authority(state, key)
    true = :ets.delete(state.table, key)
    emit_distributed_signal(state, :cache_delete, key)
    {:reply, :ok, state}
  end

  def handle_call({:delete, key}, _from, state) do
    case state.ack_mode do
      :cache ->
        :ets.delete(state.table, key)
        backend_delete(state, key)
        emit_distributed_signal(state, :cache_delete, key)
        {:reply, :ok, state}

      :backend ->
        case backend_delete(state, key) do
          :ok ->
            :ets.delete(state.table, key)
            emit_distributed_signal(state, :cache_delete, key)
            {:reply, :ok, state}

          {:error, _reason} = error ->
            {:reply, error, state}
        end
    end
  end

  @impl true
  def handle_call(:backend_healthy?, _from, state) do
    {:reply, do_backend_healthy?(state), state}
  end

  def handle_call(:hydration_status, _from, state) do
    {:reply, {:ok, state.hydration}, state}
  end

  def handle_call(:authority_mode, _from, state) do
    {:reply, {:ok, authority_mode_for(state)}, state}
  end

  def handle_call({:authoritative_get, key}, _from, state) do
    {:reply, do_authoritative_get(state, key), state}
  end

  def handle_call({:authoritative_list, prefix}, _from, state) do
    {:reply, do_authoritative_list(state, prefix), state}
  end

  def handle_call(:authoritative_entries, _from, state) do
    {:reply, do_authoritative_entries(state), state}
  end

  def handle_call({:acknowledged_put, key, value}, _from, state) do
    if Revision.key_mismatch?(key, value) do
      {:reply, {:error, :key_mismatch}, state}
    else
      {reply, state} = do_acknowledged_put(state, key, value)
      {:reply, reply, state}
    end
  end

  def handle_call({:acknowledged_delete, key}, _from, state) do
    {reply, state} = do_acknowledged_delete(state, key)
    {:reply, reply, state}
  end

  def handle_call(
        {:acknowledged_compare_and_swap, key, expected, replacement},
        _from,
        state
      ) do
    if Revision.cas_operands_key_mismatch?(key, expected, replacement) do
      {:reply, {:error, :key_mismatch}, state}
    else
      {reply, state} = do_acknowledged_compare_and_swap(state, key, expected, replacement)
      {:reply, reply, state}
    end
  end

  def handle_call({:acknowledged_compare_and_delete, key, expected}, _from, state) do
    if Revision.key_mismatch?(key, expected) do
      {:reply, {:error, :key_mismatch}, state}
    else
      {reply, state} = do_acknowledged_compare_and_delete(state, key, expected)
      {:reply, reply, state}
    end
  end

  @impl true
  def handle_info({:signal_received, signal}, state) do
    handle_distributed_signal(signal, state)
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ===========================================================================
  # Backend operations
  # ===========================================================================

  defp authority_mode_for(%{backend: nil}), do: :ephemeral

  defp authority_mode_for(%{backend: backend} = state) do
    durability =
      if Code.ensure_loaded?(backend) and function_exported?(backend, :durability_class, 1) do
        case guarded_backend_read(fn -> backend.durability_class(backend_call_opts(state)) end) do
          class
          when class in [:volatile, :process_lifetime, :application_restart, :node_restart] ->
            class

          _ ->
            :unknown
        end
      else
        :unknown
      end

    {:backend, durability}
  end

  defp do_authoritative_get(%{backend: nil, ephemeral_authority: authority} = state, key) do
    case Map.fetch(authority, key) do
      {:ok, value} ->
        true = :ets.insert(state.table, {key, value})
        {:ok, value}

      :error ->
        true = :ets.delete(state.table, key)
        {:error, :not_found}
    end
  end

  defp do_authoritative_get(%{backend: backend} = state, key) do
    case guarded_backend_read(fn -> backend.get(key, backend_call_opts(state)) end) do
      {:ok, value} ->
        if Revision.key_mismatch?(key, value) do
          true = :ets.delete(state.table, key)
          {:error, :invalid_backend_record}
        else
          true = :ets.insert(state.table, {key, value})
          {:ok, value}
        end

      {:error, :not_found} = not_found ->
        true = :ets.delete(state.table, key)
        not_found

      {:error, _reason} ->
        # Availability failure reveals nothing about the cached value. Keep the
        # compatibility projection; authoritative callers still receive an
        # error and never fall back to it.
        {:error, :backend_unavailable}

      _other ->
        true = :ets.delete(state.table, key)
        {:error, :invalid_backend_response}
    end
  end

  defp do_authoritative_list(%{backend: nil, ephemeral_authority: authority}, prefix) do
    normalize_ephemeral_authority(authority, prefix, :keys)
  end

  defp do_authoritative_list(%{backend: backend} = state, prefix) do
    opts =
      Keyword.put(backend_call_opts(state), :authoritative_limit, @max_authoritative_keys + 1)

    case guarded_backend_read(fn -> backend.list(opts) end) do
      {:ok, keys} when is_list(keys) -> normalize_authoritative_keys(keys, prefix)
      {:error, :inventory_limit_exceeded} -> {:error, :inventory_limit_exceeded}
      {:error, _reason} -> {:error, :backend_unavailable}
      _other -> {:error, :invalid_backend_response}
    end
  end

  defp do_authoritative_entries(%{backend: nil, ephemeral_authority: authority}) do
    normalize_ephemeral_authority(authority, nil, :entries)
  end

  defp do_authoritative_entries(%{backend: backend} = state) do
    if Code.ensure_loaded?(backend) and function_exported?(backend, :query, 2) do
      filter =
        Filter.new()
        |> Filter.order_by(:key, :asc)
        |> Filter.limit(@max_authoritative_keys + 1)

      opts =
        Keyword.put(
          backend_call_opts(state),
          :authoritative_limit,
          @max_authoritative_keys + 1
        )

      case guarded_backend_read(fn -> backend.query(filter, opts) end) do
        {:ok, records} -> normalize_authoritative_records(records, state)
        {:error, :inventory_limit_exceeded} -> {:error, :inventory_limit_exceeded}
        {:error, _reason} -> {:error, :backend_unavailable}
        _other -> {:error, :invalid_backend_response}
      end
    else
      {:error, :unsupported}
    end
  end

  defp normalize_authoritative_keys(keys, prefix) do
    reduce_authoritative_backend_keys(keys, prefix, [], 0)
  rescue
    _ -> {:error, :invalid_backend_response}
  catch
    _, _ -> {:error, :invalid_backend_response}
  end

  defp normalize_ephemeral_authority(authority, prefix, return) do
    if map_size(authority) > @max_authoritative_keys do
      {:error, :inventory_limit_exceeded}
    else
      authority
      |> Enum.reduce_while({:ok, []}, fn
        {key, value}, {:ok, acc} when is_binary(key) ->
          cond do
            is_binary(prefix) and not String.starts_with?(key, prefix) ->
              {:cont, {:ok, acc}}

            return == :keys ->
              {:cont, {:ok, [key | acc]}}

            true ->
              {:cont, {:ok, [{key, value} | acc]}}
          end

        _entry, _acc ->
          {:halt, {:error, :invalid_cache_state}}
      end)
      |> case do
        {:ok, values} when return == :keys -> {:ok, Enum.sort(values)}
        {:ok, values} -> {:ok, Enum.sort_by(values, &elem(&1, 0))}
        {:error, _reason} = error -> error
      end
    end
  rescue
    _ -> {:error, :invalid_cache_state}
  catch
    _, _ -> {:error, :invalid_cache_state}
  end

  defp reduce_authoritative_backend_keys([], _prefix, acc, _visited),
    do: {:ok, Enum.sort(acc)}

  defp reduce_authoritative_backend_keys(_keys, _prefix, _acc, visited)
       when visited >= @max_authoritative_keys,
       do: {:error, :inventory_limit_exceeded}

  defp reduce_authoritative_backend_keys([key | rest], prefix, acc, visited)
       when is_binary(key) do
    acc =
      if is_binary(prefix) and not String.starts_with?(key, prefix),
        do: acc,
        else: [key | acc]

    reduce_authoritative_backend_keys(rest, prefix, acc, visited + 1)
  end

  defp reduce_authoritative_backend_keys([_invalid | _rest], _prefix, _acc, _visited),
    do: {:error, :invalid_backend_response}

  defp reduce_authoritative_backend_keys(_improper, _prefix, _acc, _visited),
    do: {:error, :invalid_backend_response}

  defp normalize_authoritative_records(records, state) do
    case reduce_authoritative_records(records, [], MapSet.new(), 0) do
      {:ok, entries} ->
        entries = Enum.sort_by(entries, &elem(&1, 0))

        # Reconcile only after the complete bounded snapshot validates so a
        # malformed backend response cannot erase an otherwise usable cache.
        true = :ets.delete_all_objects(state.table)
        true = :ets.insert(state.table, entries)
        {:ok, entries}

      {:error, _reason} = error ->
        error
    end
  rescue
    _ -> {:error, :invalid_backend_response}
  catch
    _, _ -> {:error, :invalid_backend_response}
  end

  defp reduce_authoritative_records([], acc, _seen, _count),
    do: {:ok, Enum.reverse(acc)}

  defp reduce_authoritative_records(_records, _acc, _seen, count)
       when count >= @max_authoritative_keys,
       do: {:error, :inventory_limit_exceeded}

  defp reduce_authoritative_records(
         [%Record{key: key} = record | rest],
         acc,
         seen,
         count
       )
       when is_binary(key) do
    if MapSet.member?(seen, key) do
      {:error, :invalid_backend_response}
    else
      reduce_authoritative_records(rest, [{key, record} | acc], MapSet.put(seen, key), count + 1)
    end
  end

  defp reduce_authoritative_records([_invalid | _rest], _acc, _seen, _count),
    do: {:error, :invalid_backend_response}

  defp reduce_authoritative_records(_improper, _acc, _seen, _count),
    do: {:error, :invalid_backend_response}

  defp do_acknowledged_put(%{backend: nil} = state, key, value) do
    case put_ephemeral_authority(state, key, value) do
      {:ok, stored, state} ->
        true = :ets.insert(state.table, {key, stored})
        emit_distributed_signal(state, :cache_put, key)
        {{:ok, stored}, state}

      {:error, reason} ->
        {{:error, reason}, converge_ephemeral_projection(state, key)}
    end
  end

  defp do_acknowledged_put(%{backend: backend} = state, key, value) do
    case guarded_backend_mutation(fn -> backend.put(key, value, backend_call_opts(state)) end) do
      :ok ->
        case do_authoritative_get(state, key) do
          {:ok, stored} ->
            emit_distributed_signal(state, :cache_put, key)
            {{:ok, stored}, state}

          {:error, _reason} ->
            true = :ets.delete(state.table, key)
            {{:error, :outcome_unknown}, state}
        end

      {:error, _reason} ->
        true = :ets.delete(state.table, key)
        {{:error, :outcome_unknown}, state}

      _other ->
        true = :ets.delete(state.table, key)
        {{:error, :outcome_unknown}, state}
    end
  end

  defp do_acknowledged_delete(%{backend: nil} = state, key) do
    state = delete_ephemeral_authority(state, key)
    true = :ets.delete(state.table, key)
    emit_distributed_signal(state, :cache_delete, key)
    {:ok, state}
  end

  defp do_acknowledged_delete(%{backend: backend} = state, key) do
    case guarded_backend_mutation(fn -> backend.delete(key, backend_call_opts(state)) end) do
      :ok ->
        true = :ets.delete(state.table, key)
        emit_distributed_signal(state, :cache_delete, key)
        {:ok, state}

      {:error, _reason} ->
        true = :ets.delete(state.table, key)
        {{:error, :outcome_unknown}, state}

      _other ->
        true = :ets.delete(state.table, key)
        {{:error, :outcome_unknown}, state}
    end
  end

  defp do_acknowledged_compare_and_swap(%{backend: nil} = state, key, expected, replacement) do
    current =
      case Map.fetch(state.ephemeral_authority, key) do
        {:ok, value} -> {:value, value}
        :error -> :not_found
      end

    with :ok <- ensure_ephemeral_capacity(state, key) do
      case ephemeral_cas(current, expected, replacement) do
        {:ok, stored} ->
          authority = Map.put(state.ephemeral_authority, key, stored)
          true = :ets.insert(state.table, {key, stored})
          emit_distributed_signal(state, :cache_put, key)
          state = %{state | ephemeral_authority: authority}
          {{:ok, stored}, state}

        {:error, :conflict} = error ->
          {error, converge_ephemeral_projection(state, key)}
      end
    else
      {:error, _reason} = error -> {error, converge_ephemeral_projection(state, key)}
    end
  end

  defp do_acknowledged_compare_and_swap(%{backend: backend} = state, key, expected, replacement) do
    if Code.ensure_loaded?(backend) and function_exported?(backend, :compare_and_swap, 4) do
      result =
        guarded_backend_mutation(fn ->
          backend.compare_and_swap(key, expected, replacement, backend_call_opts(state))
        end)

      case result do
        {:ok, stored} ->
          if Revision.key_mismatch?(key, stored) do
            true = :ets.delete(state.table, key)
            {{:error, :outcome_unknown}, state}
          else
            true = :ets.insert(state.table, {key, stored})
            emit_distributed_signal(state, :cache_put, key)
            {{:ok, stored}, state}
          end

        {:error, :conflict} ->
          true = :ets.delete(state.table, key)
          {{:error, :conflict}, state}

        {:error, :key_mismatch} ->
          {{:error, :key_mismatch}, state}

        {:error, _reason} ->
          true = :ets.delete(state.table, key)
          {{:error, :outcome_unknown}, state}

        _other ->
          true = :ets.delete(state.table, key)
          {{:error, :outcome_unknown}, state}
      end
    else
      {{:error, :unsupported}, state}
    end
  end

  defp ephemeral_cas(:not_found, :not_found, replacement) do
    {:ok, Revision.advance_ephemeral_insert(replacement)}
  end

  defp ephemeral_cas({:value, current}, {:value, expected}, replacement) do
    if Revision.cas_matches?(current, expected) do
      case {current, replacement} do
        {%Record{} = current_record, %Record{} = replacement_record} ->
          Revision.advance_cas_update(current_record, replacement_record)

        {_current, %Record{}} ->
          {:error, :conflict}

        {_current, replacement} ->
          {:ok, replacement}
      end
    else
      {:error, :conflict}
    end
  end

  defp ephemeral_cas(_current, _expected, _replacement), do: {:error, :conflict}

  defp do_acknowledged_compare_and_delete(%{backend: nil} = state, key, expected) do
    case Map.fetch(state.ephemeral_authority, key) do
      {:ok, current} ->
        if Revision.cas_matches?(current, expected) do
          state = delete_ephemeral_authority(state, key)
          true = :ets.delete(state.table, key)
          emit_distributed_signal(state, :cache_delete, key)
          {:ok, state}
        else
          {{:error, :conflict}, converge_ephemeral_projection(state, key)}
        end

      :error ->
        {{:error, :conflict}, converge_ephemeral_projection(state, key)}
    end
  end

  defp do_acknowledged_compare_and_delete(%{backend: backend} = state, key, expected) do
    if Code.ensure_loaded?(backend) and function_exported?(backend, :compare_and_delete, 3) do
      result =
        guarded_backend_mutation(fn ->
          backend.compare_and_delete(key, expected, backend_call_opts(state))
        end)

      case result do
        :ok ->
          true = :ets.delete(state.table, key)
          emit_distributed_signal(state, :cache_delete, key)
          {:ok, state}

        {:error, :conflict} ->
          true = :ets.delete(state.table, key)
          {{:error, :conflict}, state}

        {:error, :key_mismatch} ->
          {{:error, :key_mismatch}, state}

        {:error, _reason} ->
          true = :ets.delete(state.table, key)
          {{:error, :outcome_unknown}, state}

        _other ->
          true = :ets.delete(state.table, key)
          {{:error, :outcome_unknown}, state}
      end
    else
      {{:error, :unsupported}, state}
    end
  end

  defp put_ephemeral_authority(state, key, value) do
    with :ok <- ensure_ephemeral_capacity(state, key),
         {:ok, stored} <- apply_ephemeral_put(state.ephemeral_authority, key, value) do
      state = %{state | ephemeral_authority: Map.put(state.ephemeral_authority, key, stored)}
      {:ok, stored, state}
    end
  end

  defp apply_ephemeral_put(authority, key, value) do
    case {Map.fetch(authority, key), value} do
      {{:ok, %Record{} = current}, %Record{} = replacement} ->
        Revision.advance_cas_update(current, replacement)

      {{:ok, _non_record}, %Record{} = replacement} ->
        {:ok, Revision.advance_ephemeral_insert(replacement)}

      {{:ok, current}, replacement} ->
        Revision.apply_put(current, replacement)

      {:error, replacement} ->
        {:ok, Revision.advance_ephemeral_insert(replacement)}
    end
  end

  defp ensure_ephemeral_capacity(%{ephemeral_authority: authority}, key) do
    if Map.has_key?(authority, key) or map_size(authority) < @max_authoritative_keys do
      :ok
    else
      {:error, :inventory_limit_exceeded}
    end
  end

  defp delete_ephemeral_authority(state, key) do
    %{state | ephemeral_authority: Map.delete(state.ephemeral_authority, key)}
  end

  defp converge_ephemeral_projection(state, key) do
    case Map.fetch(state.ephemeral_authority, key) do
      {:ok, current} -> true = :ets.insert(state.table, {key, current})
      :error -> true = :ets.delete(state.table, key)
    end

    state
  end

  defp backend_call_opts(state) do
    Keyword.merge(state.backend_opts, name: state.collection)
  end

  defp guarded_backend_read(fun) do
    fun.()
  rescue
    _ -> {:error, :backend_unavailable}
  catch
    :exit, _ -> {:error, :backend_unavailable}
    :throw, _ -> {:error, :backend_unavailable}
  end

  defp guarded_backend_mutation(fun) do
    fun.()
  rescue
    _ -> {:error, :outcome_unknown}
  catch
    :exit, _ -> {:error, :outcome_unknown}
    :throw, _ -> {:error, :outcome_unknown}
  end

  # No backend = trivially healthy (ETS-only is always reachable).
  defp do_backend_healthy?(%{backend: nil}), do: true

  defp do_backend_healthy?(%{
         backend: backend,
         backend_opts: backend_opts,
         collection: collection
       }) do
    opts = Keyword.merge(backend_opts, name: collection)

    # A reachable backend returns *some* response from list/1, even an
    # `{:error, _}`. An unreachable backend raises / exits / throws.
    # `list/1` is a light query (just key enumeration) and is mandated by
    # the Store behaviour so every backend supports it.
    case backend.list(opts) do
      {:ok, _} -> true
      {:error, _} -> true
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
    :throw, _ -> false
  end

  defp parse_hydration_limit(nil), do: {:ok, @max_authoritative_keys}

  defp parse_hydration_limit(limit) when is_integer(limit) and limit > 0, do: {:ok, limit}

  defp parse_hydration_limit(other), do: {:error, {:invalid_hydration_limit, other}}

  defp hydration_ready(loaded_count, limit) do
    %{
      status: :ready,
      loaded_count: loaded_count,
      configured_limit: limit,
      reason: :ok
    }
  end

  defp hydration_failed(limit, reason) do
    %{
      status: :failed,
      loaded_count: 0,
      configured_limit: limit,
      reason: reason
    }
  end

  defp hydrate_from_backend(%{backend: nil, hydration_limit: limit} = state) do
    %{state | hydration: hydration_ready(0, limit)}
  end

  defp hydrate_from_backend(%{backend: _backend, hydration_limit: limit} = state) do
    case collect_hydration_entries(state) do
      {:ok, entries} ->
        true = :ets.delete_all_objects(state.table)

        if entries != [] do
          true = :ets.insert(state.table, entries)
        end

        %{state | hydration: hydration_ready(length(entries), limit)}

      {:error, reason} ->
        true = :ets.delete_all_objects(state.table)
        log_backend_load_failure()
        %{state | hydration: hydration_failed(limit, reason)}
    end
  rescue
    _ ->
      true = :ets.delete_all_objects(state.table)
      log_backend_load_failure()
      %{state | hydration: hydration_failed(state.hydration_limit, :hydration_error)}
  catch
    _, _ ->
      true = :ets.delete_all_objects(state.table)
      log_backend_load_failure()
      %{state | hydration: hydration_failed(state.hydration_limit, :hydration_error)}
  end

  defp collect_hydration_entries(%{backend: backend} = state) do
    if Code.ensure_loaded?(backend) and function_exported?(backend, :query, 2) do
      collect_query_hydration_entries(state)
    else
      collect_crud_hydration_entries(state)
    end
  end

  defp collect_query_hydration_entries(%{backend: backend, hydration_limit: limit} = state) do
    filter =
      Filter.new()
      |> Filter.order_by(:key, :asc)
      |> Filter.limit(limit + 1)

    opts = backend_call_opts(state)

    case guarded_backend_read(fn -> backend.query(filter, opts) end) do
      {:ok, records} when is_list(records) ->
        normalize_hydration_values(records, limit)

      {:error, :backend_unavailable} ->
        {:error, :backend_unavailable}

      {:error, _} ->
        {:error, :backend_unavailable}

      _other ->
        {:error, :invalid_backend_response}
    end
  end

  defp collect_crud_hydration_entries(%{backend: backend, hydration_limit: limit} = state) do
    opts = backend_call_opts(state)

    case guarded_backend_read(fn -> backend.list(opts) end) do
      {:ok, keys} when is_list(keys) ->
        with :ok <- validate_hydration_keys(keys, limit) do
          keys
          |> Enum.sort()
          |> fetch_hydration_values(backend, opts, limit)
        end

      {:error, :backend_unavailable} ->
        {:error, :backend_unavailable}

      {:error, _} ->
        {:error, :backend_unavailable}

      _other ->
        {:error, :invalid_backend_response}
    end
  end

  defp validate_hydration_keys(keys, limit) do
    case reduce_hydration_keys(keys, MapSet.new(), 0) do
      {:ok, count} when count > limit ->
        {:error, :inventory_limit_exceeded}

      {:ok, _count} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reduce_hydration_keys([], _seen, count), do: {:ok, count}

  defp reduce_hydration_keys([key | rest], seen, count) when is_binary(key) do
    if MapSet.member?(seen, key) do
      {:error, :invalid_backend_response}
    else
      reduce_hydration_keys(rest, MapSet.put(seen, key), count + 1)
    end
  end

  defp reduce_hydration_keys([_invalid | _rest], _seen, _count),
    do: {:error, :invalid_backend_response}

  defp reduce_hydration_keys(_improper, _seen, _count),
    do: {:error, :invalid_backend_response}

  defp fetch_hydration_values(keys, backend, opts, limit) do
    if length(keys) > limit do
      {:error, :inventory_limit_exceeded}
    else
      Enum.reduce_while(keys, {:ok, []}, fn key, {:ok, acc} ->
        case guarded_backend_read(fn -> backend.get(key, opts) end) do
          {:ok, value} ->
            case hydration_entry(key, value) do
              {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
              {:error, reason} -> {:halt, {:error, reason}}
            end

          {:error, :not_found} ->
            {:halt, {:error, :incomplete_inventory}}

          {:error, :backend_unavailable} ->
            {:halt, {:error, :backend_unavailable}}

          {:error, _} ->
            {:halt, {:error, :incomplete_inventory}}

          _other ->
            {:halt, {:error, :invalid_backend_response}}
        end
      end)
      |> case do
        {:ok, entries} -> {:ok, Enum.reverse(entries)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp normalize_hydration_values(values, limit) do
    case reduce_hydration_values(values, [], MapSet.new(), 0, limit) do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ -> {:error, :invalid_backend_response}
  catch
    _, _ -> {:error, :invalid_backend_response}
  end

  defp reduce_hydration_values([], acc, _seen, _count, _limit), do: {:ok, acc}

  defp reduce_hydration_values(_values, _acc, _seen, count, limit) when count > limit,
    do: {:error, :inventory_limit_exceeded}

  defp reduce_hydration_values([%Record{key: key} = record | rest], acc, seen, count, limit)
       when is_binary(key) do
    cond do
      count >= limit ->
        {:error, :inventory_limit_exceeded}

      MapSet.member?(seen, key) ->
        {:error, :invalid_backend_response}

      Revision.key_mismatch?(key, record) ->
        {:error, :invalid_backend_record}

      true ->
        reduce_hydration_values(
          rest,
          [{key, record} | acc],
          MapSet.put(seen, key),
          count + 1,
          limit
        )
    end
  end

  defp reduce_hydration_values([{key, value} | rest], acc, seen, count, limit)
       when is_binary(key) do
    cond do
      count >= limit ->
        {:error, :inventory_limit_exceeded}

      MapSet.member?(seen, key) ->
        {:error, :invalid_backend_response}

      Revision.key_mismatch?(key, value) ->
        {:error, :invalid_backend_record}

      true ->
        reduce_hydration_values(
          rest,
          [{key, value} | acc],
          MapSet.put(seen, key),
          count + 1,
          limit
        )
    end
  end

  defp reduce_hydration_values([_invalid | _rest], _acc, _seen, _count, _limit),
    do: {:error, :invalid_backend_response}

  defp reduce_hydration_values(_improper, _acc, _seen, _count, _limit),
    do: {:error, :invalid_backend_response}

  defp hydration_entry(key, value) do
    if Revision.key_mismatch?(key, value) do
      {:error, :invalid_backend_record}
    else
      {:ok, {key, value}}
    end
  end

  defp log_backend_load_failure do
    try do
      Logger.warning("BufferedStore backend hydration failed")
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    :ok
  end

  defp backend_put(%{backend: nil, ack_mode: :backend}, _key, _value),
    do: {:error, :backend_not_configured}

  defp backend_put(%{backend: nil}, _key, _value), do: :ok

  defp backend_put(
         %{
           backend: backend,
           backend_opts: backend_opts,
           collection: collection,
           write_mode: mode
         },
         key,
         value
       ) do
    opts = Keyword.merge(backend_opts, name: collection)

    case mode do
      :async ->
        Task.start(fn ->
          do_backend_put(backend, key, value, opts)
        end)

        :ok

      :sync ->
        do_backend_put(backend, key, value, opts)
    end
  end

  # Cache-acknowledged callers keep their historical best-effort behavior.
  # Backend-acknowledged callers receive this error and do not mutate ETS.
  defp do_backend_put(backend, key, value, opts) do
    case backend.put(key, value, opts) do
      :ok ->
        :ok

      {:error, reason} = error ->
        Logger.error("BufferedStore: backend put failed for #{key}: #{inspect(reason)}")
        error
    end
  rescue
    e ->
      Logger.error("BufferedStore: backend put error for #{key}: #{inspect(e)}")
      {:error, {:backend_exception, Exception.message(e)}}
  catch
    :exit, reason ->
      Logger.error("BufferedStore: backend put exit for #{key}: #{inspect(reason)}")
      {:error, {:backend_exit, reason}}

    :throw, value ->
      Logger.error("BufferedStore: backend put throw for #{key}: #{inspect(value)}")
      {:error, {:backend_throw, value}}
  end

  defp backend_delete(%{backend: nil, ack_mode: :backend}, _key),
    do: {:error, :backend_not_configured}

  defp backend_delete(%{backend: nil}, _key), do: :ok

  defp backend_delete(
         %{
           backend: backend,
           backend_opts: backend_opts,
           collection: collection,
           write_mode: mode
         },
         key
       ) do
    opts = Keyword.merge(backend_opts, name: collection)

    case mode do
      :async ->
        Task.start(fn ->
          do_backend_delete(backend, key, opts)
        end)

        :ok

      :sync ->
        do_backend_delete(backend, key, opts)
    end
  end

  defp do_backend_delete(backend, key, opts) do
    case backend.delete(key, opts) do
      :ok ->
        :ok

      {:error, reason} = error ->
        Logger.warning("BufferedStore: backend delete failed for #{key}: #{inspect(reason)}")
        error
    end
  rescue
    e ->
      Logger.warning("BufferedStore: backend delete error for #{key}: #{inspect(e)}")
      {:error, {:backend_exception, Exception.message(e)}}
  catch
    :exit, reason ->
      Logger.warning("BufferedStore: backend delete exit for #{key}: #{inspect(reason)}")
      {:error, {:backend_exit, reason}}

    :throw, value ->
      Logger.warning("BufferedStore: backend delete throw for #{key}: #{inspect(value)}")
      {:error, {:backend_throw, value}}
  end

  defp validate_write_options!(write_mode, ack_mode) do
    unless write_mode in [:async, :sync] do
      raise ArgumentError, "write_mode must be :async or :sync"
    end

    unless ack_mode in [:cache, :backend] do
      raise ArgumentError, "ack_mode must be :cache or :backend"
    end

    if ack_mode == :backend and write_mode != :sync do
      raise ArgumentError, "ack_mode :backend requires write_mode :sync"
    end
  end

  # ===========================================================================
  # Distributed Cache Invalidation
  # ===========================================================================

  defp emit_distributed_signal(%{distributed: false}, _type, _key), do: :ok

  defp emit_distributed_signal(%{distributed: true, collection: collection}, type, key) do
    Arbor.Signals.emit(
      :persistence,
      type,
      %{
        collection: collection,
        key: key,
        origin_node: node()
      },
      scope: :cluster
    )

    :ok
  catch
    _, _ -> :ok
  end

  defp handle_distributed_signal(%{data: %{origin_node: origin}}, state)
       when origin == node() do
    # Ignore signals from our own node
    {:noreply, state}
  end

  defp handle_distributed_signal(%{data: data} = signal, state) do
    collection = Map.get(data, :collection)

    state =
      if collection == state.collection,
        do: apply_remote_cache_signal(signal.type, data, state),
        else: state

    {:noreply, state}
  rescue
    e ->
      Logger.warning("BufferedStore[#{state.collection}]: error handling signal: #{inspect(e)}")
      {:noreply, state}
  end

  defp apply_remote_cache_signal(type, data, %{backend: nil} = state)
       when type in [:cache_put, :cache_delete] do
    key = Map.get(data, :key)
    state = delete_ephemeral_authority(state, key)
    true = :ets.delete(state.table, key)
    state
  end

  defp apply_remote_cache_signal(:cache_put, data, state) do
    key = Map.get(data, :key)
    reload_key_from_backend(state, key)
    safe_remote_cache_log(state, :cache_put, key, Map.get(data, :origin_node))
    state
  end

  defp apply_remote_cache_signal(:cache_delete, data, state) do
    key = Map.get(data, :key)
    true = :ets.delete(state.table, key)
    safe_remote_cache_log(state, :cache_delete, key, Map.get(data, :origin_node))
    state
  end

  defp apply_remote_cache_signal(_type, _data, state), do: state

  defp safe_remote_cache_log(state, type, key, origin) do
    try do
      Logger.debug(fn ->
        "BufferedStore remote cache event " <>
          inspect(%{collection: state.collection, type: type, key: key, origin: origin},
            limit: 20
          )
      end)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    :ok
  end

  defp reload_key_from_backend(%{backend: nil, table: table}, key) do
    # No backend — just delete the stale ETS entry
    :ets.delete(table, key)
  end

  defp reload_key_from_backend(
         %{backend: backend, backend_opts: backend_opts, collection: collection, table: table},
         key
       ) do
    opts = Keyword.merge(backend_opts, name: collection)

    case backend.get(key, opts) do
      {:ok, value} ->
        :ets.insert(table, {key, value})

      {:error, :not_found} ->
        :ets.delete(table, key)

      {:error, reason} ->
        Logger.warning(
          "BufferedStore[#{collection}]: failed to reload #{key}: #{inspect(reason)}"
        )
    end
  rescue
    e ->
      Logger.warning("BufferedStore[#{collection}]: reload error for #{key}: #{inspect(e)}")
  catch
    :exit, reason ->
      Logger.warning("BufferedStore[#{collection}]: reload exit for #{key}: #{inspect(reason)}")

    :throw, value ->
      Logger.warning("BufferedStore[#{collection}]: reload throw for #{key}: #{inspect(value)}")
  end

  defp subscribe_to_distributed_signals(collection) do
    bus = Arbor.Signals.Bus

    if Code.ensure_loaded?(bus) and Process.whereis(bus) do
      me = self()

      for type <- ~w(cache_put cache_delete) do
        Arbor.Signals.subscribe("persistence.#{type}", fn signal ->
          # Only forward if it's for our collection
          if Map.get(signal.data, :collection) == collection do
            send(me, {:signal_received, signal})
          end

          :ok
        end)
      end

      Logger.info("BufferedStore[#{collection}]: subscribed to distributed cache signals")
    end

    :ok
  catch
    _, _ -> :ok
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp store_name!(opts) do
    Keyword.fetch!(opts, :name)
  end

  defp authority_call(store, message, operation) when operation in [:read, :mutation] do
    # The configured backend owns its operation timeout. Returning early from
    # GenServer.call would be ambiguous: the queued/backend effect could still
    # commit after the caller observed a timeout error.
    case Process.whereis(store) do
      pid when is_pid(pid) -> GenServer.call(pid, message, :infinity)
      nil -> {:error, :store_unavailable}
    end
  rescue
    _ -> authority_call_failure(operation)
  catch
    :exit, _ -> authority_call_failure(operation)
    :throw, _ -> authority_call_failure(operation)
  end

  defp authority_call_failure(:read), do: {:error, :store_unavailable}
  defp authority_call_failure(:mutation), do: {:error, :outcome_unknown}

  defp ets_table!(opts) do
    # The ETS table name is the same as the GenServer name
    Keyword.fetch!(opts, :name)
  end

  defp get_numeric_field(%Record{data: data}, field) do
    get_numeric_value(Map.get(data, field) || Map.get(data, to_string(field)))
  end

  defp get_numeric_field(record, field) when is_map(record) do
    get_numeric_value(Map.get(record, field) || Map.get(record, to_string(field)))
  end

  defp get_numeric_value(nil), do: nil
  defp get_numeric_value(v) when is_number(v), do: v

  defp get_numeric_value(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp get_numeric_value(_), do: nil
end
