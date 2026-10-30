defmodule Arbor.Security.Store.BoundedInventory do
  @moduledoc """
  Optional Security-local backend operation for bounded authority inventory.

  Implementations must reject inventories larger than the positive owner-supplied
  limit before record hydration or migration and return only complete live-key
  inventories. This does not widen the shared persistence Store contract.
  """

  @callback bounded_list(pos_integer(), keyword()) ::
              {:ok, [String.t()]} | {:error, atom() | tuple()}
end
