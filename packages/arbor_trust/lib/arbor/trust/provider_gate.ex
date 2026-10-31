defmodule Arbor.Trust.ProviderGate do
  @moduledoc "Stable symbolic gate. Product runtime adapters own concrete provider roots; standalone omits the gate."
  alias Arbor.Trust.Runtime

  @spec child_spec(term()) :: Supervisor.child_spec() | :none | {:error, term()}
  def child_spec(_opts) do
    case Runtime.provider_gate_child_spec(__MODULE__, []) do
      {:ok, spec} -> spec
      other -> other
    end
  end
end
