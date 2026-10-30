defmodule Arbor.Capabilities.OIDC do
  @moduledoc """
  Bounded OpenID Connect protocols with caller-owned identity and cache policy.

  This passive package owns discovery, authorization-code/PKCE, device flows
  and JWT verification. It neither creates Arbor identities nor starts a JWKS
  cache or HTTP pool. Hosts retain configured-provider admission, key storage,
  authority acquisition and resource supervision.

  `verify/2` fetches JWKS without caching. A host with an admitted cache first
  calls `prepare_verification/2`, then passes its owned JWKS to
  `verify_prepared/2`. Preparation validates inputs before network IO but is
  not authentication; only successful verification returns verified claims.
  """

  use Boundary,
    top_level?: true,
    deps: [Arbor.Common.OAuth, Jason, Joken, Plug.Crypto, Logger],
    exports: []

  alias Arbor.Capabilities.OIDC.AuthCodeFlow
  alias Arbor.Capabilities.OIDC.DeviceFlow
  alias Arbor.Capabilities.OIDC.Discovery
  alias Arbor.Capabilities.OIDC.TokenVerifier

  defdelegate generate_pkce(), to: AuthCodeFlow
  defdelegate generate_state(), to: AuthCodeFlow
  defdelegate generate_nonce(), to: AuthCodeFlow

  defdelegate build_authorize_url(provider, redirect_uri, state, opts \\ []), to: AuthCodeFlow
  defdelegate exchange_code(provider, code, redirect_uri, code_verifier), to: AuthCodeFlow

  defdelegate start_device_flow(provider), to: DeviceFlow, as: :start
  defdelegate poll_device_flow(provider, device_response), to: DeviceFlow, as: :poll
  defdelegate refresh_device_flow(provider, refresh_token), to: DeviceFlow, as: :refresh

  defdelegate discover(issuer, opts \\ []), to: Discovery
  defdelegate validate_issuer(issuer, allow_http \\ false), to: Discovery
  defdelegate discovery_url(issuer), to: Discovery

  defdelegate verify(id_token, provider), to: TokenVerifier
  defdelegate prepare_verification(id_token, provider), to: TokenVerifier, as: :prepare
  defdelegate verify_prepared(context, jwks), to: TokenVerifier
  defdelegate fetch_jwks_uncached(provider), to: TokenVerifier
  defdelegate decode_unverified(id_token), to: TokenVerifier
end
