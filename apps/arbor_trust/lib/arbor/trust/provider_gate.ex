defmodule Arbor.Trust.ProviderGate do
  @moduledoc """
  Closed Trust provider-root declaration.

  Active startup is owned by the `Arbor.KernelRuntime` facade. This module
  preserves Trust's stable symbolic gate name and child-spec surface.
  """

  @roots [:arbor_persistence, :phoenix_pubsub]

  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_opts) do
    Arbor.KernelRuntime.provider_gate_child_spec(__MODULE__, @roots)
  end
end
