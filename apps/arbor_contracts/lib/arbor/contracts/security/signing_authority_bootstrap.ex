defmodule Arbor.Contracts.Security.SigningAuthorityBootstrap do
  @moduledoc """
  Opaque restart slot for claiming a caller-owned signing authority.

  The bearer `token` identifies broker-only state. It is not a signing
  authority itself and contains no private key, owner process, callback, or
  executable reference. Bootstrap values deliberately have no Jason encoder
  so they cannot enter checkpoints or JSON logs accidentally.
  """

  use TypedStruct

  alias Arbor.Contracts.Security.SigningAuthority.Validator
  alias Arbor.Types

  typedstruct enforce: true, opaque: true do
    @typedoc "Opaque signing-authority restart slot"

    field(:token, binary())
    field(:principal_id, Types.agent_id())
    field(:purpose, atom() | String.t())
  end

  @doc """
  Construct a bootstrap reference after validating its broker-issued fields.
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, atom()}
  def new(attrs) when is_list(attrs) or is_map(attrs) do
    token = Validator.get_attr(attrs, :token)
    principal_id = Validator.get_attr(attrs, :principal_id)
    purpose = Validator.get_attr(attrs, :purpose)

    with :ok <- Validator.validate_token(token),
         :ok <- Validator.validate_principal_id(principal_id),
         :ok <- Validator.validate_purpose(purpose) do
      {:ok,
       %__MODULE__{
         token: token,
         principal_id: principal_id,
         purpose: purpose
       }}
    end
  end

  def new(_), do: {:error, :invalid_attrs}

  @doc """
  Canonicalize any term into a validated bootstrap without raising.

  This protects broker calls from hostile struct-tagged partial maps, which
  otherwise match `%SigningAuthorityBootstrap{}` while omitting required keys.
  """
  @spec canonicalize(term()) :: {:ok, t()} | {:error, atom()}
  def canonicalize(%__MODULE__{} = bootstrap) do
    new(%{
      token: Map.get(bootstrap, :token),
      principal_id: Map.get(bootstrap, :principal_id),
      purpose: Map.get(bootstrap, :purpose)
    })
  end

  def canonicalize(attrs) when is_map(attrs) or is_list(attrs), do: new(attrs)
  def canonicalize(_), do: {:error, :invalid_bootstrap}
end

defimpl Inspect, for: Arbor.Contracts.Security.SigningAuthorityBootstrap do
  def inspect(%Arbor.Contracts.Security.SigningAuthorityBootstrap{} = bootstrap, opts) do
    details =
      Inspect.Algebra.concat([
        "principal_id: ",
        Inspect.Algebra.to_doc(Map.get(bootstrap, :principal_id), opts),
        ", purpose: ",
        Inspect.Algebra.to_doc(Map.get(bootstrap, :purpose), opts),
        ", token: [REDACTED]"
      ])

    Inspect.Algebra.concat([
      "#Arbor.Contracts.Security.SigningAuthorityBootstrap<",
      details,
      ">"
    ])
  end
end
