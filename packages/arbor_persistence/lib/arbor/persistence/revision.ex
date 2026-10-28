defmodule Arbor.Persistence.Revision do
  @moduledoc false

  alias Arbor.Persistence.ContractProviders

  def key_mismatch?(key, value),
    do:
      ContractProviders.call(ContractProviders.current!(), :revision, :key_mismatch?, [key, value])

  def cas_operands_key_mismatch?(key, expected, replacement),
    do:
      ContractProviders.call(
        ContractProviders.current!(),
        :revision,
        :cas_operands_key_mismatch?,
        [key, expected, replacement]
      )

  def live_value(value),
    do: ContractProviders.call(ContractProviders.current!(), :revision, :live_value, [value])

  def live_record?(value),
    do: ContractProviders.call(ContractProviders.current!(), :revision, :live_record?, [value])

  def tombstone?(value),
    do: ContractProviders.call(ContractProviders.current!(), :revision, :tombstone?, [value])

  def to_tombstone(value),
    do: ContractProviders.call(ContractProviders.current!(), :revision, :to_tombstone, [value])

  def apply_put(current, value),
    do:
      ContractProviders.call(ContractProviders.current!(), :revision, :apply_put, [current, value])

  def advance_cas_insert(value),
    do:
      ContractProviders.call(ContractProviders.current!(), :revision, :advance_cas_insert, [value])

  def advance_ephemeral_insert(value),
    do:
      ContractProviders.call(ContractProviders.current!(), :revision, :advance_ephemeral_insert, [
        value
      ])

  def advance_cas_insert_from_tombstone(generation, value),
    do:
      ContractProviders.call(
        ContractProviders.current!(),
        :revision,
        :advance_cas_insert_from_tombstone,
        [generation, value]
      )

  def advance_cas_update(current, replacement),
    do:
      ContractProviders.call(ContractProviders.current!(), :revision, :advance_cas_update, [
        current,
        replacement
      ])

  def cas_matches?(current, expected),
    do:
      ContractProviders.call(ContractProviders.current!(), :revision, :cas_matches?, [
        current,
        expected
      ])

  def absent_for_cas?(value),
    do: ContractProviders.call(ContractProviders.current!(), :revision, :absent_for_cas?, [value])

  def authoritative_list_limit(opts),
    do:
      ContractProviders.call(ContractProviders.current!(), :revision, :authoritative_list_limit, [
        opts
      ])
end
