defmodule Arbor.Contracts.Security.SigningAuthority do
  @moduledoc """
  Opaque signing-authority reference shared across library APIs.

  Callers retain this value instead of a signer closure or a decrypted private
  key. The bearer `token` is unguessable authority material owned by
  `Arbor.Security`'s signing-authority broker; verification and key use always
  go through named Security facade operations.

  ## Invariants

  - **No raw key** — private material never appears in this struct
  - **No PID / function / MFA** — reload-stable across module purges
  - **No Jason derive** — must not serialize into checkpoints or JSON logs
  - **Redacted Inspect** — normal inspection never prints the token

  ## Usage

  Acquisition requires a one-shot SignedRequest possession proof — knowing an
  `agent_id` alone is never enough:

      {:ok, proof} =
        Arbor.Security.build_signing_authority_acquisition_proof(
          agent_id,
          private_key,
          purpose: :session,
          owner: self()
        )

      {:ok, authority} = Arbor.Security.open_signing_authority(proof)
      {:ok, signed} = Arbor.Security.sign_with_authority(authority, payload)
  """

  use TypedStruct

  alias Arbor.Types

  @token_min_bytes 16

  typedstruct enforce: true do
    @typedoc "Opaque signing-authority reference (broker bearer token + principal binding)"

    # Unguessable broker token. Treated as secret bearer authority.
    field(:token, binary())
    # Principal this authority was opened for. Broker re-checks on every use.
    field(:principal_id, Types.agent_id())
    # Open-time purpose label (session, heartbeat, …). Not a derive domain.
    field(:purpose, atom() | String.t())
  end

  @doc """
  Construct a signing-authority reference after validation.

  Prefer `Arbor.Security.open_signing_authority/1` (possession proof) for
  production use — this factory only validates shape for callers that already
  hold broker-issued fields (or tests constructing fixtures).

  ## Options

  - `:token` (required) — unguessable bearer token (≥ 16 bytes)
  - `:principal_id` (required) — agent id the authority binds to
  - `:purpose` (required) — open-time purpose atom or non-blank string
    (booleans and blank/whitespace-only strings are rejected)
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs) or is_map(attrs) do
    token = get_attr(attrs, :token)
    principal_id = get_attr(attrs, :principal_id)
    purpose = get_attr(attrs, :purpose)

    with :ok <- validate_token(token),
         :ok <- validate_principal_id(principal_id),
         :ok <- validate_purpose(purpose) do
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
  Canonicalize any term into a validated `%SigningAuthority{}` without raising.

  Struct-tagged partial/forged maps match `%SigningAuthority{}` in pattern
  matching but may omit required fields. Field access on those maps can raise
  `KeyError` and, if forwarded into the broker, can crash a GenServer call.
  This helper always extracts fields via `Map.get/2` and re-validates through
  `new/1` so callers get a shaped `{:error, reason}` instead.
  """
  @spec canonicalize(term()) :: {:ok, t()} | {:error, term()}
  def canonicalize(%__MODULE__{} = authority) do
    new(%{
      token: Map.get(authority, :token),
      principal_id: Map.get(authority, :principal_id),
      purpose: Map.get(authority, :purpose)
    })
  end

  def canonicalize(attrs) when is_map(attrs) or is_list(attrs), do: new(attrs)
  def canonicalize(_), do: {:error, :invalid_authority}

  @doc """
  Returns true when `value` is a `%SigningAuthority{}` struct.
  """
  @spec signing_authority?(term()) :: boolean()
  def signing_authority?(%__MODULE__{}), do: true
  def signing_authority?(_), do: false

  # ---------------------------------------------------------------------------
  # Private validation
  # ---------------------------------------------------------------------------

  defp get_attr(attrs, key) when is_list(attrs), do: Keyword.get(attrs, key)

  defp get_attr(attrs, key) when is_map(attrs) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end

  defp validate_token(token) when is_binary(token) and byte_size(token) >= @token_min_bytes do
    if token == :binary.copy(<<0>>, byte_size(token)) do
      {:error, :zero_token}
    else
      :ok
    end
  end

  defp validate_token(token) when is_binary(token), do: {:error, :token_too_short}
  defp validate_token(_), do: {:error, :invalid_token}

  defp validate_principal_id(id) when is_binary(id) and byte_size(id) > 0 do
    if String.starts_with?(id, "agent_"), do: :ok, else: {:error, :invalid_principal_id}
  end

  defp validate_principal_id(_), do: {:error, :invalid_principal_id}

  # Booleans are atoms in Elixir — reject them before the generic atom clause.
  defp validate_purpose(purpose) when is_boolean(purpose), do: {:error, :invalid_purpose}

  defp validate_purpose(purpose) when is_atom(purpose) and not is_nil(purpose), do: :ok

  defp validate_purpose(purpose) when is_binary(purpose) do
    if String.trim(purpose) == "" do
      {:error, :invalid_purpose}
    else
      :ok
    end
  end

  defp validate_purpose(_), do: {:error, :invalid_purpose}
end

defimpl Inspect, for: Arbor.Contracts.Security.SigningAuthority do
  def inspect(%Arbor.Contracts.Security.SigningAuthority{} = authority, opts) do
    details =
      Inspect.Algebra.concat([
        "principal_id: ",
        Inspect.Algebra.to_doc(authority.principal_id, opts),
        ", purpose: ",
        Inspect.Algebra.to_doc(authority.purpose, opts),
        ", token: [REDACTED]"
      ])

    Inspect.Algebra.concat([
      "#Arbor.Contracts.Security.SigningAuthority<",
      details,
      ">"
    ])
  end
end
