defmodule Arbor.LLM.OAuth.ProviderPolicy do
  @moduledoc false

  # Single closed compile-time source of truth for OpenAI/xAI OAuth provider
  # identity, consumed by BOTH Arbor.LLM.OAuth's existing refresh path (via
  # refresh_config/1) and Arbor.LLM.OAuth.Login (via openai/0, xai/0), so the
  # two paths can never drift into a second, independently-edited table.
  @policy %{
    openai: %{
      client_id: "app_EMoamEEZ73f0CkXaXp7hrann",
      issuer: "https://auth.openai.com",
      authorization_endpoint: "https://auth.openai.com/oauth/authorize",
      token_endpoint: "https://auth.openai.com/oauth/token",
      redirect_uris: %{
        port_1455: "http://localhost:1455/auth/callback",
        port_1457: "http://localhost:1457/auth/callback"
      },
      scopes: ~w(openid profile email offline_access api.connectors.read api.connectors.invoke),
      code_challenge_method: "S256",
      skew_s: 120
    },
    xai: %{
      client_id: "b1a00492-073a-47ea-816f-4c329264a828",
      issuer: "https://auth.x.ai",
      discovery_url: "https://auth.x.ai/.well-known/openid-configuration",
      device_authorization_endpoint: "https://auth.x.ai/oauth2/device/code",
      token_endpoint: "https://auth.x.ai/oauth2/token",
      scopes: ~w(openid profile email offline_access api:access grok-cli:access),
      skew_s: 3600
    }
  }

  @doc false
  @spec openai() :: map()
  def openai, do: @policy.openai

  @doc false
  @spec xai() :: map()
  def xai, do: @policy.xai

  @doc """
  Thin projection back to the 3-key shape `Arbor.LLM.OAuth`'s refresh internals
  already destructure (`refresh_url`/`client_id`/`skew_s` for openai;
  `discovery_url`/`client_id`/`skew_s` for xai), so the refresh call sites need
  only swap their config source, not their shape.
  """
  @spec refresh_config(:openai | :xai) :: map()
  def refresh_config(:openai) do
    %{
      refresh_url: @policy.openai.token_endpoint,
      client_id: @policy.openai.client_id,
      skew_s: @policy.openai.skew_s
    }
  end

  def refresh_config(:xai) do
    %{
      discovery_url: @policy.xai.discovery_url,
      client_id: @policy.xai.client_id,
      skew_s: @policy.xai.skew_s
    }
  end
end
