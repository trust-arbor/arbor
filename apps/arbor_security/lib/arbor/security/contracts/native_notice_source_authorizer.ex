defmodule Arbor.Security.Contracts.NativeNoticeSourceAuthorizer do
  @moduledoc """
  Deployment-owned native source eligibility port.

  Acquisition runs outside the receipt broker, after the source's parent has
  acknowledged startup. The adapter must verify actual fixed native child
  topology and durable mailbox configuration. Rechecks must use actor-independent
  authority reads; they must never call a source or ancestor supervisor.

  These callbacks are trusted compiled deployment code. External parameters,
  cryptographic key possession, process dictionaries, Registry metadata and
  caller-supplied purpose labels do not provision native source roles.
  """
  @callback acquire(String.t(), pid()) :: {:ok, map()} | {:error, atom()}
  @callback recheck(map(), map(), map() | nil) :: :ok | {:error, atom()}
end
