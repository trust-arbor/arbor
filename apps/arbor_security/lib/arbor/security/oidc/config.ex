defmodule Arbor.Security.OIDC.Config do
  @moduledoc """
  Configuration for OIDC authentication.

  Reads from `Application.get_env(:arbor_security, :oidc, [])`.

  ## Configuration

      config :arbor_security, :oidc,
        providers: [
          %{
            issuer: "https://accounts.google.com",
            client_id: "...",
            client_secret: "...",
            scopes: ["openid", "email", "profile"]
          }
        ],
        device_flow: %{
          issuer: "https://accounts.google.com",
          client_id: "..."
        },
        token_cache_path: ".arbor/identity/oidc_tokens.enc"
  """

  @app :arbor_security

  @doc "Returns the full OIDC configuration map."
  @spec get() :: keyword()
  def get do
    Application.get_env(@app, :oidc, [])
  end

  @doc "Whether OIDC is configured with at least one provider or device flow."
  @spec enabled?() :: boolean()
  def enabled? do
    config = get()
    has_providers?(config) or has_device_flow?(config)
  end

  @doc "Returns the list of configured OIDC providers."
  @spec providers() :: [map()]
  def providers do
    get() |> Keyword.get(:providers, [])
  end

  @doc "Returns the device flow configuration, if any."
  @spec device_flow() :: map() | nil
  def device_flow do
    get() |> Keyword.get(:device_flow)
  end

  @doc "Returns the path for encrypted token cache."
  @spec token_cache_path() :: String.t()
  def token_cache_path do
    default = Path.join([System.user_home!(), ".arbor", "identity", "oidc_tokens.enc"])
    get() |> Keyword.get(:token_cache_path, default)
  end

  defp has_providers?(config) do
    case Keyword.get(config, :providers) do
      providers when is_list(providers) and providers != [] -> true
      _ -> false
    end
  end

  defp has_device_flow?(config) do
    case Keyword.get(config, :device_flow) do
      %{issuer: _, client_id: _} -> true
      _ -> false
    end
  end
end
