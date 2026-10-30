defmodule Arbor.Security.OIDC.Discovery do
  @moduledoc """
  Compatibility facade for the optional OIDC endpoint-policy implementation.
  """

  alias Arbor.Security.OIDC.Adapter

  @type endpoints :: %{
          issuer: String.t(),
          authorization_endpoint: String.t() | nil,
          token_endpoint: String.t() | nil,
          device_authorization_endpoint: String.t() | nil,
          jwks_uri: String.t() | nil
        }

  @spec discover(term(), term()) :: {:ok, endpoints()} | {:error, term()}
  def discover(issuer, opts \\ []), do: Adapter.call(:discover, [issuer, opts])

  @spec validate_issuer(term(), boolean()) :: {:ok, String.t()} | {:error, term()}
  def validate_issuer(issuer, allow_http \\ false),
    do: Adapter.call(:validate_issuer, [issuer, allow_http])

  @spec discovery_url(String.t()) :: String.t() | {:error, :oidc_adapter_unavailable}
  def discovery_url(issuer), do: Adapter.call(:discovery_url, [issuer])
end
