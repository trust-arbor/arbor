defmodule Arbor.Common.ProcessPrivateState do
  @moduledoc """
  Keeps security-sensitive GenServer data outside replaceable callback state.

  The calling process owns a private ETS table whose exact table identifier is
  sealed in that process's dictionary. Callers identify the table with a
  module-local anchor and schema; no table handle needs to be retained in the
  GenServer state returned from a callback.

  This is intended for small, bounded credential maps. It protects ordinary
  `:sys.get_state/1` inspection and state-table substitution: transferring a
  prepopulated private table to the server does not change the sealed table
  selected by this module.
  """

  @seal_prefix {__MODULE__, :sealed}

  @type error :: {:error, :invalid_private_state}

  @doc "Creates one exact private value store for `anchor` in the calling process."
  @spec open(term(), atom(), term(), (term() -> boolean())) :: :ok | error()
  def open(anchor, schema, value, validator)
      when is_atom(schema) and is_function(validator, 1) do
    seal_key = seal_key(anchor)

    case Process.get(seal_key) do
      nil ->
        if validator.(value) do
          table = :ets.new(__MODULE__, [:set, :private])
          true = :ets.insert(table, {schema, value})
          Process.put(seal_key, table)
          :ok
        else
          {:error, :invalid_private_state}
        end

      _existing ->
        {:error, :invalid_private_state}
    end
  rescue
    _ -> {:error, :invalid_private_state}
  catch
    _, _ -> {:error, :invalid_private_state}
  end

  @doc "Reads the value from the exact private table sealed for `anchor`."
  @spec fetch(term(), atom(), (term() -> boolean())) :: {:ok, term()} | error()
  def fetch(anchor, schema, validator) when is_atom(schema) and is_function(validator, 1) do
    with {:ok, table} <- sealed_table(anchor),
         1 <- :ets.info(table, :size),
         [{^schema, value}] <- :ets.lookup(table, schema),
         true <- validator.(value) do
      {:ok, value}
    else
      _ -> {:error, :invalid_private_state}
    end
  rescue
    _ -> {:error, :invalid_private_state}
  catch
    _, _ -> {:error, :invalid_private_state}
  end

  @doc "Replaces the sealed value after validating both old and new values."
  @spec replace(term(), atom(), term(), (term() -> boolean())) :: :ok | error()
  def replace(anchor, schema, value, validator)
      when is_atom(schema) and is_function(validator, 1) do
    with true <- validator.(value),
         {:ok, _old_value} <- fetch(anchor, schema, validator),
         {:ok, table} <- sealed_table(anchor),
         true <- :ets.insert(table, {schema, value}) do
      :ok
    else
      _ -> {:error, :invalid_private_state}
    end
  rescue
    _ -> {:error, :invalid_private_state}
  catch
    _, _ -> {:error, :invalid_private_state}
  end

  @doc "Updates the sealed value inside the owning process."
  @spec update(term(), atom(), (term() -> term()), (term() -> boolean())) ::
          :ok | error()
  def update(anchor, schema, update_fun, validator)
      when is_atom(schema) and is_function(update_fun, 1) and is_function(validator, 1) do
    with {:ok, value} <- fetch(anchor, schema, validator) do
      replace(anchor, schema, update_fun.(value), validator)
    end
  rescue
    _ -> {:error, :invalid_private_state}
  catch
    _, _ -> {:error, :invalid_private_state}
  end

  @doc "Deletes the exact sealed table owned by the calling process."
  @spec close(term()) :: :ok
  def close(anchor) do
    seal_key = seal_key(anchor)

    case Process.get(seal_key) do
      table when is_reference(table) ->
        if exact_private_owner?(table), do: :ets.delete(table)
        Process.delete(seal_key)

      _ ->
        :ok
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp sealed_table(anchor) do
    case Process.get(seal_key(anchor)) do
      table when is_reference(table) ->
        if exact_private_owner?(table),
          do: {:ok, table},
          else: {:error, :invalid_private_state}

      _ ->
        {:error, :invalid_private_state}
    end
  end

  defp exact_private_owner?(table) do
    :ets.info(table, :owner) == self() and
      :ets.info(table, :protection) == :private and
      :ets.info(table, :type) == :set
  end

  defp seal_key(anchor), do: {@seal_prefix, anchor}
end
