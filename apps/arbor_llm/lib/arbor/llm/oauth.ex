defmodule Arbor.LLM.OAuth do
  @moduledoc """
  Subscription OAuth token access for LLM providers that authenticate against their SUBSCRIPTION
  backends (ChatGPT/Codex, xAI/Grok) rather than metered API keys.

  Piggybacks on the provider CLIs' stored tokens — the user has already run `codex login` /
  `grok login`, so there is NO OAuth login flow here, only READ + JWT-`exp` expiry check
  (refresh is a follow-up: reactive refresh-on-401 against the endpoints in `@providers`). The
  returned access_token is used as `Authorization: Bearer` against the subscription-backend
  endpoints via the Responses-API adapter (mechanism reverse-engineered from ~/code/hermes-agent).

  ## SECURITY — Anthropic is HARD-REFUSED

  Using a Claude subscription OAuth token programmatically is against Anthropic's ToS. This module
  returns `{:error, :anthropic_oauth_forbidden}` for any anthropic-family provider and has no code
  path to a Claude token. xAI + OpenAI subscription OAuth is permitted (that's how the CLIs work).
  NOTE: xAI OAuth is frequently tier-gated (403 `xai_oauth_tier_denied`) — a SuperGrok sub may not
  entitle API access; there is no fix for that here (use ACP for Grok).
  """

  require Logger

  # Per-provider: token file, refresh endpoint + client_id, JWT-exp skew. token acquisition (login)
  # is out of scope — piggyback the CLI files.
  @providers %{
    openai: %{
      file: "~/.codex/auth.json",
      refresh_url: "https://auth.openai.com/oauth/token",
      client_id: "app_EMoamEEZ73f0CkXaXp7hrann",
      skew_s: 120
    },
    xai: %{
      file: "~/.grok/auth.json",
      discovery_url: "https://auth.x.ai/.well-known/openid-configuration",
      client_id: "b1a00492-073a-47ea-816f-4c329264a828",
      skew_s: 3600
    }
  }

  @doc """
  Return a valid access token for `provider`. `{:ok, token}` or `{:error, reason}`.

  Anthropic-family providers are refused (`:anthropic_oauth_forbidden`). Warns (not errors) when
  the token's JWT `exp` is within the skew window — refresh-on-401 is the follow-up.
  """
  @spec access_token(atom() | String.t()) :: {:ok, String.t()} | {:error, term()}
  def access_token(provider) do
    with {:ok, key, config} <- resolve(provider),
         {:ok, tokens} <- read_tokens(key, config) do
      cached = tokens["access_token"]

      cond do
        is_binary(cached) and not expiring?(cached, config.skew_s) ->
          {:ok, cached}

        is_binary(tokens["refresh_token"]) ->
          # No valid cached access_token (grok stores ONLY a refresh_token; openai's cached one may
          # be expiring) — mint one via refresh. NOTE: providers ROTATE the refresh_token, so a
          # robust impl must persist the rotation (follow-up: an Arbor-owned token store, NOT the
          # CLI file). For now we mint per-call and rely on the CLI to keep the refresh_token warm.
          refresh(key, config, tokens["refresh_token"])

        true ->
          {:error, :no_usable_token}
      end
    end
  end

  @doc "The ChatGPT-Account-ID header value for OpenAI (from the token file). nil otherwise."
  @spec account_id(atom() | String.t()) :: String.t() | nil
  def account_id(provider) do
    with {:ok, :openai, config} <- resolve(provider),
         {:ok, tokens} <- read_tokens(:openai, config) do
      tokens["account_id"]
    else
      _ -> nil
    end
  end

  @doc "Whether `provider` has a usable subscription-OAuth token on disk (and isn't Anthropic)."
  @spec available?(atom() | String.t()) :: boolean()
  def available?(provider), do: match?({:ok, _}, access_token(provider))

  # ── internals ──

  # Map provider aliases -> the config key, refusing Anthropic FIRST (before any file read).
  defp resolve(provider) do
    p = provider |> to_string() |> String.downcase()

    cond do
      # substring match (no String.to_atom) covers claude / claude-code / claude_code / anthropic
      p =~ "claude" or p =~ "anthropic" ->
        {:error, :anthropic_oauth_forbidden}

      p in ~w(openai codex chatgpt gpt) ->
        {:ok, :openai, @providers.openai}

      p in ~w(xai grok x-ai) ->
        {:ok, :xai, @providers.xai}

      true ->
        {:error, {:no_oauth_provider, p}}
    end
  end

  defp read_tokens(:openai, config) do
    with {:ok, json} <- read_json(config.file),
         %{"tokens" => %{} = tokens} <- json do
      {:ok, tokens}
    else
      _ -> {:error, {:no_tokens_in_file, config.file}}
    end
  end

  # Grok stores the token object under a single "https://auth.x.ai::<uuid>" key.
  defp read_tokens(:xai, config) do
    with {:ok, json} <- read_json(config.file),
         [{_key, %{} = tokens} | _] <- Map.to_list(json) do
      {:ok, tokens}
    else
      _ -> {:error, {:no_tokens_in_file, config.file}}
    end
  end

  defp read_json(path) do
    with {:ok, body} <- File.read(Path.expand(path)),
         {:ok, json} <- Jason.decode(body) do
      {:ok, json}
    else
      {:error, reason} -> {:error, {:token_file_unreadable, reason}}
    end
  end

  # A JWT access token is `<h>.<payload>.<sig>`; the payload has an `exp` (unix seconds). Expiring
  # if now + skew >= exp. Opaque/non-JWT tokens can't be checked → treat as not-expiring.
  defp expiring?(token, skew_s) do
    with [_h, payload, _s] <- String.split(token, "."),
         {:ok, decoded} <- Base.url_decode64(payload, padding: false),
         {:ok, %{"exp" => exp}} <- Jason.decode(decoded),
         true <- is_integer(exp) do
      System.system_time(:second) + skew_s >= exp
    else
      _ -> false
    end
  end

  # ── refresh: mint an access_token from a refresh_token (form-encoded OAuth token endpoint) ──

  defp refresh(:openai, config, refresh_token) do
    post_token(config.refresh_url, %{
      "grant_type" => "refresh_token",
      "refresh_token" => refresh_token,
      "client_id" => config.client_id
    })
  end

  defp refresh(:xai, config, refresh_token) do
    with {:ok, token_endpoint} <- xai_token_endpoint(config.discovery_url) do
      post_token(token_endpoint, %{
        "grant_type" => "refresh_token",
        "client_id" => config.client_id,
        "refresh_token" => refresh_token
      })
    end
  end

  # xAI's token endpoint comes from OIDC discovery; validate it stays on the x.ai origin.
  defp xai_token_endpoint(discovery_url) do
    case safe_get(discovery_url) do
      {:ok, %{"token_endpoint" => te}} when is_binary(te) ->
        if String.contains?(te, "x.ai"), do: {:ok, te}, else: {:error, :untrusted_token_endpoint}

      _ ->
        {:error, :xai_discovery_failed}
    end
  end

  defp post_token(url, form) do
    case Req.post(url, form: form, receive_timeout: 20_000) do
      {:ok, %{status: 200, body: %{"access_token" => at}}} when is_binary(at) ->
        {:ok, at}

      {:ok, %{status: status, body: body}} ->
        {:error, {:refresh_failed, status, oauth_error(body)}}

      {:error, reason} ->
        {:error, {:refresh_request_failed, reason}}
    end
  end

  defp safe_get(url) do
    case Req.get(url, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: %{} = body}} -> {:ok, body}
      other -> {:error, other}
    end
  end

  defp oauth_error(%{"error" => e}), do: e
  defp oauth_error(_), do: :unknown
end
