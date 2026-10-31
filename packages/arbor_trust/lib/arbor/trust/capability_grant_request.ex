defmodule Arbor.Trust.CapabilityGrantRequest do
  @moduledoc false

  alias Arbor.Contracts.Security.CapabilityUri
  alias Arbor.Contracts.Security.SigningAuthority.Validator

  @uri_prefix "arbor://trust/capability_grant/v1/"
  @nonce_bytes 24
  @ttl_seconds 30
  @max_ttl_seconds 60
  @max_payload_bytes 2_048
  @max_field_bytes 4_096
  @max_session_bytes 512

  @type t :: %{
          target_agent_id: String.t(),
          resource_uri: String.t(),
          session_id: String.t(),
          nonce: binary(),
          expires_at: integer()
        }

  @spec build(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, t(), binary()} | {:error, atom()}
  def build(target_agent_id, resource_uri, session_id, opts \\ []) do
    with :ok <- validate_principal(target_agent_id),
         {:ok, canonical_uri} <- canonical_resource(resource_uri, opts),
         :ok <- validate_session(session_id) do
      request = %{
        target_agent_id: target_agent_id,
        resource_uri: canonical_uri,
        session_id: session_id,
        nonce: :crypto.strong_rand_bytes(@nonce_bytes),
        expires_at: System.system_time(:second) + @ttl_seconds
      }

      payload = encode(request)

      with :ok <- validate_encoded_payload(payload) do
        {:ok, request, payload}
      end
    end
  rescue
    _ -> {:error, :invalid_capability_grant_request}
  catch
    _, _ -> {:error, :invalid_capability_grant_request}
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, atom()}
  def decode(payload) when is_binary(payload) and byte_size(payload) <= @max_payload_bytes do
    with {:ok, parsed} <- CapabilityUri.parse(payload),
         true <- CapabilityUri.canonical(parsed) == payload,
         [
           "trust",
           "capability_grant",
           "v1",
           encoded_target,
           encoded_resource,
           encoded_session,
           encoded_nonce,
           expires_at_binary
         ] <- parsed.segments,
         {:ok, target_agent_id} <- decode_field(encoded_target),
         {:ok, resource_uri} <- decode_field(encoded_resource),
         {:ok, session_id} <- decode_field(encoded_session),
         {:ok, nonce} <- Base.decode16(encoded_nonce, case: :lower),
         {expires_at, ""} <- Integer.parse(expires_at_binary),
         request = %{
           target_agent_id: target_agent_id,
           resource_uri: resource_uri,
           session_id: session_id,
           nonce: nonce,
           expires_at: expires_at
         },
         :ok <- validate(request),
         true <- encode(request) == payload do
      {:ok, request}
    else
      _ -> {:error, :invalid_capability_grant_request}
    end
  rescue
    _ -> {:error, :invalid_capability_grant_request}
  catch
    _, _ -> {:error, :invalid_capability_grant_request}
  end

  def decode(_payload), do: {:error, :invalid_capability_grant_request}

  @doc false
  @spec encode(t()) :: binary()
  def encode(request) when is_map(request) do
    @uri_prefix <>
      encode_field(Map.fetch!(request, :target_agent_id)) <>
      "/" <>
      encode_field(Map.fetch!(request, :resource_uri)) <>
      "/" <>
      encode_field(Map.fetch!(request, :session_id)) <>
      "/" <>
      Base.encode16(Map.fetch!(request, :nonce), case: :lower) <>
      "/" <> Integer.to_string(Map.fetch!(request, :expires_at))
  end

  @spec fresh?(t(), integer()) :: boolean()
  def fresh?(request, now_seconds \\ System.system_time(:second))

  def fresh?(%{expires_at: expires_at}, now_seconds)
      when is_integer(expires_at) and is_integer(now_seconds) do
    expires_at > now_seconds and expires_at <= now_seconds + @max_ttl_seconds
  end

  def fresh?(_request, _now_seconds), do: false

  defp validate(request) do
    with :ok <- validate_principal(request.target_agent_id),
         {:ok, canonical_uri} <- canonical_resource(request.resource_uri, []),
         true <- canonical_uri == request.resource_uri,
         :ok <- validate_session(request.session_id),
         true <- is_binary(request.nonce) and byte_size(request.nonce) == @nonce_bytes,
         true <- request.nonce != :binary.copy(<<0>>, @nonce_bytes),
         true <- is_integer(request.expires_at) and request.expires_at > 0 do
      :ok
    else
      _ -> {:error, :invalid_capability_grant_request}
    end
  end

  defp validate_principal(principal_id) do
    case Validator.validate_principal_id(principal_id) do
      :ok -> :ok
      _ -> {:error, :invalid_capability_grant_request}
    end
  end

  defp canonical_resource(resource_uri, opts)
       when is_binary(resource_uri) and byte_size(resource_uri) in 1..@max_field_bytes and
              is_list(opts) do
    with true <- Keyword.keyword?(opts),
         {:ok, effective_uri} <-
           Arbor.Security.normalize_authorization_resource_uri(resource_uri, opts),
         {:ok, parsed} <- CapabilityUri.parse(effective_uri) do
      {:ok, CapabilityUri.canonical(parsed)}
    else
      _ -> {:error, :invalid_capability_grant_request}
    end
  end

  defp canonical_resource(_resource_uri, _opts),
    do: {:error, :invalid_capability_grant_request}

  defp validate_session(session_id)
       when is_binary(session_id) and byte_size(session_id) in 1..@max_session_bytes do
    if String.valid?(session_id) and not String.contains?(session_id, <<0>>),
      do: :ok,
      else: {:error, :invalid_capability_grant_request}
  end

  defp validate_session(_session_id), do: {:error, :invalid_capability_grant_request}

  defp validate_encoded_payload(payload) do
    with true <- byte_size(payload) <= @max_payload_bytes,
         {:ok, parsed} <- CapabilityUri.parse(payload),
         true <- CapabilityUri.canonical(parsed) == payload do
      :ok
    else
      _ -> {:error, :invalid_capability_grant_request}
    end
  end

  defp encode_field(field) when is_binary(field), do: Base.url_encode64(field, padding: false)

  defp decode_field(encoded) when is_binary(encoded) and encoded != "" do
    Base.url_decode64(encoded, padding: false)
  end

  defp decode_field(_encoded), do: :error
end
