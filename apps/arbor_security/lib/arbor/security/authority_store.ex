defmodule Arbor.Security.AuthorityStore do
  @moduledoc """
  Security-owned authority storage with a frozen backend configuration.

  The default backend is `Arbor.Security.Store.JSONFile`, whose durability is
  `:node_restart`. Passing `backend: nil` selects owner-private in-memory state
  with `:process_lifetime` durability. The in-memory mode makes no restart or
  distributed consistency claim.

  This process serializes access and bounds authoritative snapshots. Startup
  handoff is coherent when it is the exclusive owner of backend mutations.
  Writers bypassing this process may race inventory hydration; snapshot isolation
  against such writers is not claimed. Durable generation and revision semantics
  remain owned by the configured Store backend; ephemeral mode delegates those
  transitions to `Revision`.
  """

  use GenServer

  alias Arbor.Contracts.Persistence.{Record, Revision}
  alias Arbor.Security.Config
  alias Arbor.Security.Store.JSONFile

  @default_hydration_limit 10_000
  @required_callbacks [put: 3, get: 2, delete: 2, list: 1]
  @durability_classes [:volatile, :process_lifetime, :application_restart, :node_restart]

  @type expected :: :not_found | {:value, Record.t()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    with {:ok, name} <- fetch_name(opts) do
      GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def start_link(_opts), do: {:error, :invalid_options}

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    # Child id is the registered name, not the module. Several stores run under
    # one supervisor; a module id would collide. Ownership proofs equate
    # Process.whereis(name) with the child pid listed under that same id.
    name = Keyword.get(opts, :name, __MODULE__)

    %{
      id: name,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @spec authoritative_get(String.t(), keyword()) ::
          {:ok, Record.t()} | {:error, :not_found | atom()}
  def authoritative_get(key, opts),
    do: GenServer.call(store_name!(opts), {:authoritative_get, key})

  @spec authoritative_list(keyword()) :: {:ok, [String.t()]} | {:error, atom()}
  def authoritative_list(opts),
    do: GenServer.call(store_name!(opts), {:authoritative_list, nil})

  @spec authoritative_entries(keyword()) ::
          {:ok, [{String.t(), Record.t()}]} | {:error, atom()}
  def authoritative_entries(opts), do: GenServer.call(store_name!(opts), :authoritative_entries)

  @doc """
  Takes the validated startup entries, or a fresh complete bounded inventory.

  The startup set is handed off at most once. Later calls always perform a fresh
  complete read, as do first calls after any attempted owner mutation.
  """
  @spec take_hydrated_entries(keyword()) ::
          {:ok, [{String.t(), Record.t()}]} | {:error, atom()}
  def take_hydrated_entries(opts), do: GenServer.call(store_name!(opts), :take_hydrated_entries)

  @spec put(String.t(), Record.t(), keyword()) :: :ok | {:error, atom()}
  def put(key, value, opts), do: GenServer.call(store_name!(opts), {:put, key, value})

  @spec delete(String.t(), keyword()) :: :ok | {:error, atom()}
  def delete(key, opts), do: GenServer.call(store_name!(opts), {:delete, key})

  @spec acknowledged_put(String.t(), Record.t(), keyword()) ::
          {:ok, Record.t()} | {:error, atom()}
  def acknowledged_put(key, value, opts),
    do: GenServer.call(store_name!(opts), {:acknowledged_put, key, value})

  @spec acknowledged_delete(String.t(), keyword()) :: :ok | {:error, atom()}
  def acknowledged_delete(key, opts),
    do: GenServer.call(store_name!(opts), {:acknowledged_delete, key})

  @spec acknowledged_compare_and_swap(String.t(), expected(), Record.t(), keyword()) ::
          {:ok, Record.t()} | {:error, atom()}
  def acknowledged_compare_and_swap(key, expected, replacement, opts),
    do:
      GenServer.call(
        store_name!(opts),
        {:acknowledged_compare_and_swap, key, expected, replacement}
      )

  @spec acknowledged_compare_and_delete(String.t(), Record.t(), keyword()) ::
          :ok | {:error, atom()}
  def acknowledged_compare_and_delete(key, expected, opts),
    do: GenServer.call(store_name!(opts), {:acknowledged_compare_and_delete, key, expected})

  @spec hydration_status(keyword()) :: {:ok, map()}
  def hydration_status(opts), do: GenServer.call(store_name!(opts), :hydration_status)

  @spec durability_class(keyword()) ::
          :volatile | :process_lifetime | :application_restart | :node_restart | :unknown
  def durability_class(opts), do: GenServer.call(store_name!(opts), :durability_class)

  @impl GenServer
  def init(opts) do
    with {:ok, state} <- build_state(opts) do
      {:ok, hydrate(state)}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:hydration_status, _from, state) do
    {:reply, {:ok, state.hydration_status}, state}
  end

  def handle_call(:durability_class, _from, state) do
    {:reply, state.durability_class, state}
  end

  # Hydration diagnostics remain readable after failure, but every authoritative
  # read and mutation below is poison-gated so partial inventory cannot escape.
  def handle_call(request, from, state) do
    if poisoned?(state) do
      {:reply, {:error, :hydration_unavailable}, state}
    else
      handle_authoritative_call(request, from, state)
    end
  end

  defp handle_authoritative_call({:authoritative_get, key}, _from, state) do
    {:reply, get_record(state, key), state}
  end

  defp handle_authoritative_call({:authoritative_list, nil}, _from, state) do
    {:reply, list_records(state), state}
  end

  defp handle_authoritative_call(:authoritative_entries, _from, state) do
    {:reply, list_entries(state), state}
  end

  defp handle_authoritative_call(:take_hydrated_entries, _from, state) do
    case state.startup_entries do
      {:ready, entries} ->
        {:reply, {:ok, entries}, %{state | startup_entries: :refresh_required}}

      {:failed, reason} ->
        {:reply, {:error, reason}, state}

      :refresh_required ->
        {:reply, list_entries(state), state}
    end
  end

  defp handle_authoritative_call({:put, key, value}, _from, state) do
    state = invalidate_startup_entries(state)
    {reply, state} = do_put(state, key, value, false)
    {:reply, reply, state}
  end

  defp handle_authoritative_call({:delete, key}, _from, state) do
    state = invalidate_startup_entries(state)
    {reply, state} = do_delete(state, key, false)
    {:reply, reply, state}
  end

  defp handle_authoritative_call({:acknowledged_put, key, value}, _from, state) do
    state = invalidate_startup_entries(state)
    {reply, state} = do_put(state, key, value, true)
    {:reply, reply, state}
  end

  defp handle_authoritative_call({:acknowledged_delete, key}, _from, state) do
    state = invalidate_startup_entries(state)
    {reply, state} = do_delete(state, key, true)
    {:reply, reply, state}
  end

  defp handle_authoritative_call(
         {:acknowledged_compare_and_swap, key, expected, replacement},
         _from,
         state
       ) do
    state = invalidate_startup_entries(state)
    {reply, state} = do_compare_and_swap(state, key, expected, replacement)
    {:reply, reply, state}
  end

  defp handle_authoritative_call({:acknowledged_compare_and_delete, key, expected}, _from, state) do
    state = invalidate_startup_entries(state)
    {reply, state} = do_compare_and_delete(state, key, expected)
    {:reply, reply, state}
  end

  defp fetch_name(opts) do
    case Keyword.fetch(opts, :name) do
      {:ok, name} when is_atom(name) -> {:ok, name}
      {:ok, _invalid} -> {:error, :invalid_name}
      :error -> {:error, :name_required}
    end
  rescue
    _ -> {:error, :invalid_options}
  end

  defp store_name!(opts) do
    case fetch_name(opts) do
      {:ok, name} -> name
      {:error, reason} -> raise ArgumentError, "invalid AuthorityStore options: #{reason}"
    end
  end

  defp build_state(opts) do
    with {:ok, name} <- fetch_name(opts),
         {:ok, namespace} <- fetch_namespace(opts, name),
         {:ok, backend} <- fetch_backend(opts),
         :ok <- validate_backend(backend),
         {:ok, backend_opts} <- fetch_backend_opts(opts),
         {:ok, backend_opts} <- inject_jsonfile_root(backend, backend_opts),
         {:ok, hydration_limit} <- fetch_hydration_limit(opts),
         {:ok, durability_class} <- resolve_durability(backend, backend_opts, namespace) do
      {:ok,
       %{
         name: name,
         namespace: namespace,
         backend: backend,
         backend_opts: Keyword.put(backend_opts, :name, namespace),
         hydration_limit: hydration_limit,
         persistence_mode: if(is_nil(backend), do: :ephemeral, else: :durable),
         durability_class: durability_class,
         entries: %{},
         startup_entries: {:failed, :not_hydrated},
         hydration_status: hydration_status(:unavailable, 0, hydration_limit, :not_hydrated)
       }}
    end
  end

  defp fetch_namespace(opts, name) do
    namespace =
      Keyword.get(opts, :namespace, Keyword.get(opts, :collection, Atom.to_string(name)))

    if (is_binary(namespace) and byte_size(namespace) > 0) or
         (is_atom(namespace) and not is_nil(namespace)) do
      {:ok, namespace}
    else
      {:error, :invalid_namespace}
    end
  rescue
    _ -> {:error, :invalid_options}
  end

  defp fetch_backend(opts) do
    case Keyword.fetch(opts, :backend) do
      :error -> {:ok, JSONFile}
      {:ok, nil} -> {:ok, nil}
      {:ok, backend} when is_atom(backend) -> {:ok, backend}
      {:ok, _invalid} -> {:error, :invalid_backend}
    end
  rescue
    _ -> {:error, :invalid_options}
  end

  defp fetch_backend_opts(opts) do
    backend_opts = Keyword.get(opts, :backend_opts, [])

    if Keyword.keyword?(backend_opts),
      do: {:ok, backend_opts},
      else: {:error, :invalid_backend_opts}
  rescue
    _ -> {:error, :invalid_backend_opts}
  end

  defp inject_jsonfile_root(nil, backend_opts), do: {:ok, backend_opts}

  defp inject_jsonfile_root(backend, backend_opts) when backend != JSONFile,
    do: {:ok, backend_opts}

  defp inject_jsonfile_root(JSONFile, backend_opts) do
    case Keyword.get(backend_opts, :base_dir) do
      dir when is_binary(dir) and byte_size(dir) > 0 ->
        if Path.type(dir) == :absolute do
          {:ok, backend_opts}
        else
          # Relative legacy values are config aliases, not per-store roots.
          put_frozen_jsonfile_root(backend_opts)
        end

      _missing ->
        put_frozen_jsonfile_root(backend_opts)
    end
  end

  defp put_frozen_jsonfile_root(backend_opts) do
    case Config.authority_root() do
      {:ok, root} -> {:ok, Keyword.put(backend_opts, :base_dir, root)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp poisoned?(%{persistence_mode: :durable, hydration_status: %{status: :failed}}), do: true
  defp poisoned?(_state), do: false

  defp fetch_hydration_limit(opts) do
    case Keyword.get(opts, :hydration_limit, @default_hydration_limit) do
      limit when is_integer(limit) and limit > 0 ->
        {:ok, limit}

      _invalid ->
        {:error, :invalid_hydration_limit}
    end
  rescue
    _ -> {:error, :invalid_hydration_limit}
  end

  defp validate_backend(nil), do: :ok

  defp validate_backend(backend) do
    if Code.ensure_loaded?(backend) do
      case Enum.find(@required_callbacks, fn {fun, arity} ->
             not function_exported?(backend, fun, arity)
           end) do
        nil -> :ok
        {fun, arity} -> {:error, {:missing_backend_callback, fun, arity}}
      end
    else
      {:error, :backend_unavailable}
    end
  end

  defp resolve_durability(nil, _backend_opts, _namespace), do: {:ok, :process_lifetime}

  defp resolve_durability(backend, backend_opts, namespace) do
    if function_exported?(backend, :durability_class, 1) do
      case guarded_backend(fn ->
             backend.durability_class(Keyword.put(backend_opts, :name, namespace))
           end) do
        {:returned, class} when class in @durability_classes -> {:ok, class}
        {:returned, _malformed} -> {:error, :invalid_backend_response}
        :aborted -> {:error, :backend_unavailable}
      end
    else
      {:ok, :unknown}
    end
  end

  defp hydrate(%{backend: nil, hydration_limit: limit} = state) do
    %{
      state
      | startup_entries: {:ready, []},
        hydration_status: hydration_status(:ready, 0, limit, :ok)
    }
  end

  defp hydrate(state) do
    case list_entries(state) do
      {:ok, entries} ->
        %{
          state
          | startup_entries: {:ready, entries},
            hydration_status:
              hydration_status(:ready, length(entries), state.hydration_limit, :ok)
        }

      {:error, reason} ->
        %{
          state
          | startup_entries: {:failed, reason},
            hydration_status: hydration_status(:failed, 0, state.hydration_limit, reason)
        }
    end
  end

  defp invalidate_startup_entries(state), do: %{state | startup_entries: :refresh_required}

  defp hydration_status(status, loaded_count, limit, reason) do
    %{
      status: status,
      loaded_count: loaded_count,
      configured_limit: limit,
      reason: reason
    }
  end

  defp get_record(_state, key) when not is_binary(key), do: {:error, :invalid_key}

  defp get_record(%{backend: nil, entries: entries}, key) do
    entries
    |> Map.get(key, :absent)
    |> Revision.live_value()
    |> normalize_live_value(key)
  end

  defp get_record(state, key) do
    case guarded_backend(fn -> state.backend.get(key, state.backend_opts) end) do
      {:returned, {:ok, %Record{} = record}} -> validate_record(key, record)
      {:returned, {:ok, _malformed}} -> {:error, :invalid_backend_response}
      {:returned, {:error, :not_found}} -> {:error, :not_found}
      {:returned, {:error, _reason}} -> {:error, :backend_unavailable}
      {:returned, _malformed} -> {:error, :invalid_backend_response}
      :aborted -> {:error, :backend_unavailable}
    end
  end

  defp normalize_live_value({:ok, %Record{} = record}, key), do: validate_record(key, record)
  defp normalize_live_value({:ok, _malformed}, _key), do: {:error, :invalid_backend_response}
  defp normalize_live_value(:not_found, _key), do: {:error, :not_found}

  defp validate_record(key, %Record{} = record) do
    if Revision.key_mismatch?(key, record),
      do: {:error, :key_mismatch},
      else: {:ok, record}
  end

  defp list_records(%{backend: nil, entries: entries, hydration_limit: limit}) do
    entries
    |> Enum.reduce([], fn {key, entry}, acc ->
      if match?({:ok, %Record{}}, Revision.live_value(entry)), do: [key | acc], else: acc
    end)
    |> validate_keys(limit)
  end

  defp list_records(state), do: backend_list(state)

  defp list_entries(state) do
    with {:ok, keys} <- list_records(state),
         {:ok, entries} <- fetch_entries(state, keys) do
      {:ok, entries}
    end
  end

  defp backend_list(state) do
    case guarded_backend(fn -> call_bounded_list(state) end) do
      {:returned, {:ok, keys}} ->
        validate_keys(keys, state.hydration_limit)

      {:returned, {:error, :inventory_limit_exceeded}} ->
        {:error, :hydration_limit_exceeded}

      {:returned, {:error, :bounded_inventory_unsupported}} ->
        {:error, :bounded_inventory_unsupported}

      {:returned, {:error, _reason}} ->
        {:error, :backend_unavailable}

      {:returned, _malformed} ->
        {:error, :invalid_backend_response}

      :aborted ->
        {:error, :backend_unavailable}
    end
  end

  defp call_bounded_list(state) do
    cond do
      function_exported?(state.backend, :bounded_list, 2) ->
        state.backend.bounded_list(state.hydration_limit, state.backend_opts)

      state.hydration_limit <= @default_hydration_limit ->
        state.backend.list(
          Keyword.put(state.backend_opts, :authoritative_limit, state.hydration_limit)
        )

      true ->
        {:error, :bounded_inventory_unsupported}
    end
  end

  defp validate_keys(keys, limit), do: validate_keys(keys, limit, MapSet.new(), [], 0)

  defp validate_keys([], _limit, _seen, acc, _count), do: {:ok, Enum.sort(acc)}

  defp validate_keys([key | rest], limit, seen, acc, count) when is_binary(key) do
    cond do
      count >= limit ->
        {:error, :hydration_limit_exceeded}

      MapSet.member?(seen, key) ->
        {:error, :invalid_backend_response}

      true ->
        validate_keys(rest, limit, MapSet.put(seen, key), [key | acc], count + 1)
    end
  end

  defp validate_keys([_malformed | _rest], _limit, _seen, _acc, _count),
    do: {:error, :invalid_backend_response}

  defp validate_keys(_improper, _limit, _seen, _acc, _count),
    do: {:error, :invalid_backend_response}

  defp fetch_entries(state, keys) do
    Enum.reduce_while(keys, {:ok, []}, fn key, {:ok, acc} ->
      case get_record(state, key) do
        {:ok, record} -> {:cont, {:ok, [{key, record} | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  defp do_put(state, key, value, acknowledged?) do
    with :ok <- validate_mutation(key, value) do
      case state.persistence_mode do
        :ephemeral -> ephemeral_put(state, key, value, acknowledged?)
        :durable -> durable_put(state, key, value, acknowledged?)
      end
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp ephemeral_put(state, key, value, acknowledged?) do
    with :ok <- ensure_ephemeral_capacity(state, key),
         {:ok, stored} <- apply_ephemeral_put(state.entries, key, value) do
      state = %{state | entries: Map.put(state.entries, key, stored)}
      reply = if acknowledged?, do: {:ok, stored}, else: :ok
      {reply, state}
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp apply_ephemeral_put(entries, key, replacement) do
    case Map.fetch(entries, key) do
      {:ok, %Record{} = current} -> Revision.advance_cas_update(current, replacement)
      :error -> {:ok, Revision.advance_ephemeral_insert(replacement)}
    end
  end

  defp durable_put(state, key, value, acknowledged?) do
    case guarded_backend(fn -> state.backend.put(key, value, state.backend_opts) end) do
      {:returned, :ok} when acknowledged? ->
        case get_record(state, key) do
          {:ok, stored} -> {{:ok, stored}, state}
          {:error, _reason} -> {{:error, :outcome_unknown}, state}
        end

      {:returned, :ok} ->
        {:ok, state}

      {:returned, {:error, :key_mismatch}} ->
        {{:error, :key_mismatch}, state}

      {:returned, {:error, _reason}} when acknowledged? ->
        {{:error, :outcome_unknown}, state}

      {:returned, {:error, _reason}} ->
        {{:error, :backend_unavailable}, state}

      {:returned, _malformed} when acknowledged? ->
        {{:error, :outcome_unknown}, state}

      {:returned, _malformed} ->
        {{:error, :invalid_backend_response}, state}

      :aborted when acknowledged? ->
        {{:error, :outcome_unknown}, state}

      :aborted ->
        {{:error, :backend_unavailable}, state}
    end
  end

  defp do_delete(state, key, _acknowledged?) when not is_binary(key),
    do: {{:error, :invalid_key}, state}

  defp do_delete(%{persistence_mode: :ephemeral} = state, key, _acknowledged?) do
    {:ok, %{state | entries: Map.delete(state.entries, key)}}
  end

  defp do_delete(state, key, acknowledged?) do
    case guarded_backend(fn -> state.backend.delete(key, state.backend_opts) end) do
      {:returned, :ok} -> {:ok, state}
      {:returned, _other} when acknowledged? -> {{:error, :outcome_unknown}, state}
      {:returned, {:error, _reason}} -> {{:error, :backend_unavailable}, state}
      {:returned, _malformed} -> {{:error, :invalid_backend_response}, state}
      :aborted when acknowledged? -> {{:error, :outcome_unknown}, state}
      :aborted -> {{:error, :backend_unavailable}, state}
    end
  end

  defp do_compare_and_swap(state, key, expected, replacement) do
    with :ok <- validate_mutation(key, replacement),
         :ok <- validate_expected(key, expected) do
      case state.persistence_mode do
        :ephemeral -> ephemeral_compare_and_swap(state, key, expected, replacement)
        :durable -> durable_compare_and_swap(state, key, expected, replacement)
      end
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp ephemeral_compare_and_swap(state, key, expected, replacement) do
    current = Map.get(state.entries, key, :absent)

    with :ok <- ensure_ephemeral_capacity(state, key),
         {:ok, stored} <- ephemeral_cas(current, expected, replacement) do
      {{:ok, stored}, %{state | entries: Map.put(state.entries, key, stored)}}
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp ephemeral_cas(:absent, :not_found, replacement),
    do: {:ok, Revision.advance_ephemeral_insert(replacement)}

  defp ephemeral_cas(%Record{} = current, {:value, expected}, replacement) do
    if Revision.cas_matches?(current, expected),
      do: Revision.advance_cas_update(current, replacement),
      else: {:error, :conflict}
  end

  defp ephemeral_cas(_current, {:value, _expected}, _replacement), do: {:error, :conflict}
  defp ephemeral_cas(_current, :not_found, _replacement), do: {:error, :conflict}

  defp ensure_ephemeral_capacity(state, key) do
    if Map.has_key?(state.entries, key) or map_size(state.entries) < state.hydration_limit do
      :ok
    else
      {:error, :inventory_limit_exceeded}
    end
  end

  defp durable_compare_and_swap(state, key, expected, replacement) do
    if function_exported?(state.backend, :compare_and_swap, 4) do
      case guarded_backend(fn ->
             state.backend.compare_and_swap(key, expected, replacement, state.backend_opts)
           end) do
        {:returned, {:ok, %Record{} = stored}} ->
          case validate_record(key, stored) do
            {:ok, valid} -> {{:ok, valid}, state}
            {:error, _reason} -> {{:error, :outcome_unknown}, state}
          end

        {:returned, {:ok, _malformed}} ->
          {{:error, :outcome_unknown}, state}

        {:returned, {:error, :conflict}} ->
          {{:error, :conflict}, state}

        {:returned, {:error, :key_mismatch}} ->
          {{:error, :key_mismatch}, state}

        {:returned, _other} ->
          {{:error, :outcome_unknown}, state}

        :aborted ->
          {{:error, :outcome_unknown}, state}
      end
    else
      {{:error, :unsupported}, state}
    end
  end

  defp do_compare_and_delete(state, key, expected) do
    with :ok <- validate_expected_record(key, expected) do
      case state.persistence_mode do
        :ephemeral -> ephemeral_compare_and_delete(state, key, expected)
        :durable -> durable_compare_and_delete(state, key, expected)
      end
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp ephemeral_compare_and_delete(state, key, expected) do
    case Map.get(state.entries, key, :absent) do
      %Record{} = current ->
        if Revision.cas_matches?(current, expected) do
          {:ok, %{state | entries: Map.delete(state.entries, key)}}
        else
          {{:error, :conflict}, state}
        end

      _other ->
        {{:error, :conflict}, state}
    end
  end

  defp durable_compare_and_delete(state, key, expected) do
    if function_exported?(state.backend, :compare_and_delete, 3) do
      case guarded_backend(fn ->
             state.backend.compare_and_delete(key, expected, state.backend_opts)
           end) do
        {:returned, :ok} -> {:ok, state}
        {:returned, {:error, :conflict}} -> {{:error, :conflict}, state}
        {:returned, {:error, :key_mismatch}} -> {{:error, :key_mismatch}, state}
        {:returned, _other} -> {{:error, :outcome_unknown}, state}
        :aborted -> {{:error, :outcome_unknown}, state}
      end
    else
      {{:error, :unsupported}, state}
    end
  end

  defp validate_mutation(key, %Record{} = record) when is_binary(key) do
    if Revision.key_mismatch?(key, record), do: {:error, :key_mismatch}, else: :ok
  end

  defp validate_mutation(key, _record) when not is_binary(key), do: {:error, :invalid_key}
  defp validate_mutation(_key, _record), do: {:error, :unsupported_value}

  defp validate_expected(_key, :not_found), do: :ok

  defp validate_expected(key, {:value, %Record{} = record}),
    do: validate_expected_record(key, record)

  defp validate_expected(_key, _expected), do: {:error, :invalid_expected}

  defp validate_expected_record(key, %Record{} = record) when is_binary(key) do
    if Revision.key_mismatch?(key, record), do: {:error, :key_mismatch}, else: :ok
  end

  defp validate_expected_record(key, _record) when not is_binary(key), do: {:error, :invalid_key}
  defp validate_expected_record(_key, _record), do: {:error, :invalid_expected}

  defp guarded_backend(fun) do
    {:returned, fun.()}
  rescue
    _ -> :aborted
  catch
    _, _ -> :aborted
  end
end
