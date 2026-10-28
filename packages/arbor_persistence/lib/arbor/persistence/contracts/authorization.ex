defmodule Arbor.Persistence.Contracts.Authorization do
  @moduledoc "Authorization port for the generic persistence facade."

  @callback authorize(term(), String.t(), atom(), keyword()) ::
              {:ok, :authorized}
              | {:ok, :pending_approval, String.t()}
              | {:error, term()}
end
