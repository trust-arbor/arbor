defmodule Arbor.KernelRuntime do
  @moduledoc """
  Boundary owner for the active kernel runtime application.

  Runtime services remain in their stable public namespaces. This root owns
  only the application callback namespace and declares the service
  boundaries it composes plus the contracts it consumes. The public
  safe-management surface is `Arbor.KernelRuntime.SafeManagementSurface`.
  The VM-lifetime boot-profile snapshot is `boot_profile/0`.
  """

  use Boundary,
    top_level?: true,
    deps: [Arbor.Common, Arbor.Contracts, Arbor.Signals, Arbor.Monitor, Logger],
    exports: [SafeManagementSurface]

  alias Arbor.KernelRuntime.BootProfileBinding

  @doc """
  Returns the immutable VM-lifetime boot-profile snapshot.

  The map is closed plain data. It does not include process tokens,
  verifier input, private keys, or internal slot state. This read does
  not invoke Envelope; each fetch validates the bounded table and
  snapshot. Returns `{:error, :not_bound}` when the binding owner is
  not live or bounded admission fails.
  """
  @spec boot_profile() :: {:ok, map()} | {:error, :not_bound}
  def boot_profile, do: BootProfileBinding.snapshot()
end
