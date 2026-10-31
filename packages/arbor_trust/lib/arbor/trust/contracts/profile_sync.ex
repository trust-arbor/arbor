defmodule Arbor.Trust.Contracts.ProfileSync do
  @moduledoc "Authority-sensitive cache invalidation. Configured transport failure prevents Store startup; nil explicitly selects single-node ownership. Transport implementations own subscription lifetime. Errors may expose underlying transport failure reasons."
  @callback subscribe(pid()) :: :ok | {:error, term()}
  @callback broadcast(atom(), map()) :: :ok | {:ok, term()} | {:error, term()}
end
