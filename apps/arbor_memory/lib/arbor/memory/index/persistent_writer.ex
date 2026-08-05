defmodule Arbor.Memory.Index.PersistentWriter do
  @moduledoc """
  Internal durable writer seam for the memory index.

  `store_batch_with_ids/2` must execute one atomic durable transaction, so a
  database or pre-commit error cannot leave a committed prefix. A successful
  result describes the complete input batch in order.

  An exception, exit, or transport failure can lose the commit acknowledgement.
  In that case the caller cannot distinguish a whole-batch commit from absence;
  it must never infer that no rows committed. Implementations therefore use the
  supplied stable IDs and idempotent upsert semantics so retry converges either
  outcome without creating a partial or duplicate batch.
  """

  @callback store(String.t(), String.t(), [float()], map()) ::
              {:ok, String.t()} | {:error, term()}

  @callback store_batch_with_ids(String.t(), [{String.t(), [float()], map()}]) ::
              {:ok, [String.t()]} | {:error, term()}
end
