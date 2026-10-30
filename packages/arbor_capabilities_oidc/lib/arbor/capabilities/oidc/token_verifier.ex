defmodule Arbor.Capabilities.OIDC.TokenVerifier do
  @moduledoc """
  JWT/OIDC token verification via JWKS.

  Fetches the provider's JWKS keys from their OpenID Configuration endpoint,
  then validates the token's signature, expiry, issuer, and audience.

  Standalone verification fetches JWKS without retaining a cache. Hosts may use
  the preparation and verification stages with their own admitted JWKS owner.
  """

  require Logger

  alias Arbor.Capabilities.OIDC.Discovery
  alias Arbor.Capabilities.OIDC.Verification
  alias Arbor.Common.OAuth.HttpClient
  alias Arbor.Common.OAuth.HttpClient.Request

  @default_clock_skew_seconds 60
  @max_unix_timestamp 253_402_300_799
  @max_issuer_bytes 2_048
  @max_subject_bytes 256
  @max_audiences 16
  @max_audience_bytes 256
  @max_nonce_bytes 1_024
  @jwks_max_response_bytes 262_144
  @jwks_timeout_ms 10_000

  @doc """
  Verify an OIDC ID token against a provider configuration.

  The provider config must include `:issuer` and `:client_id`.

  Returns `{:ok, claims}` with the decoded JWT claims on success,
  or `{:error, reason}` on failure.
  """
  @spec verify(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def verify(id_token, provider) do
    with {:ok, context} <- prepare(id_token, provider),
         {:ok, jwks} <- fetch_jwks_uncached(provider) do
      verify_prepared(context, jwks)
    end
  end

  @doc """
  Validate a provider and decode the token header without network IO.

  The returned context contains credentials and has redacted inspection. It
  does not establish identity or validate the token's signature or claims.
  """
  @spec prepare(term(), term()) :: {:ok, Verification.t()} | {:error, term()}
  def prepare(id_token, %{issuer: _issuer, client_id: _client_id} = provider) do
    with :ok <- validate_provider(provider),
         {:ok, header} <- decode_header(id_token) do
      {:ok, %Verification{token: id_token, provider: provider, header: header}}
    end
  end

  def prepare(_id_token, _provider), do: {:error, :invalid_provider_config}

  @doc """
  Verify a prepared token against JWKS admitted by the calling owner.

  This pure stage selects the signing key and verifies the original token's
  signature and claims. It never selects a cache, fetch callback or key source
  from provider/request options. A missing kid is returned to the host so that
  its own cache authority can decide whether to refresh once.
  """
  @spec verify_prepared(Verification.t(), map()) :: {:ok, map()} | {:error, term()}
  def verify_prepared(
        %Verification{
          token: id_token,
          provider: %{issuer: issuer, client_id: client_id} = provider,
          header: header
        },
        jwks
      ) do
    with true <- valid_jwks?(jwks),
         {:ok, key} <- find_key(jwks, header),
         {:ok, claims} <- verify_signature(id_token, key),
         :ok <- validate_claims(claims, issuer, client_id, provider) do
      {:ok, claims}
    else
      false -> {:error, :invalid_jwks_format}
      {:error, _reason} = error -> error
    end
  end

  def verify_prepared(_context, _jwks), do: {:error, :invalid_verification_context}

  @doc """
  Decode a JWT without verification (for inspection only).

  Returns `{:ok, claims}` or `{:error, reason}`.
  """
  @spec decode_unverified(String.t()) :: {:ok, map()} | {:error, term()}
  def decode_unverified(token) when is_binary(token) do
    case String.split(token, ".") do
      [_header, payload, _sig] ->
        with {:ok, json} <- Base.url_decode64(payload, padding: false),
             {:ok, claims} <- Jason.decode(json) do
          {:ok, claims}
        else
          _ -> {:error, :invalid_token_format}
        end

      _ ->
        {:error, :invalid_token_format}
    end
  end

  def decode_unverified(_token), do: {:error, :invalid_token_format}

  # --- Private ---

  defp decode_header(token) when is_binary(token) do
    case String.split(token, ".") do
      [header_b64 | _rest] ->
        with {:ok, json} <- Base.url_decode64(header_b64, padding: false),
             {:ok, header} <- Jason.decode(json) do
          {:ok, header}
        else
          _ -> {:error, :invalid_jwt_header}
        end

      _ ->
        {:error, :invalid_token_format}
    end
  end

  defp decode_header(_token), do: {:error, :invalid_token_format}

  defp validate_provider(%{issuer: issuer, client_id: client_id} = provider) do
    allow_http = provider_get(provider, :allow_http, false) == true

    with {:ok, _normalized} <- Discovery.validate_issuer(issuer, allow_http),
         true <- bounded_string?(client_id, @max_audience_bytes) do
      :ok
    else
      false -> {:error, :invalid_provider_config}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_provider_config}
    end
  end

  @doc false
  @spec fetch_jwks_uncached(map()) :: {:ok, map()} | {:error, term()}
  def fetch_jwks_uncached(%{issuer: issuer} = provider) do
    opts =
      %{
        allow_http: provider_get(provider, :allow_http, false) == true,
        endpoints: jwks_endpoints(provider_get(provider, :endpoints)),
        trusted_origins: provider_get(provider, :trusted_origins, []),
        http_client: provider_get(provider, :http_client),
        for: :jwks
      }
      |> maybe_put(:timeout_ms, provider_get(provider, :discovery_timeout_ms))
      |> maybe_put(:max_response_bytes, provider_get(provider, :discovery_max_response_bytes))

    with {:ok, endpoints} <- Discovery.discover(issuer, opts),
         {:ok, jwks_uri} <- require_jwks_uri(endpoints),
         {:ok, jwks} <- http_get_json(jwks_uri, provider),
         true <- valid_jwks?(jwks) do
      {:ok, jwks}
    else
      false ->
        {:error, :invalid_jwks_format}

      {:error, {:transport_error, _reason} = reason} ->
        {:error, {:http_request_failed, reason}}

      {:error, {:timeout, _milliseconds} = reason} ->
        {:error, {:http_request_failed, reason}}

      {:error, _} = error ->
        error
    end
  end

  def fetch_jwks_uncached(_provider), do: {:error, :invalid_provider_config}

  defp require_jwks_uri(%{jwks_uri: jwks_uri})
       when is_binary(jwks_uri) and jwks_uri != "",
       do: {:ok, jwks_uri}

  defp require_jwks_uri(_endpoints), do: {:error, :no_jwks_uri_in_config}

  defp jwks_endpoints(endpoints) when is_map(endpoints) do
    case Map.get(endpoints, :jwks_uri, Map.get(endpoints, "jwks_uri")) do
      nil -> nil
      jwks_uri -> %{jwks_uri: jwks_uri}
    end
  end

  defp jwks_endpoints(_endpoints), do: nil

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Map.put(opts, key, value)

  defp valid_jwks?(%{"keys" => keys}) when is_list(keys),
    do: length(keys) in 1..128 and Enum.all?(keys, &is_map/1)

  defp valid_jwks?(_jwks), do: false

  defp find_key(%{"keys" => keys}, %{"kid" => kid}) when is_list(keys) do
    case Enum.find(keys, fn k -> Map.get(k, "kid") == kid end) do
      nil -> {:error, {:kid_not_found, kid}}
      key -> {:ok, key}
    end
  end

  defp find_key(%{"keys" => [key | _]}, _header) do
    # No kid in header — use first key
    {:ok, key}
  end

  defp find_key(_, _), do: {:error, :invalid_jwks_format}

  defp verify_signature(token, jwk) do
    try do
      signer = Joken.Signer.create(jwk_alg(jwk), jwk)

      case Joken.verify(token, signer) do
        {:ok, claims} -> {:ok, claims}
        {:error, reason} -> {:error, {:signature_verification_failed, reason}}
      end
    rescue
      _exception -> {:error, :invalid_jwks_key}
    catch
      _kind, _reason -> {:error, :invalid_jwks_key}
    end
  end

  defp jwk_alg(%{"alg" => alg}), do: alg
  defp jwk_alg(%{"kty" => "RSA"}), do: "RS256"
  defp jwk_alg(%{"kty" => "EC", "crv" => "P-256"}), do: "ES256"
  defp jwk_alg(_), do: "RS256"

  defp validate_claims(claims, issuer, client_id, provider) when is_map(claims) do
    now = DateTime.utc_now() |> DateTime.to_unix()
    skew = clock_skew_seconds(provider)
    exp = Map.get(claims, "exp")
    nbf = Map.get(claims, "nbf")
    iat = Map.get(claims, "iat")
    audiences = normalized_audiences(Map.get(claims, "aud"))
    azp = Map.get(claims, "azp")

    cond do
      not bounded_string?(Map.get(claims, "iss"), @max_issuer_bytes) ->
        {:error, :invalid_issuer_claim}

      Map.get(claims, "iss") != issuer ->
        {:error, {:issuer_mismatch, Map.get(claims, "iss"), issuer}}

      not is_integer(exp) ->
        {:error, :invalid_exp_claim}

      exp <= now - skew ->
        {:error, :token_expired}

      exp > @max_unix_timestamp ->
        {:error, :invalid_exp_claim}

      not optional_time_claim_valid?(claims, "nbf", nbf, now, skew) ->
        {:error, :invalid_nbf_claim}

      not optional_time_claim_valid?(claims, "iat", iat, now, skew) ->
        {:error, :invalid_iat_claim}

      not valid_audiences?(audiences) or client_id not in audiences ->
        {:error, {:audience_mismatch, Map.get(claims, "aud"), client_id}}

      length(audiences) > 1 and azp != client_id ->
        {:error, :invalid_authorized_party_claim}

      Map.has_key?(claims, "azp") and azp != client_id ->
        {:error, :invalid_authorized_party_claim}

      not bounded_string?(Map.get(claims, "sub"), @max_subject_bytes) ->
        {:error, :missing_sub_claim}

      not nonce_matches?(claims, expected_nonce(provider)) ->
        {:error, :nonce_mismatch}

      true ->
        :ok
    end
  end

  defp validate_claims(_claims, _issuer, _client_id, _provider),
    do: {:error, :invalid_claims}

  defp normalized_audiences(audience) when is_binary(audience), do: [audience]
  defp normalized_audiences(audience) when is_list(audience), do: audience
  defp normalized_audiences(_audience), do: []

  defp valid_audiences?(audiences) do
    length(audiences) in 1..@max_audiences and
      Enum.all?(audiences, &bounded_string?(&1, @max_audience_bytes))
  end

  defp optional_time_claim_valid?(claims, name, value, now, skew) do
    not Map.has_key?(claims, name) or
      (is_integer(value) and value >= 0 and value <= now + skew)
  end

  defp bounded_string?(value, maximum) do
    is_binary(value) and byte_size(value) in 1..maximum//1 and String.valid?(value)
  end

  defp clock_skew_seconds(provider) do
    case provider_get(provider, :clock_skew_seconds, @default_clock_skew_seconds) do
      value when is_integer(value) and value in 0..300 -> value
      _invalid -> @default_clock_skew_seconds
    end
  end

  defp expected_nonce(provider), do: provider_get(provider, :expected_nonce)

  defp nonce_matches?(_claims, nil), do: true

  defp nonce_matches?(claims, expected)
       when is_binary(expected) and byte_size(expected) in 1..@max_nonce_bytes do
    actual = Map.get(claims, "nonce")

    is_binary(actual) and byte_size(actual) == byte_size(expected) and
      Plug.Crypto.secure_compare(actual, expected)
  end

  defp nonce_matches?(_claims, _invalid_expected_nonce), do: false

  defp provider_get(provider, key, default \\ nil) when is_map(provider) do
    Map.get(provider, key, Map.get(provider, Atom.to_string(key), default))
  end

  defp http_get_json(url, provider) do
    request = %Request{
      method: :get,
      url: url,
      headers: [{"accept", "application/json"}],
      max_response_bytes: @jwks_max_response_bytes,
      timeout_ms: @jwks_timeout_ms
    }

    case HttpClient.request(request, http_client: provider_get(provider, :http_client)) do
      {:ok, %HttpClient.Response{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
          _invalid -> {:error, :invalid_jwks_json}
        end

      {:ok, %HttpClient.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, {:transport_error, _reason} = reason} ->
        {:error, {:http_request_failed, reason}}

      {:error, {:timeout, _milliseconds} = reason} ->
        {:error, {:http_request_failed, reason}}

      {:error, _reason} = error ->
        error
    end
  end
end
