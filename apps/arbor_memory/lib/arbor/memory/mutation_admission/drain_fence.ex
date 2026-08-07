defmodule Arbor.Memory.MutationAdmission.DrainFence do
  @moduledoc """
  Opaque drain fence returned by `Arbor.Memory.MutationAdmission.drain/2`.

  Constructed only by a successful zero-root fence issuance. Token is never logged.
  """

  @enforce_keys [:token, :agent_id, :fence_generation]
  defstruct [:token, :agent_id, :fence_generation]

  @type t :: %__MODULE__{
          token: binary(),
          agent_id: String.t(),
          fence_generation: pos_integer()
        }

  defimpl Inspect do
    def inspect(%{agent_id: agent_id, fence_generation: gen}, _opts) do
      "#MutationAdmission.DrainFence<agent=#{inspect(agent_id)} gen=#{gen} token=[REDACTED]>"
    end
  end
end
