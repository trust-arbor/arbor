defmodule Arbor.Contracts.Security.SigningAuthorityBootstrap do
  @moduledoc """
  Opaque restart slot for claiming a caller-owned signing authority.

  The bearer `token` identifies broker-only state. It is not a signing
  authority itself and contains no private key, owner process, callback, or
  executable reference. Bootstrap values deliberately have no Jason encoder
  so they cannot enter checkpoints or JSON logs accidentally.

  Redaction applies to genuine bootstrap structs. A caller that forges an
  ordinary map containing copied credential fields controls that map's
  inspection behavior and must not log it. Security facade and broker
  diagnostics never inspect raw credential arguments.
  """

  use TypedStruct

  alias Arbor.Contracts.Security.SigningAuthority.Validator

  typedstruct enforce: true, opaque: true do
    @typedoc "Opaque signing-authority restart slot"

    field(:token, binary())
    field(:principal_id, Validator.principal_id())
    field(:purpose, atom() | String.t())
  end

  @doc """
  Construct a bootstrap reference after validating its broker-issued fields.
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, atom()}
  def new(attrs) when is_list(attrs) or is_map(attrs) do
    with {:ok, normalized} <-
           Validator.extract_attributes(attrs, [:token, :principal_id, :purpose]),
         token = Map.get(normalized, :token),
         principal_id = Map.get(normalized, :principal_id),
         purpose = Map.get(normalized, :purpose),
         :ok <- Validator.validate_token(token),
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
