defmodule Arbor.Security.ExtensionEnvelopes do
  @moduledoc """
  Security consumer of the E0C activation and invocation envelopes.

  Shape and digest checks live in `Arbor.Contracts.Extension.Envelope`.
  This module binds those closed maps to Ed25519 verification and a
  caller-supplied clock. Expiry comparison is never performed inside
  the contract.
  """

  alias Arbor.Contracts.Extension.Envelope
  alias Arbor.Security.Crypto

  @authorization_kinds [:activation_authorization, :invocation_authorization]

  @doc "Validates an activation or invocation authorization payload."
  @spec validate(atom(), term()) :: {:ok, map()} | {:error, atom()}
  def validate(kind, document) when kind in @authorization_kinds do
    Envelope.validate(kind, document)
  end

  def validate(_kind, _document), do: {:error, :unsupported_kind}

  @doc "Validates a signed authorization and optionally verifies its signature."
  @spec validate_signed(term(), keyword()) :: {:ok, map()} | {:error, atom()}
  def validate_signed(document, opts \\ []) when is_list(opts) do
    with {:ok, envelope} <- Envelope.validate_signed(document),
         {:ok, kind} <- signed_kind(envelope),
         true <- kind in @authorization_kinds,
         :ok <- maybe_verify(envelope, opts),
         :ok <- maybe_unexpired(envelope["payload"], opts),
         :ok <- maybe_unreplayed(envelope["payload"], opts) do
      {:ok, envelope}
    else
      false -> {:error, :unsupported_kind}
      {:error, reason} -> {:error, reason}
    end
  end

  defp signed_kind(%{"domain" => domain}) do
    case Envelope.kind_from_domain(domain) do
      {:ok, kind} -> {:ok, kind}
      :error -> {:error, :unknown_kind}
    end
  end

  defp maybe_verify(envelope, opts) do
    case Keyword.get(opts, :public_key) do
      nil ->
        :ok

      public_key when is_binary(public_key) ->
        with {:ok, message} <- Envelope.signing_message(envelope),
             {:ok, signature} <- decode_signature(envelope["signature"]) do
          if Crypto.verify(message, signature, public_key),
            do: :ok,
            else: {:error, :signature_mismatch}
        end

      _other ->
        {:error, :invalid_public_key}
    end
  end

  defp maybe_unexpired(payload, opts) do
    case Keyword.get(opts, :now) do
      nil ->
        :ok

      now when is_binary(now) ->
        expires_at = Map.get(payload, "expires_at") || Map.get(payload, "deadline")

        if is_binary(expires_at) and expires_at >= now,
          do: :ok,
          else: {:error, :authorization_expired}

      _other ->
        {:error, :invalid_timestamp}
    end
  end

  defp maybe_unreplayed(payload, opts) do
    case Keyword.get(opts, :consumed_nonces) do
      nil ->
        :ok

      %MapSet{} = consumed ->
        nonce = Map.get(payload, "nonce")

        if is_binary(nonce) and MapSet.member?(consumed, nonce),
          do: {:error, :authorization_replayed},
          else: :ok

      _other ->
        {:error, :invalid_nonce}
    end
  end

  defp decode_signature(hex) when is_binary(hex) do
    case Base.decode16(hex, case: :lower) do
      {:ok, bytes} when byte_size(bytes) == 64 -> {:ok, bytes}
      _ -> {:error, :invalid_signature}
    end
  end
end
