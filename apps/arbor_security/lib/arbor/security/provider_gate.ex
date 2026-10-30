defmodule Arbor.Security.ProviderGate do
  @moduledoc """
  Closed Security provider-root declaration.

  Active startup is owned by the `Arbor.KernelRuntime` facade. This module
  preserves Security's stable symbolic gate name and child-spec surface.
  """

  # JWT verification belongs to the optional caller-composed OIDC adapter.
  # Preserve this gate's stable child surface and existing HTTP root. Kernel
  # Runtime independently retains its full-profile HTTP provider admission.
  @roots [:req]

  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_opts) do
    Arbor.KernelRuntime.provider_gate_child_spec(__MODULE__, @roots)
  end
end
