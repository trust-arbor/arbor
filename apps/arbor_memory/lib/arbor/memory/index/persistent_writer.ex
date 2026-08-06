defmodule Arbor.Memory.Index.PersistentWriter do
  @moduledoc """
  Legacy durable writer behaviour (pre-C3G2).

  Production Index paths now use `Arbor.Memory.StrictVectorSeam`. This module
  remains only for transitional documentation of the retired
  `store` / `store_batch_with_ids` callbacks.
  """

  @callback store(String.t(), String.t(), [float()], map()) ::
              {:ok, String.t()} | {:error, term()}

  @callback store_batch_with_ids(String.t(), [{String.t(), [float()], map()}]) ::
              {:ok, [String.t()]} | {:error, term()}
end
