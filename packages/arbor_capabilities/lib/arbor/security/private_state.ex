defmodule Arbor.Security.PrivateState do
  @moduledoc false

  @type handle :: %{private_state: :ets.tid()}

  @spec new(atom(), term(), term()) :: handle()
  def new(anchor, schema, value) when is_atom(schema) do
    table = :ets.new(__MODULE__, [:set, :private])
    true = :ets.insert(table, {schema, value})
    Process.put(anchor, table)
    %{private_state: table}
  end

  @spec fetch(term(), term(), atom(), (term() -> boolean())) ::
          {:ok, term()} | {:error, :invalid_private_state}
  def fetch(%{private_state: table}, anchor, schema, validator)
      when is_atom(schema) and is_function(validator, 1) do
    with ^table <- Process.get(anchor),
         true <- :ets.info(table, :owner) == self(),
         true <- :ets.info(table, :protection) == :private,
         1 <- :ets.info(table, :size),
         [{^schema, value}] <- :ets.lookup(table, schema),
         true <- validator.(value) do
      {:ok, value}
    else
      _ -> {:error, :invalid_private_state}
    end
  rescue
    ArgumentError -> {:error, :invalid_private_state}
  end

  def fetch(_state, _anchor, _schema, _validator), do: {:error, :invalid_private_state}

  @spec replace(term(), term(), atom(), term(), (term() -> boolean())) ::
          :ok | {:error, :invalid_private_state}
  def replace(handle, anchor, schema, value, validator)
      when is_atom(schema) and is_function(validator, 1) do
    with true <- validator.(value),
         {:ok, _old_value} <- fetch(handle, anchor, schema, validator),
         %{private_state: table} <- handle,
         true <- :ets.insert(table, {schema, value}) do
      :ok
    else
      _ -> {:error, :invalid_private_state}
    end
  rescue
    ArgumentError -> {:error, :invalid_private_state}
  end

  @spec delete(term(), term()) :: :ok
  def delete(%{private_state: table}, anchor) do
    if Process.get(anchor) == table and :ets.info(table, :owner) == self() do
      true = :ets.delete(table)
      Process.delete(anchor)
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  def delete(_state, _anchor), do: :ok
end
