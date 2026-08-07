defmodule Arbor.Memory.MutationAdmission.Lease do
  @moduledoc """
  Opaque root-lease handle returned by `Arbor.Memory.MutationAdmission.acquire/2`.

  Constructed only by a successful admission. Token is never logged.
  """

  @enforce_keys [:token, :agent_id, :admitted_gate_gen]
  defstruct [:token, :agent_id, :admitted_gate_gen]

  @type t :: %__MODULE__{
          token: binary(),
          agent_id: String.t(),
          admitted_gate_gen: pos_integer()
        }

  defimpl Inspect do
    def inspect(%{agent_id: agent_id, admitted_gate_gen: gen}, _opts) do
      "#MutationAdmission.Lease<agent=#{inspect(agent_id)} gen=#{gen} token=[REDACTED]>"
    end
  end
end
