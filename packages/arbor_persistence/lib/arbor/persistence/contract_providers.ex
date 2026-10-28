defmodule Arbor.Persistence.ContractProviders do
  @moduledoc """
  Exact contract identities selected by the composing application.

  Standalone consumers use package-owned contracts. A host may select one complete
  trusted provider set with `:contract_modules`. Bindings are captured before
  effects and storage owners pin them for their lifetime. No caller option can
  replace that binding, and foreign structs are never converted automatically.
  """

  alias Arbor.Persistence.Contracts

  @binding_key {__MODULE__, :owner_binding}
  @owners_key {__MODULE__, :owner_references}
  @tables_key {__MODULE__, :owner_tables}
  @owned_table_key {__MODULE__, :owned_table}
  @deadline_key {__MODULE__, :call_deadline}
  @defaults %{
    record: Contracts.Record,
    revision: Contracts.Revision,
    filter: Contracts.Filter,
    append_operation: Contracts.AppendOperation
  }
  @fields %{
    record: [:id, :key, :data, :metadata, :generation, :revision, :inserted_at, :updated_at],
    filter: [:conditions, :since, :until, :order_by, :limit, :offset],
    append_operation: [:operation_id, :stream_id, :event_ids, :fingerprints]
  }
  @callbacks %{
    record: [__struct__: 0, new: 1, new: 2, new: 3, update: 2, update: 3],
    filter: [
      __struct__: 0,
      new: 0,
      where: 4,
      since: 2,
      until: 2,
      order_by: 2,
      order_by: 3,
      limit: 2,
      offset: 2,
      matches?: 2,
      apply: 2
    ],
    append_operation: [__struct__: 0, new: 1],
    revision: [
      key_mismatch?: 2,
      cas_operands_key_mismatch?: 3,
      live_value: 1,
      live_record?: 1,
      tombstone?: 1,
      to_tombstone: 1,
      apply_put: 2,
      advance_cas_insert: 1,
      advance_ephemeral_insert: 1,
      advance_cas_insert_from_tombstone: 2,
      advance_cas_update: 2,
      cas_matches?: 2,
      absent_for_cas?: 1,
      authoritative_list_limit: 1
    ]
  }

  @type t :: %{
          record: module(),
          revision: module(),
          filter: module(),
          append_operation: module()
        }

  @spec capture() :: {:ok, t()} | {:error, :invalid_contract_provider}
  def capture do
    selected = Application.get_env(:arbor_persistence, :contract_modules, @defaults)

    if valid_bindings?(selected) do
      {:ok, selected}
    else
      {:error, :invalid_contract_provider}
    end
  rescue
    _ -> {:error, :invalid_contract_provider}
  catch
    _, _ -> {:error, :invalid_contract_provider}
  end

  @spec capture!() :: t()
  def capture! do
    case capture() do
      {:ok, bindings} ->
        bindings

      {:error, reason} ->
        raise ArgumentError, "invalid persistence contract configuration: #{reason}"
    end
  end

  @doc false
  @spec pin!() :: t()
  def pin! do
    bindings = capture!()
    Process.put(@binding_key, bindings)
    bindings
  end

  @doc false
  @spec current!() :: t()
  def current! do
    case Process.get(@binding_key) do
      nil -> capture!()
      bindings -> bindings
    end
  end

  @doc false
  def with_bindings(bindings, fun) when is_map(bindings) and is_function(fun, 0) do
    unless valid_bindings?(bindings),
      do: raise(ArgumentError, "invalid persistence contract binding")

    previous = Process.get(@binding_key)
    Process.put(@binding_key, bindings)

    try do
      fun.()
    after
      if is_nil(previous),
        do: Process.delete(@binding_key),
        else: Process.put(@binding_key, previous)
    end
  end

  @doc false
  def with_store(opts, fun, mode \\ :ordinary) do
    with_deadline(mode, fn ->
      name = Keyword.fetch!(opts, :name)

      with_store_owner(name, resolve_owner(name), fun, mode)
    end)
  end

  @doc false
  def with_agent(opts, fun) do
    with_deadline(:ordinary, fn ->
      name = Keyword.fetch!(opts, :name)

      case resolve_owner(name) do
        nil ->
          fun.()

        owner ->
          bindings =
            if owner == self(),
              do: current!(),
              else: Agent.get(owner, fn _state -> current!() end, call_timeout())

          with_owner(name, owner, nil, fn -> with_bindings(bindings, fun) end)
      end
    end)
  end

  @doc false
  def owner_ref(name), do: Process.get(@owners_key, %{}) |> Map.get(name, name)

  @doc false
  def resolve_owner(name) do
    case owner_ref(name) do
      owner when is_pid(owner) -> owner
      server -> GenServer.whereis(server)
    end
  end

  @doc false
  def table_ref(name), do: Process.get(@tables_key, %{}) |> Map.get(name, name)

  @doc false
  def register_table(table) do
    table = if is_atom(table), do: :ets.whereis(table), else: table
    true = is_reference(table) and :ets.info(table, :owner) == self()
    Process.put(@owned_table_key, table)
    :ok
  end

  @doc false
  def server_call(server, message), do: GenServer.call(server, message, call_timeout())
  def server_call(server, message, timeout), do: GenServer.call(server, message, timeout)

  @doc false
  def agent_get(server, fun), do: Agent.get(server, fun, call_timeout())
  def agent_get(server, fun, timeout), do: Agent.get(server, fun, timeout)

  @doc false
  def agent_update(server, fun), do: Agent.update(server, fun, call_timeout())
  def agent_update(server, fun, timeout), do: Agent.update(server, fun, timeout)

  @doc false
  def agent_get_and_update(server, fun), do: Agent.get_and_update(server, fun, call_timeout())
  def agent_get_and_update(server, fun, timeout), do: Agent.get_and_update(server, fun, timeout)

  defp call_timeout do
    case Process.get(@deadline_key) do
      nil -> 5_000
      :infinity -> :infinity
      deadline -> max(deadline - System.monotonic_time(:millisecond), 0)
    end
  end

  defp with_deadline(mode, fun) do
    previous = Process.get(@deadline_key)

    proposed =
      if mode == :ordinary, do: System.monotonic_time(:millisecond) + 5_000, else: :infinity

    deadline =
      case {previous, proposed} do
        {value, :infinity} when is_integer(value) -> value
        {value, proposed} when is_integer(value) and is_integer(proposed) -> min(value, proposed)
        _ -> proposed
      end

    Process.put(@deadline_key, deadline)

    try do
      fun.()
    after
      if is_nil(previous),
        do: Process.delete(@deadline_key),
        else: Process.put(@deadline_key, previous)
    end
  end

  defp with_store_owner(_name, nil, fun, _mode), do: fun.()

  defp with_store_owner(name, owner, fun, mode) do
    case owner_context(owner, mode) do
      {:ok, %{contracts: bindings, table: table}} ->
        with_owner(name, owner, table, fn -> with_bindings(bindings, fun) end)

      {:error, _} = error ->
        error
    end
  end

  defp owner_context(owner, mode) do
    context =
      if owner == self(),
        do: %{contracts: current!(), table: Process.get(@owned_table_key)},
        else: GenServer.call(owner, :contract_context, call_timeout())

    %{contracts: bindings, table: table} = context

    if valid_bindings?(bindings) and is_reference(table) and :ets.info(table, :owner) == owner,
      do: {:ok, context},
      else: raise(ArgumentError, "invalid persistence owner context")
  rescue
    error -> context_failure(mode, :error, error, __STACKTRACE__)
  catch
    kind, reason -> context_failure(mode, kind, reason, __STACKTRACE__)
  end

  defp context_failure(:read, _kind, _reason, _stack), do: {:error, :store_unavailable}
  defp context_failure(:mutation, _kind, _reason, _stack), do: {:error, :outcome_unknown}
  defp context_failure(:ordinary, kind, reason, stack), do: :erlang.raise(kind, reason, stack)

  @spec record?(term(), t()) :: boolean()
  def record?(value, bindings \\ current!()), do: is_struct(value, bindings.record)

  @spec filter?(term(), t()) :: boolean()
  def filter?(value, bindings \\ current!()), do: is_struct(value, bindings.filter)

  @spec append_operation?(term(), t()) :: boolean()
  def append_operation?(value, bindings \\ current!()),
    do: is_struct(value, bindings.append_operation)

  @spec call(t(), atom(), atom(), list()) :: term()
  def call(bindings, kind, function, args),
    do: apply(Map.fetch!(bindings, kind), function, args)

  @spec record_new(String.t(), map(), keyword(), t()) :: struct()
  def record_new(key, data \\ %{}, opts \\ [], bindings \\ current!()),
    do: call(bindings, :record, :new, [key, data, opts])

  @spec record_struct(map() | keyword(), t()) :: struct()
  def record_struct(fields, bindings \\ current!()), do: struct!(bindings.record, fields)

  @spec append_operation_new(map() | keyword(), t()) :: term()
  def append_operation_new(attrs, bindings \\ current!()),
    do: call(bindings, :append_operation, :new, [attrs])

  defp valid_provider?(provider, callbacks, fields) do
    is_atom(provider) and provider not in [nil, true, false] and
      Code.ensure_loaded?(provider) and
      Enum.all?(callbacks, fn {name, arity} -> function_exported?(provider, name, arity) end) and
      valid_struct?(provider, fields)
  end

  defp valid_struct?(_provider, nil), do: true

  defp valid_struct?(provider, fields) do
    value = apply(provider, :__struct__, [])
    is_struct(value, provider) and Enum.all?(fields, &Map.has_key?(value, &1))
  end

  defp valid_bindings?(selected) do
    is_map(selected) and map_size(selected) == map_size(@defaults) and
      Enum.all?(@callbacks, fn {kind, callbacks} ->
        valid_provider?(Map.get(selected, kind), callbacks, Map.get(@fields, kind))
      end)
  end

  defp with_owner(name, owner, table, fun) do
    owners = Process.get(@owners_key, %{})
    tables = Process.get(@tables_key, %{})
    Process.put(@owners_key, Map.put(owners, name, owner))
    if table, do: Process.put(@tables_key, Map.put(tables, name, table))

    try do
      fun.()
    after
      if map_size(owners) == 0,
        do: Process.delete(@owners_key),
        else: Process.put(@owners_key, owners)

      if map_size(tables) == 0,
        do: Process.delete(@tables_key),
        else: Process.put(@tables_key, tables)
    end
  end
end
