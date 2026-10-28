defmodule Arbor.Persistence.Record do
  @moduledoc """
  Record constructors for the selected exact persistence contract.

  Standalone values use `Arbor.Persistence.Contracts.Record`. Hosts can select
  their original passive contract without changing stored struct identities.
  """

  alias Arbor.Persistence.ContractProviders
  @type t :: struct()

  def new(key, data \\ %{}, opts \\ []),
    do: ContractProviders.record_new(key, data, opts)

  def update(record, data, opts \\ []),
    do:
      ContractProviders.call(ContractProviders.current!(), :record, :update, [record, data, opts])
end
