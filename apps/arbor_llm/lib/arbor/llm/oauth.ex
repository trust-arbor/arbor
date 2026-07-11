defmodule Arbor.LLM.OAuth do
  @moduledoc """
  Subscription OAuth token access for LLM providers that authenticate against their SUBSCRIPTION
  backends (ChatGPT/Codex, xAI/Grok) rather than metered API keys.

  Tokens are held in an Arbor-owned store (`~/.arbor/oauth/<provider>.json`, 0600), imported once
  from the provider CLIs' files (`~/.codex`, `~/.grok`) on first use. There is NO OAuth LOGIN flow
  here yet (that's the OIDC-reuse follow-up — see the roadmap); acquisition piggybacks the CLIs.
  Refresh IS implemented: when the cached access_token is expiring (or grok, which stores only a
  refresh_token), we mint a new one (openai: POST auth.openai.com; xai: OIDC-discovered endpoint)
  and WRITE the rotated tokens BACK to the Arbor store — never the CLI file, so the CLI credential
  is never consumed. The access_token is used as `Authorization: Bearer` against the
  subscription-backend endpoints via `Arbor.LLM.OAuth.Responses` (reverse-engineered from
  ~/code/hermes-agent). Verified live 2026-07-03: agents run on ChatGPT (gpt-5.4-mini) AND SuperGrok
  (grok-4) subscriptions.

  ## SECURITY — Anthropic is HARD-REFUSED

  Using a Claude subscription OAuth token programmatically is against Anthropic's ToS. This module
  returns `{:error, :anthropic_oauth_forbidden}` for any anthropic-family provider and has no code
  path to a Claude token. xAI + OpenAI subscription OAuth is permitted (that's how the CLIs work).
  NOTE: xAI OAuth CAN be tier-gated (403 `xai_oauth_tier_denied`) on some accounts — a SuperGrok
  sub entitled it in testing, but that's account-specific.
  """

  require Logger

  alias Arbor.LLM.{Deadline, Endpoint, ResponseBudget}

  @max_oauth_response_bytes 1_048_576
  @max_access_token_bytes 65_536

  # Keep the "*_oauth" provider atoms alive so callers that String.to_existing_atom a provider
  # string (e.g. the eval runner's normalize_provider) can resolve "openai_oauth"/"xai_oauth".
  @provider_atoms [:openai_oauth, :xai_oauth]
  @doc false
  def provider_atoms, do: @provider_atoms

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
        is_binary(cached) and byte_size(cached) <= @max_access_token_bytes and
            not expiring?(cached, config.skew_s) ->
          {:ok, cached}

        is_binary(tokens["refresh_token"]) ->
          # No valid cached access_token (grok stores ONLY a refresh_token; openai's cached one may
          # be expiring) — mint one via refresh. Providers ROTATE the refresh_token, so we WRITE
          # the rotated tokens back to the Arbor-owned store (~/.arbor/oauth), never the CLI file —
          # so the CLI credential is never consumed and the next call has a fresh refresh_token.
          with {:ok, refreshed} <- refresh(key, config, tokens["refresh_token"]) do
            write_stored(key, Map.merge(tokens, refreshed))
            {:ok, refreshed["access_token"]}
          end

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

  @doc """
  Whether `provider` has an OAuth token FILE on disk — no refresh, no network. Safe to call at
  boot / adapter registration (unlike `available?/1`, which for grok triggers a refresh that
  consumes the rotating refresh_token). Anthropic is refused.
  """
  @spec configured?(atom() | String.t()) :: boolean()
  def configured?(provider) do
    case resolve(provider) do
      {:ok, key, config} ->
        File.exists?(store_path(key)) or File.exists?(Path.expand(config.file))

      _ ->
        false
    end
  end

  # ── internals ──

  # Map provider aliases -> the config key, refusing Anthropic FIRST (before any file read).
  defp resolve(provider) do
    with {:ok, p} <- normalize_oauth_provider(provider) do
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
  end

  defp normalize_oauth_provider(provider) when is_atom(provider),
    do: provider |> Atom.to_string() |> normalize_oauth_provider()

  defp normalize_oauth_provider(provider)
       when is_binary(provider) and byte_size(provider) > 0 and byte_size(provider) <= 256 do
    if String.valid?(provider),
      do: {:ok, String.downcase(provider)},
      else: {:error, :invalid_oauth_provider}
  end

  defp normalize_oauth_provider(_provider), do: {:error, :invalid_oauth_provider}

  # Store-first: read the Arbor-owned copy (~/.arbor/oauth/<key>.json); import from the CLI file on
  # first use. This is what makes rotation safe — write-back keeps the Arbor store current without
  # ever consuming the CLI credential.
  defp read_tokens(key, config) do
    case read_json(store_path(key)) do
      {:ok, %{"access_token" => _} = tokens} -> {:ok, tokens}
      {:ok, %{"refresh_token" => _} = tokens} -> {:ok, tokens}
      _ -> import_from_cli(key, config)
    end
  end

  defp import_from_cli(key, config) do
    with {:ok, tokens} <- read_cli_tokens(key, config) do
      write_stored(key, tokens)
      {:ok, tokens}
    end
  end

  defp read_cli_tokens(:openai, config) do
    with {:ok, json} <- read_json(config.file),
         %{"tokens" => %{} = tokens} <- json do
      {:ok, tokens}
    else
      _ -> {:error, {:no_tokens_in_file, config.file}}
    end
  end

  # Grok stores the token object under a single "https://auth.x.ai::<uuid>" key.
  defp read_cli_tokens(:xai, config) do
    with {:ok, json} <- read_json(config.file),
         [{_key, %{} = tokens} | _] <- Map.to_list(json) do
      {:ok, tokens}
    else
      _ -> {:error, {:no_tokens_in_file, config.file}}
    end
  end

  @store_dir "~/.arbor/oauth"
  @token_json_limits [
    max_bytes: 1_048_576,
    max_nodes: 10_000,
    max_depth: 16,
    max_map_keys: 2_000,
    max_list_items: 10_000
  ]
  @jwt_json_limits [
    max_bytes: 65_536,
    max_nodes: 1_000,
    max_depth: 8,
    max_map_keys: 200,
    max_list_items: 1_000
  ]
  defp store_path(key), do: Path.expand("#{@store_dir}/#{key}.json")

  # Persist tokens to the Arbor-owned store (0600). Returns the tokens for pipelining.
  defp write_stored(key, tokens) do
    path = store_path(key)
    File.mkdir_p(Path.dirname(path))
    File.write(path, Jason.encode!(tokens))
    File.chmod(path, 0o600)
    tokens
  end

  defp read_json(path) do
    with {:ok, body} <- File.read(Path.expand(path)),
         {:ok, json} <- Arbor.LLM.ResponseBudget.decode_json(body, @token_json_limits) do
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
         {:ok, %{"exp" => exp}} <-
           Arbor.LLM.ResponseBudget.decode_json(decoded, @jwt_json_limits),
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
      {:ok, document} ->
        trusted_xai_token_endpoint(document)

      _ ->
        {:error, :xai_discovery_failed}
    end
  end

  @doc false
  def trusted_xai_token_endpoint(%{"token_endpoint" => endpoint}) when is_binary(endpoint) do
    case Endpoint.validate(endpoint, :oauth_xai_token) do
      {:ok, canonical} -> {:ok, canonical}
      {:error, _reason} -> {:error, :untrusted_token_endpoint}
    end
  end

  def trusted_xai_token_endpoint(_document), do: {:error, :untrusted_token_endpoint}

  defp post_token(url, form) do
    case bounded_oauth_request(:post, url, [form: form], 20_000, :oauth_token) do
      {:ok, %{status: 200, body: %{"access_token" => at} = tokens}}
      when is_binary(at) and byte_size(at) <= @max_access_token_bytes ->
        {:ok, tokens}

      {:ok, %{status: status, body: body}} ->
        {:error, {:refresh_failed, status, oauth_error(body)}}

      {:error, reason} ->
        {:error, {:refresh_request_failed, reason}}
    end
  end

  defp safe_get(url) do
    case bounded_oauth_request(:get, url, [], 15_000, :oauth_discovery) do
      {:ok, %{status: 200, body: %{} = body}} -> {:ok, body}
      other -> {:error, other}
    end
  end

  defp bounded_oauth_request(method, url, body_opts, timeout, policy) do
    with {:ok, receipt} <- Deadline.receipt(timeout_ms: timeout),
         {:ok, canonical_url} <- Endpoint.validate(url, policy) do
      Deadline.run(
        fn ->
          request =
            [
              url: canonical_url,
              method: method,
              receive_timeout: max(receipt.deadline_ms - System.monotonic_time(:millisecond), 1)
            ]
            |> Keyword.merge(body_opts)
            |> Req.new()
            |> ResponseBudget.apply_req_receipt(@max_oauth_response_bytes)

          case Req.request(request) do
            {:ok, %Req.Response{private: %{arbor_response_overflow: @max_oauth_response_bytes}}} ->
              {:error, {:oauth_response_bytes_exceeded, @max_oauth_response_bytes}}

            {:ok, %Req.Response{private: %{arbor_response_error: reason}}} ->
              {:error, {:invalid_oauth_response, reason}}

            result ->
              result
          end
        end,
        receipt,
        {:oauth_deadline_exceeded, timeout}
      )
    end
  end

  defp oauth_error(%{"error" => e}), do: e
  defp oauth_error(_), do: :unknown
end
