defmodule Arbor.Persistence.Store.Revision do
  @moduledoc false

  # Shared helpers for structured Record identity, backend-owned generation +
  # revision fencing, and compare-and-swap matching. Not part of the public facade.
  #
  # Internal entry shapes for in-memory backends:
  #   %Record{} | {:tombstone, generation :: non_neg_integer()}
  # Non-Record values are stored as-is (no tombstone / no ABA protection).

  alias Arbor.Contracts.Persistence.Record

  @type entry :: Record.t() | {:tombstone, non_neg_integer()} | term()

  @doc false
  @spec key_mismatch?(String.t(), term()) :: boolean()
  def key_mismatch?(_store_key, value) when not is_struct(value, Record), do: false
  def key_mismatch?(store_key, %Record{key: key}), do: key != store_key

  # True when either CAS operand is a structured Record whose key differs from
  # the physical store key. Token equality alone must never authorize an update
  # when the expected Record was observed under another key.
  @doc false
  @spec cas_operands_key_mismatch?(String.t(), term(), term()) :: boolean()
  def cas_operands_key_mismatch?(store_key, expected, replacement) do
    key_mismatch?(store_key, replacement) or expected_key_mismatch?(store_key, expected)
  end

  defp expected_key_mismatch?(store_key, {:value, expected_value}),
    do: key_mismatch?(store_key, expected_value)

  defp expected_key_mismatch?(_store_key, _expected), do: false

  @doc false
  @spec live_value(entry() | :absent) :: {:ok, term()} | :not_found
  def live_value(:absent), do: :not_found
  def live_value({:tombstone, _gen}), do: :not_found
  def live_value(value), do: {:ok, value}

  @doc false
  @spec live_record?(entry()) :: boolean()
  def live_record?(%Record{}), do: true
  def live_record?(_), do: false

  @doc false
  @spec tombstone?(entry()) :: boolean()
  def tombstone?({:tombstone, _}), do: true
  def tombstone?(_), do: false

  @doc false
  @spec to_tombstone(entry()) :: entry() | :absent
  def to_tombstone(%Record{generation: gen})
      when is_integer(gen) and gen >= 0 do
    {:tombstone, gen}
  end

  def to_tombstone({:tombstone, _} = t), do: t
  def to_tombstone(_other), do: :absent

  @doc false
  @spec apply_put(entry() | :absent, term()) ::
          {:ok, entry()} | {:error, :key_mismatch}
  def apply_put(current, value) do
    case value do
      %Record{} = record ->
        do_apply_record(current, record)

      other ->
        {:ok, plain_put(current, other)}
    end
  end

  @doc false
  @spec advance_cas_insert(term()) :: term()
  def advance_cas_insert(%Record{} = record) do
    now = DateTime.utc_now()

    %{
      record
      | generation: 1,
        revision: 1,
        updated_at: now
    }
  end

  def advance_cas_insert(value), do: value

  @doc false
  @spec advance_cas_insert_from_tombstone(non_neg_integer(), term()) :: term()
  def advance_cas_insert_from_tombstone(prev_gen, %Record{} = record)
      when is_integer(prev_gen) and prev_gen >= 0 do
    now = DateTime.utc_now()

    %{
      record
      | generation: prev_gen + 1,
        revision: 1,
        updated_at: now
    }
  end

  def advance_cas_insert_from_tombstone(_prev_gen, value), do: value

  @doc false
  @spec advance_cas_update(Record.t(), term()) ::
          {:ok, Record.t()} | {:error, :key_mismatch | :conflict}
  def advance_cas_update(%Record{} = current, %Record{} = replacement) do
    if current.key != replacement.key do
      {:error, :key_mismatch}
    else
      now = DateTime.utc_now()

      stored = %{
        replacement
        | id: current.id,
          key: current.key,
          generation: current.generation,
          revision: current.revision + 1,
          inserted_at: current.inserted_at || replacement.inserted_at,
          updated_at: now
      }

      {:ok, stored}
    end
  end

  def advance_cas_update(_current, _replacement), do: {:error, :conflict}

  @doc false
  @spec cas_matches?(entry(), term()) :: boolean()
  def cas_matches?(%Record{} = current, %Record{} = expected) do
    current.generation == expected.generation and current.revision == expected.revision
  end

  def cas_matches?({:tombstone, _}, _expected), do: false
  def cas_matches?(current, expected), do: current == expected

  @doc false
  @spec absent_for_cas?(entry() | :absent) :: boolean()
  def absent_for_cas?(:absent), do: true
  def absent_for_cas?({:tombstone, _}), do: true
  def absent_for_cas?(_), do: false

  defp do_apply_record(:absent, %Record{} = record) do
    now = DateTime.utc_now()
    {:ok, %{record | generation: 1, revision: 1, updated_at: now}}
  end

  defp do_apply_record({:tombstone, prev_gen}, %Record{} = record)
       when is_integer(prev_gen) and prev_gen >= 0 do
    now = DateTime.utc_now()

    {:ok,
     %{
       record
       | generation: prev_gen + 1,
         revision: 1,
         updated_at: now
     }}
  end

  defp do_apply_record(%Record{} = current, %Record{} = record) do
    if current.key != record.key do
      {:error, :key_mismatch}
    else
      now = DateTime.utc_now()

      {:ok,
       %{
         record
         | id: current.id,
           key: current.key,
           generation: current.generation,
           revision: current.revision + 1,
           inserted_at: current.inserted_at || record.inserted_at,
           updated_at: now
       }}
    end
  end

  defp do_apply_record(_other, %Record{} = record) do
    # Replacing a plain value with a Record starts a fresh structured incarnation.
    now = DateTime.utc_now()
    {:ok, %{record | generation: 1, revision: 1, updated_at: now}}
  end

  defp plain_put(:absent, value), do: value
  defp plain_put({:tombstone, _}, value), do: value
  defp plain_put(_current, value), do: value
end
