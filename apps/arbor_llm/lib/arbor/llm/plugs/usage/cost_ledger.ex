defmodule Arbor.LLM.Plugs.Usage.CostLedger do
  @moduledoc false

  @table __MODULE__
  @scale 1_000_000

  @type identity :: {:agent, String.t()} | {:key, String.t()} | {:unidentified, :global}

  @spec micros(identity()) :: non_neg_integer()
  def micros(identity) do
    case :ets.lookup(ensure_table(), identity) do
      [{^identity, value}] when is_integer(value) and value >= 0 -> value
      _ -> 0
    end
  end

  @spec add(identity(), number()) :: :ok
  def add(_identity, cost) when not is_number(cost) or cost <= 0, do: :ok

  def add(identity, cost) do
    amount = to_micros(cost)
    table = ensure_table()
    :ets.update_counter(table, identity, {2, amount}, {identity, 0})
    :ok
  rescue
    _ -> :ok
  end

  @spec to_micros(number()) :: non_neg_integer()
  def to_micros(cost) when is_number(cost) and cost >= 0, do: round(cost * @scale)
  def to_micros(_cost), do: 0

  @spec fingerprint(term()) :: String.t() | nil
  def fingerprint(key) when is_binary(key) and byte_size(key) > 0 do
    Base.encode16(:crypto.hash(:sha256, key), case: :lower)
  end

  def fingerprint(_key), do: nil

  @spec reset() :: :ok
  def reset do
    case :ets.whereis(@table) do
      :undefined ->
        :ok

      tid ->
        true = :ets.delete_all_objects(tid)
        :ok
    end
  end

  @spec ensure_table() :: :ets.table()
  def ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [
            :named_table,
            :public,
            :set,
            read_concurrency: true,
            write_concurrency: true
          ])
        rescue
          ArgumentError ->
            case :ets.whereis(@table) do
              :undefined ->
                raise "usage cost ledger missing after create race"

              tid ->
                tid
            end
        end

      tid ->
        tid
    end
  end
end
