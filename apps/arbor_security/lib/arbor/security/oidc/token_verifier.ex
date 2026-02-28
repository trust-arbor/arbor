defmodule Arbor.Security.OIDC.TokenVerifier do
  @moduledoc """
  JWT/OIDC token verification via JWKS.

  Fetches the provider's JWKS keys from their OpenID Configuration endpoint,
  then validates the token's signature, expiry, issuer, and audience.

  JWKS keys are cached in ETS with a configurable TTL (default: 1 hour).
  """

  require Logger

  @jwks_cache_table :arbor_oidc_jwks_cache
  @jwks_ttl_ms :timer.hours(1)

  @doc """
  Verify an OIDC ID token against a provider configuration.

  The provider config must include `:issuer` and `:client_id`.

  Returns `{:ok, claims}` with the decoded JWT claims on success,
  or `{:error, reason}` on failure.
  """
  @spec verify(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def verify(id_token, %{issuer: issuer, client_id: client_id} = _provider) do
    with {:ok, header} <- decode_header(id_token),
         {:ok, jwks} <- fetch_jwks(issuer),
         {:ok, key} <- find_key(jwks, header),
         {:ok, claims} <- verify_signature(id_token, key),
         :ok <- validate_claims(claims, issuer, client_id) do
      {:ok, claims}
    end
  end

  @doc """
  Decode a JWT without verification (for inspection only).

  Returns `{:ok, claims}` or `{:error, reason}`.
  """
  @spec decode_unverified(String.t()) :: {:ok, map()} | {:error, term()}
  def decode_unverified(token) do
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

  # --- Private ---

  defp decode_header(token) do
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

  defp fetch_jwks(issuer) do
    case get_cached_jwks(issuer) do
      {:ok, jwks} ->
        {:ok, jwks}

      :miss ->
        fetch_and_cache_jwks(issuer)
    end
  end

  defp get_cached_jwks(issuer) do
    ensure_cache_table()

    case :ets.lookup(@jwks_cache_table, issuer) do
      [{^issuer, jwks, expires_at}] ->
        if System.monotonic_time(:millisecond) < expires_at do
          {:ok, jwks}
        else
          :ets.delete(@jwks_cache_table, issuer)
          :miss
        end

      [] ->
        :miss
    end
  end

  defp fetch_and_cache_jwks(issuer) do
    config_url = String.trim_trailing(issuer, "/") <> "/.well-known/openid-configuration"

    with {:ok, config} <- http_get_json(config_url),
         jwks_uri when is_binary(jwks_uri) <- Map.get(config, "jwks_uri"),
         {:ok, jwks} <- http_get_json(jwks_uri) do
      expires_at = System.monotonic_time(:millisecond) + @jwks_ttl_ms
      :ets.insert(@jwks_cache_table, {issuer, jwks, expires_at})
      {:ok, jwks}
    else
      nil -> {:error, :no_jwks_uri_in_config}
      {:error, _} = error -> error
    end
  end

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
    signer = Joken.Signer.create(jwk_alg(jwk), jwk)

    case Joken.verify(token, signer) do
      {:ok, claims} -> {:ok, claims}
      {:error, reason} -> {:error, {:signature_verification_failed, reason}}
    end
  end

  defp jwk_alg(%{"alg" => alg}), do: alg
  defp jwk_alg(%{"kty" => "RSA"}), do: "RS256"
  defp jwk_alg(%{"kty" => "EC", "crv" => "P-256"}), do: "ES256"
  defp jwk_alg(_), do: "RS256"

  defp validate_claims(claims, issuer, client_id) do
    now = DateTime.utc_now() |> DateTime.to_unix()

    cond do
      Map.get(claims, "exp", 0) < now ->
        {:error, :token_expired}

      Map.get(claims, "iss") != issuer ->
        {:error, {:issuer_mismatch, Map.get(claims, "iss"), issuer}}

      not audience_matches?(claims, client_id) ->
        {:error, {:audience_mismatch, Map.get(claims, "aud"), client_id}}

      is_nil(Map.get(claims, "sub")) ->
        {:error, :missing_sub_claim}

      true ->
        :ok
    end
  end

  defp audience_matches?(%{"aud" => aud}, client_id) when is_binary(aud) do
    aud == client_id
  end

  defp audience_matches?(%{"aud" => aud}, client_id) when is_list(aud) do
    client_id in aud
  end

  defp audience_matches?(_, _), do: false

  defp http_get_json(url) do
    case Req.get(url, receive_timeout: 10_000) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        Jason.decode(body)

      {:ok, %{status: status}} ->
        {:error, {:http_error, status, url}}

      {:error, reason} ->
        {:error, {:http_request_failed, reason}}
    end
  end

  defp ensure_cache_table do
    if :ets.whereis(@jwks_cache_table) == :undefined do
      :ets.new(@jwks_cache_table, [:set, :public, :named_table])
    end
  rescue
    ArgumentError -> :ok
  end
end
