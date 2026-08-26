defmodule Arbor.Security.ProviderGate do
  @moduledoc """
  Closed Security provider-root declaration.

  Active startup is owned by the `Arbor.KernelRuntime` facade. This module
  preserves Security's stable symbolic gate name and child-spec surface.
  """

  @roots [:joken, :joken_jwks, :req]

  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_opts) do
    Arbor.KernelRuntime.provider_gate_child_spec(__MODULE__, @roots)
  end
end
