defmodule Arbor.Persistence.Filter do
  @moduledoc """
  Composable query DSL for filtering, ordering, and paginating records.

  This module delegates to `Arbor.Contracts.Persistence.Filter`, the canonical
  implementation in contracts. Use that module directly for new code.

  All functions and types are re-exported for backward compatibility.
  """

  defdelegate new(), to: Arbor.Contracts.Persistence.Filter
  defdelegate where(filter, field, operator, value), to: Arbor.Contracts.Persistence.Filter
  defdelegate since(filter, dt), to: Arbor.Contracts.Persistence.Filter
  defdelegate until(filter, dt), to: Arbor.Contracts.Persistence.Filter
  defdelegate order_by(filter, field, direction \\ :asc), to: Arbor.Contracts.Persistence.Filter
  defdelegate limit(filter, n), to: Arbor.Contracts.Persistence.Filter
  defdelegate offset(filter, n), to: Arbor.Contracts.Persistence.Filter
  defdelegate matches?(filter, record), to: Arbor.Contracts.Persistence.Filter
  defdelegate apply(filter, records), to: Arbor.Contracts.Persistence.Filter
end
