defmodule Arbor.Memory.Index.PersistentWriter do
  @moduledoc false

  @callback store(String.t(), String.t(), [float()], map()) ::
              {:ok, String.t()} | {:error, term()}

  @callback store_batch_with_ids(String.t(), [{String.t(), [float()], map()}]) ::
              {:ok, [String.t()]} | {:error, term()}
end
