defmodule Arbor.LLM.OAuth.ProviderPolicyTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.LLM.OAuth.ProviderPolicy

  test "openai/0 matches the exact Codex CLI 0.146.0 policy" do
    policy = ProviderPolicy.openai()

    assert policy.client_id == "app_EMoamEEZ73f0CkXaXp7hrann"
    assert policy.issuer == "https://auth.openai.com"
    assert policy.authorization_endpoint == "https://auth.openai.com/oauth/authorize"
    assert policy.token_endpoint == "https://auth.openai.com/oauth/token"

    assert policy.redirect_uris == %{
             port_1455: "http://localhost:1455/auth/callback",
             port_1457: "http://localhost:1457/auth/callback"
           }

    assert policy.scopes ==
             ~w(openid profile email offline_access api.connectors.read api.connectors.invoke)

    assert policy.code_challenge_method == "S256"
  end

  test "xai/0 matches the exact discovery-advertised policy and existing refresh client identity" do
    policy = ProviderPolicy.xai()

    assert policy.client_id == "b1a00492-073a-47ea-816f-4c329264a828"
    assert policy.issuer == "https://auth.x.ai"
    assert policy.discovery_url == "https://auth.x.ai/.well-known/openid-configuration"
    assert policy.device_authorization_endpoint == "https://auth.x.ai/oauth2/device/code"
    assert policy.token_endpoint == "https://auth.x.ai/oauth2/token"

    assert policy.scopes ==
             ~w(openid profile email offline_access api:access grok-cli:access)
  end

  test "refresh_config/1 projects the exact 3-key shape oauth.ex's refresh internals expect" do
    assert ProviderPolicy.refresh_config(:openai) == %{
             refresh_url: "https://auth.openai.com/oauth/token",
             client_id: "app_EMoamEEZ73f0CkXaXp7hrann",
             skew_s: 120
           }

    assert ProviderPolicy.refresh_config(:xai) == %{
             discovery_url: "https://auth.x.ai/.well-known/openid-configuration",
             client_id: "b1a00492-073a-47ea-816f-4c329264a828",
             skew_s: 3600
           }
  end
end
