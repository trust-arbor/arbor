defmodule Arbor.Security.ProviderGate do
  @moduledoc """
  Closed Security provider-root declaration.

  The configured runtime host owns active HTTP startup. This module preserves
  Security's stable symbolic gate name and child-spec surface. Standalone
  Capabilities starts its authority tree without a host provider gate.
  """

  alias Arbor.Security.Runtime

  @roots [:req]

  @spec child_spec(term()) :: Supervisor.child_spec() | {:error, term()}
  def child_spec(_opts) do
    case prepare_child_spec() do
      {:ok, spec} -> spec
      :none -> {:error, :runtime_host_unavailable}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec prepare_child_spec() ::
          :none | {:ok, Supervisor.child_spec()} | {:error, term()}
  def prepare_child_spec do
    Runtime.provider_gate_child_spec(__MODULE__, @roots)
  end
end
