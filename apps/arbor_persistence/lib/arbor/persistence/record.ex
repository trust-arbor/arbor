defmodule Arbor.Persistence.Record do
  @moduledoc """
  A structured record for queryable storage backends.

  This module delegates to `Arbor.Contracts.Persistence.Record`, the canonical
  implementation in contracts. Use that module directly for new code.

  All functions and types are re-exported for backward compatibility.
  """

  defdelegate new(key, data \\ %{}, opts \\ []), to: Arbor.Contracts.Persistence.Record
  defdelegate update(record, data, opts \\ []), to: Arbor.Contracts.Persistence.Record
end
