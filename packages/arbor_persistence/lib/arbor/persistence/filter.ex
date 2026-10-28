defmodule Arbor.Persistence.Filter do
  @moduledoc "Composable queries using the selected exact persistence Filter contract."

  alias Arbor.Persistence.ContractProviders
  @type t :: struct()

  def new,
    do: ContractProviders.call(ContractProviders.current!(), :filter, :new, [])

  def where(filter, field, operator, value),
    do:
      ContractProviders.call(ContractProviders.current!(), :filter, :where, [
        filter,
        field,
        operator,
        value
      ])

  def since(filter, dt),
    do: ContractProviders.call(ContractProviders.current!(), :filter, :since, [filter, dt])

  def until(filter, dt),
    do: ContractProviders.call(ContractProviders.current!(), :filter, :until, [filter, dt])

  def order_by(filter, field, direction \\ :asc),
    do:
      ContractProviders.call(ContractProviders.current!(), :filter, :order_by, [
        filter,
        field,
        direction
      ])

  def limit(filter, n),
    do: ContractProviders.call(ContractProviders.current!(), :filter, :limit, [filter, n])

  def offset(filter, n),
    do: ContractProviders.call(ContractProviders.current!(), :filter, :offset, [filter, n])

  def matches?(filter, record),
    do: ContractProviders.call(ContractProviders.current!(), :filter, :matches?, [filter, record])

  def apply(filter, records),
    do: ContractProviders.call(ContractProviders.current!(), :filter, :apply, [filter, records])
end
