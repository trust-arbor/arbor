defmodule Arbor.Security.Contracts.PrivateMemoryAdmission do
  @moduledoc false
  use TypedStruct

  typedstruct enforce: true do
    field(:token, binary())
  end

  def new(token) when is_binary(token) and byte_size(token) == 32,
    do: {:ok, %__MODULE__{token: token}}

  def new(_), do: {:error, :invalid_memory_admission}

  def token(%__MODULE__{token: token} = admission)
      when map_size(admission) == 2 and is_binary(token) and byte_size(token) == 32,
      do: {:ok, token}

  def token(_), do: {:error, :invalid_memory_admission}
end

defimpl Inspect, for: Arbor.Security.Contracts.PrivateMemoryAdmission do
  def inspect(_, _), do: "#Arbor.Security.PrivateMemoryAdmission<[REDACTED]>"
end
