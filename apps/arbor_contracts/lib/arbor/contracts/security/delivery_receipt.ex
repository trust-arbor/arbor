defmodule Arbor.Contracts.Security.DeliveryReceipt do
  @moduledoc """
  Opaque one-use authorization delivery receipt.

  The bearer `token` identifies a Security-owned broker entry. Constructing this
  shape confers **no** authority — only a live broker binding does. The receipt
  deliberately carries no principal, resource, action, session token, capability,
  route, metadata, timestamp, node, or authority field.

  Values deliberately have no Jason encoder so they cannot enter checkpoints or
  JSON logs accidentally. Redaction applies to genuine receipt structs.
  """

  use TypedStruct

  alias Arbor.Contracts.Security.SigningAuthority.Validator

  @token_bytes 32

  typedstruct enforce: true, opaque: true do
    @typedoc "Opaque one-use delivery receipt"

    field(:token, binary())
  end

  @doc """
  Construct a delivery receipt after validating its single closed field.
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, atom()}
  def new(attrs) when is_list(attrs) or is_map(attrs) do
    with {:ok, normalized} <- Validator.extract_attributes(attrs, [:token]),
         token = Map.get(normalized, :token),
         :ok <- validate_token(token) do
      {:ok, %__MODULE__{token: token}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def new(_), do: {:error, :invalid_attrs}

  @doc """
  Canonicalize any term into a validated receipt without raising.

  Re-validates through `new/1` so a forged struct tag cannot bypass the
  one-field closed shape.
  """
  @spec canonicalize(term()) :: {:ok, t()} | {:error, atom()}
  def canonicalize(%__MODULE__{} = receipt) do
    new(%{token: Map.get(receipt, :token)})
  end

  def canonicalize(attrs) when is_map(attrs) or is_list(attrs), do: new(attrs)
  def canonicalize(_), do: {:error, :invalid_receipt}

  defp validate_token(token) when is_binary(token) and byte_size(token) == @token_bytes do
    if token == :binary.copy(<<0>>, @token_bytes) do
      {:error, :zero_token}
    else
      :ok
    end
  end

  defp validate_token(token) when is_binary(token), do: {:error, :token_wrong_size}
  defp validate_token(_), do: {:error, :invalid_token}
end

defimpl Inspect, for: Arbor.Contracts.Security.DeliveryReceipt do
  def inspect(%Arbor.Contracts.Security.DeliveryReceipt{}, _opts) do
    "#Arbor.Contracts.Security.DeliveryReceipt<token: [REDACTED]>"
  end
end
