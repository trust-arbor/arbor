defmodule Arbor.Memory.Index.PersistentWriter do
  @moduledoc """
  Internal durable writer seam for the memory index.

  `store_batch_with_ids/2` is an all-or-nothing operation: an error result must
  leave no committed rows, and a successful result must describe the complete
  input batch in order.
  """

  @callback store(String.t(), String.t(), [float()], map()) ::
              {:ok, String.t()} | {:error, term()}

  @callback store_batch_with_ids(String.t(), [{String.t(), [float()], map()}]) ::
              {:ok, [String.t()]} | {:error, term()}
end
