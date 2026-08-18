defmodule Arbor.KernelRuntime do
  @moduledoc """
  Boundary owner for the active kernel runtime application.

  Runtime services remain in their stable public namespaces. This root owns
  only the application callback namespace and declares the service
  boundaries it composes plus the contracts it consumes. The public
  safe-management surface is `Arbor.KernelRuntime.SafeManagementSurface`.
  """

  use Boundary,
    top_level?: true,
    deps: [Arbor.Common, Arbor.Contracts, Arbor.Signals, Arbor.Monitor],
    exports: [SafeManagementSurface]
end
