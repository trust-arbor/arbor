defmodule Arbor.Security.OIDC.TokenVerifier do
  @moduledoc """
  Host verification boundary for original signed OIDC tokens.

  The optional adapter prepares and verifies the protocol. Security alone owns
  JWKS cache selection, admission and lifetime. Callers supply only the original
  token and provider policy; prepared contexts, keys, fetchers and cache owners
  are never accepted by this host API.
  """

  alias Arbor.Security.OIDC.Adapter
  alias Arbor.Security.OIDC.JwksCache

  @spec verify(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def verify(id_token, provider) when is_binary(id_token) and is_map(provider) do
    with {:ok, context} <- Adapter.call(:prepare_verification, [id_token, provider]),
         {:ok, jwks} <- JwksCache.get_or_fetch(provider) do
      case Adapter.call(:verify_prepared, [context, jwks]) do
        {:error, {:kid_not_found, _kid}} -> verify_after_refresh(context, provider)
        result -> result
      end
    end
  end

  def verify(_id_token, _provider), do: {:error, :invalid_provider_config}

  @spec decode_unverified(String.t()) :: {:ok, map()} | {:error, term()}
  def decode_unverified(token), do: Adapter.call(:decode_unverified, [token])

  @doc false
  @spec fetch_jwks_uncached(map()) :: {:ok, map()} | {:error, term()}
  def fetch_jwks_uncached(provider), do: Adapter.call(:fetch_jwks_uncached, [provider])

  defp verify_after_refresh(context, provider) do
    with {:ok, jwks} <- JwksCache.refresh(provider) do
      Adapter.call(:verify_prepared, [context, jwks])
    end
  end
end
