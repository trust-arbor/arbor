defmodule Arbor.Contracts.Security.SignedRequest do
  @moduledoc """
  A signed request envelope for authenticated agent communication.

  SignedRequests provide replay-protected, authenticated messaging between agents.
  Each request includes a timestamp and random nonce to prevent replay attacks.

  ## Wire Format

  The signing payload uses length-prefixed encoding to prevent field-boundary
  ambiguity attacks. Each variable-length field is prefixed with its byte size
  as a 32-bit big-endian integer: `<<len::32, field::binary>>`.

  ## Usage

      # Sign a request
      {:ok, signed} = SignedRequest.sign("do something", identity.agent_id, identity.private_key)

      # The signing payload for verification
      canonical = SignedRequest.signing_payload(signed)
  """

  use TypedStruct

  alias Arbor.Types

  @nonce_size 16

  @derive Jason.Encoder
  typedstruct enforce: true do
    @typedoc "A signed request with replay protection"

    field(:payload, binary())
    field(:agent_id, Types.agent_id())
    field(:timestamp, DateTime.t())
    field(:nonce, Types.nonce())
    field(:signature, Types.signature())
  end

  @doc """
  Create a new SignedRequest struct from pre-computed fields.

  Validates that all required fields are present and well-formed.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    request = %__MODULE__{
      payload: Keyword.fetch!(attrs, :payload),
      agent_id: Keyword.fetch!(attrs, :agent_id),
      timestamp: Keyword.fetch!(attrs, :timestamp),
      nonce: Keyword.fetch!(attrs, :nonce),
      signature: Keyword.fetch!(attrs, :signature)
    }

    case validate(request) do
      :ok -> {:ok, request}
      {:error, _} = error -> error
    end
  end

  @doc """
  Sign a payload, producing a complete SignedRequest.

  Generates a fresh timestamp and random nonce, computes the canonical signing
  payload, and signs with the provided Ed25519 private key.

  ## Parameters

  - `payload` - The binary payload to sign
  - `agent_id` - The signing agent's ID
  - `private_key` - The 64-byte Ed25519 private key

  ## Examples

      {:ok, signed} = SignedRequest.sign("grant access", identity.agent_id, identity.private_key)
  """
  @spec sign(binary(), Types.agent_id(), Types.private_key()) :: {:ok, t()} | {:error, term()}
  def sign(payload, agent_id, private_key)
      when is_binary(payload) and is_binary(agent_id) and is_binary(private_key) do
    timestamp = DateTime.utc_now()
    nonce = :crypto.strong_rand_bytes(@nonce_size)

    request_without_sig = %__MODULE__{
      payload: payload,
      agent_id: agent_id,
      timestamp: timestamp,
      nonce: nonce,
      signature: <<>>
    }

    message = compute_signing_payload(request_without_sig)
    signature = :crypto.sign(:eddsa, :sha512, message, [private_key, :ed25519])

    {:ok, %{request_without_sig | signature: signature}}
  end

  @doc """
  Compute the canonical signing payload for a SignedRequest.

  Each variable-length field is length-prefixed (`<<byte_size::32, field::binary>>`)
  to prevent field-boundary ambiguity attacks. Fixed-size fields (nonce) are
  appended directly.

  Used by both signing and verification to ensure deterministic serialization.
  """
  @spec signing_payload(t()) :: binary()
  def signing_payload(%__MODULE__{} = request) do
    compute_signing_payload(request)
  end

  # Private

  defp compute_signing_payload(%__MODULE__{} = request) do
    timestamp_bin = DateTime.to_iso8601(request.timestamp)

    length_prefix(request.payload) <>
      length_prefix(request.agent_id) <>
      length_prefix(timestamp_bin) <>
      request.nonce
  end

  defp length_prefix(field) when is_binary(field) do
    <<byte_size(field)::32, field::binary>>
  end

  defp validate(%__MODULE__{} = request) do
    validators = [
      &validate_payload/1,
      &validate_agent_id/1,
      &validate_nonce/1,
      &validate_signature/1
    ]

    Enum.reduce_while(validators, :ok, fn validator, :ok ->
      case validator.(request) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp validate_payload(%{payload: p}) when is_binary(p) and byte_size(p) > 0, do: :ok
  defp validate_payload(_), do: {:error, :empty_payload}

  defp validate_agent_id(%{agent_id: id}) when is_binary(id) do
    if String.starts_with?(id, "agent_"), do: :ok, else: {:error, {:invalid_agent_id, id}}
  end

  defp validate_agent_id(_), do: {:error, :missing_agent_id}

  defp validate_nonce(%{nonce: n}) when is_binary(n) and byte_size(n) == @nonce_size do
    # Reject all-zero nonces as they indicate failed entropy source
    if n == <<0::size(@nonce_size * 8)>> do
      {:error, :zero_nonce}
    else
      :ok
    end
  end
  defp validate_nonce(_), do: {:error, :invalid_nonce_size}

  defp validate_signature(%{signature: s}) when is_binary(s) and byte_size(s) > 0, do: :ok
  defp validate_signature(_), do: {:error, :empty_signature}
end
