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
            scopes: ["openid", "email", "profile"],
            allow_http: false
          }
        ],
        device_flow: %{
          issuer: "https://accounts.google.com",
          client_id: "..."
        },
        token_cache_path: ".arbor/identity/oidc_tokens.enc"

  `allow_http` is required for `http://` issuers (local Zitadel). Resolve it
  with `allow_http?/2` from `runtime.exs` / CLI fallbacks — do not set it by
  hand in those two places or it will drift.
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

  @doc """
  Whether an issuer may use `http://`.

  `OIDC_ALLOW_HTTP` is an explicit operator override (`true`/`1`/`yes` or
  `false`/`0`/`no`; unknown values fail closed). When unset:

  * `:prod` stays closed
  * non-prod loopback HTTP issuers (`localhost`, `127.0.0.1`, `::1`) default
    open so the documented local Zitadel compose path works

  Options:

    * `:env` — override the `OIDC_ALLOW_HTTP` value (string or `nil`)
    * `:config_env` — `:dev | :test | :prod`. Defaults to `Mix.env/0` when Mix
      is loaded, otherwise `:prod` (fail closed).
  """
  @spec allow_http?(term(), keyword()) :: boolean()
  def allow_http?(issuer, opts \\ [])

  def allow_http?(issuer, opts) when is_list(opts) do
    case parse_allow_http_env(Keyword.get(opts, :env, System.get_env("OIDC_ALLOW_HTTP"))) do
      {:ok, value} ->
        value

      :unset ->
        default_allow_http?(issuer, Keyword.get(opts, :config_env, inferred_config_env()))
    end
  end

  defp inferred_config_env do
    if Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) do
      Mix.env()
    else
      :prod
    end
  end

  defp parse_allow_http_env(nil), do: :unset

  defp parse_allow_http_env(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> :unset
      flag when flag in ["true", "1", "yes"] -> {:ok, true}
      flag when flag in ["false", "0", "no"] -> {:ok, false}
      _unknown -> {:ok, false}
    end
  end

  defp parse_allow_http_env(_value), do: {:ok, false}

  defp default_allow_http?(_issuer, :prod), do: false
  defp default_allow_http?(issuer, _config_env), do: loopback_http_issuer?(issuer)

  defp loopback_http_issuer?(issuer) when is_binary(issuer) do
    case URI.new(issuer) do
      {:ok, %URI{scheme: "http", host: host}} when is_binary(host) ->
        String.downcase(host) in ["localhost", "127.0.0.1", "::1"]

      _ ->
        false
    end
  end

  defp loopback_http_issuer?(_issuer), do: false

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
