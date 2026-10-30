defmodule Arbor.Security.OIDC.AuthCodeFlow do
  @moduledoc """
  Compatibility facade for the optional authorization-code protocol adapter.

  Cryptographic state, nonce and PKCE generation remain available without the
  adapter. Endpoint discovery and token operations use the host-owned invoker.
  """

  alias Arbor.Common.OAuth.AuthCode
  alias Arbor.Security.OIDC.Adapter

  @spec generate_pkce() :: {String.t(), String.t()}
  defdelegate generate_pkce(), to: AuthCode

  @spec generate_state() :: String.t()
  defdelegate generate_state(), to: AuthCode

  @spec generate_nonce() :: String.t()
  def generate_nonce, do: AuthCode.generate_state()

  @spec build_authorize_url(term(), String.t(), String.t(), term()) ::
          {:ok, String.t(), String.t()} | {:error, term()}
  def build_authorize_url(provider, redirect_uri, state, opts \\ []),
    do: Adapter.call(:build_authorize_url, [provider, redirect_uri, state, opts])

  @spec exchange_code(term(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def exchange_code(provider, code, redirect_uri, code_verifier),
    do: Adapter.call(:exchange_code, [provider, code, redirect_uri, code_verifier])
end
