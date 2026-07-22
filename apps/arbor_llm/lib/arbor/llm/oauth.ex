defmodule Arbor.LLM.OAuth do
  @moduledoc """
  Subscription OAuth token access for LLM providers that authenticate against their SUBSCRIPTION
  backends (ChatGPT/Codex, xAI/Grok) rather than metered API keys.

  Tokens are held in a versioned Arbor credential envelope
  (`~/.arbor/oauth/<provider>.json`, 0600). Only an explicitly Arbor-owned family acquired by an
  Arbor login may be refreshed or published. Legacy ownerless stores are intentionally refused and
  left byte-for-byte unchanged; operators must relogin once an independent Arbor login flow exists.
  Codex/Grok CLI credentials are never imported, copied, refreshed, or modified.

  Source-owned envelopes are reserved for a future access-token read-through implementation and
  currently fail explicitly. This module does not provide an OAuth login/device flow.

  Concurrent in-process refresh is single-flighted per provider via a `:global` transaction.
  Successful rotating refreshes fail closed unless the full envelope is durably published with
  atomic same-directory rename. Provider refresh responses may replace only token payload fields;
  ownership metadata always comes from the validated stored envelope.

  ## SECURITY — Anthropic is HARD-REFUSED

  Using a Claude subscription OAuth token programmatically is against Anthropic's ToS. This module
  returns `{:error, :anthropic_oauth_forbidden}` for any anthropic-family provider and has no code
  path to a Claude token. xAI + OpenAI subscription OAuth is permitted (that's how the CLIs work).
  NOTE: xAI OAuth CAN be tier-gated (403 `xai_oauth_tier_denied`) on some accounts — a SuperGrok
  sub entitled it in testing, but that's account-specific.
  """

  alias Arbor.LLM.{Deadline, Endpoint, ResponseBudget}
  alias Arbor.Contracts.LLM.AuthProvenance

  @max_oauth_response_bytes 1_048_576
  @max_access_token_bytes 65_536
  @max_refresh_token_bytes 65_536
  @max_token_json_bytes 1_048_576
  @max_account_id_bytes 512
  @max_generation 1_000_000_000_000
  @credential_version 1
  @credential_fields ~w(version provider account_id origin owner source generation tokens)
  @token_fields ~w(access_token refresh_token)
  # Cover one concurrent refresh (~20s) plus margin; lock is released on owner death.
  @refresh_lock_retries 20
  @default_store_dir "~/.arbor/oauth"

  # Keep the "*_oauth" provider atoms alive so callers that String.to_existing_atom a provider
  # string (e.g. the eval runner's normalize_provider) can resolve "openai_oauth"/"xai_oauth".
  @provider_atoms [:openai_oauth, :xai_oauth]
  @doc false
  def provider_atoms, do: @provider_atoms

  # Per-provider refresh endpoint + client_id and JWT-expiry skew. Acquisition is out of scope.
  @providers %{
    openai: %{
      refresh_url: "https://auth.openai.com/oauth/token",
      client_id: "app_EMoamEEZ73f0CkXaXp7hrann",
      skew_s: 120
    },
    xai: %{
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
         {:ok, credential} <- read_credential(key) do
      case credential.owner do
        "arbor_owned" ->
          case usable_access_token(credential.tokens, config) do
            {:ok, token} -> {:ok, token}
            :refresh -> refresh_singleflight(key, config)
          end

        "source_owned" ->
          {:error, :oauth_source_owned_unsupported}
      end
    end
  end

  @doc "The ChatGPT-Account-ID header value for OpenAI (from the token file). nil otherwise."
  @spec account_id(atom() | String.t()) :: String.t() | nil
  def account_id(provider) do
    with {:ok, :openai, _config} <- resolve(provider),
         {:ok, %{owner: "arbor_owned", account_id: account_id}} <- read_credential(:openai) do
      account_id
    else
      _ -> nil
    end
  end

  @doc "Whether `provider` has a usable subscription-OAuth token on disk (and isn't Anthropic)."
  @spec available?(atom() | String.t()) :: boolean()
  def available?(provider), do: match?({:ok, _}, access_token(provider))

  @doc """
  Whether `provider` has a valid Arbor-owned credential envelope — no refresh and no network.
  Legacy/raw stores, CLI files, malformed envelopes, and unsupported source-owned mode do not make
  an adapter discoverable. Anthropic is refused.
  """
  @spec configured?(atom() | String.t()) :: boolean()
  def configured?(provider) do
    case resolve(provider) do
      {:ok, key, _config} ->
        match?({:ok, %{owner: "arbor_owned"}}, read_credential(key))

      _ ->
        false
    end
  end

  @doc "Return bounded public ownership provenance without credential material."
  @spec provenance(atom() | String.t()) :: {:ok, AuthProvenance.t()} | {:error, term()}
  def provenance(provider) do
    with {:ok, key, _config} <- resolve(provider),
         {:ok, credential} <- read_credential(key),
         :ok <- provenance_supported?(credential.owner),
         {:ok, provenance} <-
           AuthProvenance.new(%{
             version: AuthProvenance.schema_version(),
             provider: credential.provider,
             account_id: credential.account_id,
             origin: credential.origin,
             owner: credential.owner,
             source: credential.source,
             generation: credential.generation
           }) do
      {:ok, provenance}
    end
  end

  defp provenance_supported?("arbor_owned"), do: :ok
  defp provenance_supported?("source_owned"), do: {:error, :oauth_source_owned_unsupported}

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

  defp read_credential(key) do
    case read_json(store_path(key)) do
      {:ok, %{} = json} -> decode_credential(key, json)
      {:ok, _other} -> {:error, :oauth_credential_invalid}
      {:error, {:token_file_unreadable, :enoent}} -> {:error, :oauth_login_required}
      {:error, reason} -> {:error, {:oauth_token_store_read_failed, reason}}
    end
  end

  # The migration break is intentional: a raw token map has no trustworthy owner. Refusal must
  # happen before any token use or write so the operator can inspect and migrate it explicitly.
  defp decode_credential(_key, %{"access_token" => _token}),
    do: {:error, :oauth_credential_migration_required}

  defp decode_credential(_key, %{"refresh_token" => _token}),
    do: {:error, :oauth_credential_migration_required}

  defp decode_credential(key, envelope) do
    expected_provider = Atom.to_string(key)

    with :ok <- exact_fields(envelope, @credential_fields),
         @credential_version <- envelope["version"],
         ^expected_provider <- envelope["provider"],
         {:ok, account_id} <- validate_account_id(key, envelope["account_id"]),
         {:ok, generation} <- validate_generation(envelope["generation"]),
         {:ok, metadata} <-
           validate_ownership_metadata(
             key,
             envelope["origin"],
             envelope["owner"],
             envelope["source"]
           ),
         {:ok, tokens} <- validate_owned_tokens(metadata.owner, envelope["tokens"]) do
      {:ok,
       Map.merge(metadata, %{
         version: @credential_version,
         provider: expected_provider,
         account_id: account_id,
         generation: generation,
         tokens: tokens
       })}
    else
      _ -> {:error, :oauth_credential_invalid}
    end
  end

  defp exact_fields(%{} = value, fields) do
    if map_size(value) == length(fields) and Enum.sort(Map.keys(value)) == Enum.sort(fields),
      do: :ok,
      else: {:error, :invalid_fields}
  end

  defp exact_fields(_value, _fields), do: {:error, :invalid_fields}

  defp validate_account_id(:openai, account_id)
       when is_binary(account_id) and byte_size(account_id) > 0 and
              byte_size(account_id) <= @max_account_id_bytes do
    if valid_secret_text?(account_id), do: {:ok, account_id}, else: {:error, :invalid_account_id}
  end

  defp validate_account_id(:xai, nil), do: {:ok, nil}

  defp validate_account_id(:xai, account_id)
       when is_binary(account_id) and byte_size(account_id) > 0 and
              byte_size(account_id) <= @max_account_id_bytes do
    if valid_secret_text?(account_id), do: {:ok, account_id}, else: {:error, :invalid_account_id}
  end

  defp validate_account_id(_key, _account_id), do: {:error, :invalid_account_id}

  defp validate_generation(generation)
       when is_integer(generation) and generation >= 0 and generation <= @max_generation,
       do: {:ok, generation}

  defp validate_generation(_generation), do: {:error, :invalid_generation}

  defp validate_ownership_metadata(
         _key,
         "arbor_login",
         "arbor_owned",
         "arbor_oauth_store"
       ) do
    {:ok, %{origin: "arbor_login", owner: "arbor_owned", source: "arbor_oauth_store"}}
  end

  defp validate_ownership_metadata(:openai, "external_cli", "source_owned", "codex_file") do
    {:ok, %{origin: "external_cli", owner: "source_owned", source: "codex_file"}}
  end

  defp validate_ownership_metadata(:xai, "external_cli", "source_owned", "grok_file") do
    {:ok, %{origin: "external_cli", owner: "source_owned", source: "grok_file"}}
  end

  defp validate_ownership_metadata(_key, _origin, _owner, _source),
    do: {:error, :invalid_ownership_metadata}

  defp validate_owned_tokens("source_owned", tokens) when tokens == %{}, do: {:ok, %{}}

  defp validate_owned_tokens("arbor_owned", %{} = tokens) do
    with :ok <- exact_fields(tokens, @token_fields),
         {:ok, access_token} <- validate_token(tokens["access_token"], @max_access_token_bytes),
         {:ok, refresh_token} <-
           validate_token(tokens["refresh_token"], @max_refresh_token_bytes) do
      {:ok, %{"access_token" => access_token, "refresh_token" => refresh_token}}
    end
  end

  defp validate_owned_tokens(_owner, _tokens), do: {:error, :invalid_token_payload}

  defp validate_token(token, maximum)
       when is_binary(token) and byte_size(token) > 0 and byte_size(token) <= maximum do
    if valid_secret_text?(token), do: {:ok, token}, else: {:error, :invalid_token}
  end

  defp validate_token(_token, _maximum), do: {:error, :invalid_token}

  defp valid_secret_text?(value) when is_binary(value) do
    String.valid?(value) and not String.match?(value, ~r/[\x00-\x1F\x7F]/)
  end

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

  defp store_dir do
    case Application.get_env(:arbor_llm, :oauth_store_dir) do
      dir when is_binary(dir) and byte_size(dir) > 0 ->
        Path.expand(dir)

      _ ->
        Path.expand(@default_store_dir)
    end
  end

  defp store_path(key), do: Path.join(store_dir(), "#{key}.json")

  defp usable_access_token(tokens, config) when is_map(tokens) do
    cached = tokens["access_token"]

    if is_binary(cached) and byte_size(cached) <= @max_access_token_bytes and
         not expiring?(cached, config.skew_s) do
      {:ok, cached}
    else
      :refresh
    end
  end

  defp refresh_singleflight(key, config) do
    id = {{__MODULE__, :refresh, key}, self()}
    nodes = [node() | Node.list()]

    case :global.trans(
           id,
           fn -> refresh_under_lock(key, config) end,
           nodes,
           @refresh_lock_retries
         ) do
      :aborted ->
        {:error, :oauth_refresh_lock_aborted}

      result ->
        result
    end
  end

  # Called only while holding the provider-scoped :global lock.
  defp refresh_under_lock(key, config) do
    # Double-check the local store: another Arbor caller may have already refreshed + persisted.
    case read_credential(key) do
      {:ok, %{owner: "arbor_owned"} = latest} ->
        case usable_access_token(latest.tokens, config) do
          {:ok, token} ->
            {:ok, token}

          :refresh ->
            refresh_and_persist(key, config, latest)
        end

      {:ok, %{owner: "source_owned"}} ->
        {:error, :oauth_source_owned_unsupported}

      {:error, {:oauth_token_store_read_failed, reason}} ->
        {:error, {:oauth_token_store_reread_failed, reason}}

      {:error, reason} ->
        # The pre-lock snapshot may contain a rotating refresh token already consumed by
        # another lock holder. Never reuse it when the authoritative store cannot be reread.
        {:error, {:oauth_token_store_reread_failed, reason}}
    end
  end

  defp refresh_and_persist(key, config, %{owner: "arbor_owned"} = credential) do
    refresh_token = credential.tokens["refresh_token"]

    with {:ok, refreshed} <- refresh(key, config, refresh_token),
         {:ok, access} <- validate_refreshed_access_token(refreshed),
         {:ok, effective_refresh} <-
           effective_refresh_token(refreshed, credential.tokens["refresh_token"]),
         {:ok, generation} <- next_generation(credential.generation),
         updated = %{
           credential
           | generation: generation,
             tokens: %{
               "access_token" => access,
               "refresh_token" => effective_refresh
             }
         },
         :ok <- write_stored(key, updated) do
      {:ok, access}
    end
  end

  # Validate access-token shape/size BEFORE replacing durable credentials so a
  # malformed refresh response cannot clobber a still-valid rotated token set.
  defp validate_refreshed_access_token(%{"access_token" => access})
       when is_binary(access) and byte_size(access) > 0 and
              byte_size(access) <= @max_access_token_bytes do
    if String.valid?(access) do
      {:ok, access}
    else
      {:error, {:invalid_refreshed_access_token, :invalid_utf8}}
    end
  end

  defp validate_refreshed_access_token(%{"access_token" => access}) when is_binary(access) do
    {:error, {:invalid_refreshed_access_token, :oversized}}
  end

  defp validate_refreshed_access_token(_refreshed) do
    {:error, {:invalid_refreshed_access_token, :missing_or_not_binary}}
  end

  defp effective_refresh_token(%{"refresh_token" => refresh_token}, _stored) do
    case validate_token(refresh_token, @max_refresh_token_bytes) do
      {:ok, token} -> {:ok, token}
      {:error, _reason} -> {:error, {:invalid_refreshed_refresh_token, :invalid}}
    end
  end

  defp effective_refresh_token(_refreshed, stored) do
    case validate_token(stored, @max_refresh_token_bytes) do
      {:ok, token} -> {:ok, token}
      {:error, _reason} -> {:error, {:invalid_refreshed_refresh_token, :missing_or_not_binary}}
    end
  end

  defp next_generation(generation)
       when is_integer(generation) and generation >= 0 and generation < @max_generation,
       do: {:ok, generation + 1}

  defp next_generation(_generation), do: {:error, :oauth_generation_exhausted}

  # Persist tokens to Arbor's local store via atomic same-directory publication.
  # Encode first; exclusive temp (mode 0600 before content); write + fsync; rename over target;
  # fsync the parent directory so the directory entry is crash-durable; ensure final mode 0600.
  # Never delete the old target before rename. Failures clean the temp and return an error.
  defp write_stored(key, credential) do
    with {:ok, envelope} <- encode_credential(key, credential),
         {:ok, json} <- encode_token_json(envelope) do
      path = store_path(key)
      dir = Path.dirname(path)

      with :ok <- ensure_store_dir(dir),
           {:ok, tmp} <- create_temp_path(dir, key),
           :ok <- write_temp_token_file(tmp, json) do
        case File.rename(tmp, path) do
          :ok ->
            with :ok <- fsync_directory(dir),
                 :ok <- ensure_final_mode(path) do
              :ok
            end

          {:error, reason} ->
            _ = File.rm(tmp)
            {:error, {:token_store_write_failed, reason}}
        end
      end
    end
  end

  defp encode_credential(key, credential) do
    envelope = %{
      "version" => credential.version,
      "provider" => credential.provider,
      "account_id" => credential.account_id,
      "origin" => credential.origin,
      "owner" => credential.owner,
      "source" => credential.source,
      "generation" => credential.generation,
      "tokens" => credential.tokens
    }

    with {:ok, validated} <- decode_credential(key, envelope) do
      {:ok,
       %{
         "version" => validated.version,
         "provider" => validated.provider,
         "account_id" => validated.account_id,
         "origin" => validated.origin,
         "owner" => validated.owner,
         "source" => validated.source,
         "generation" => validated.generation,
         "tokens" => validated.tokens
       }}
    end
  end

  # Directory fsync makes the rename durable across crash/power loss on filesystems
  # that only guarantee directory-entry durability after sync of the parent dir.
  # OTP requires the :directory mode; plain [:raw, :read] returns :eisdir.
  defp fsync_directory(dir) when is_binary(dir) do
    case :file.open(dir, [:raw, :read, :directory]) do
      {:ok, io} ->
        try do
          case :file.sync(io) do
            :ok -> :ok
            {:error, reason} -> {:error, {:token_store_write_failed, {:dir_fsync_failed, reason}}}
          end
        after
          _ = close_io_silent(io)
        end

      {:error, reason} ->
        {:error, {:token_store_write_failed, {:dir_open_failed, reason}}}
    end
  end

  defp encode_token_json(tokens) when is_map(tokens) do
    case Jason.encode(tokens) do
      {:ok, json} when is_binary(json) and byte_size(json) <= @max_token_json_bytes ->
        {:ok, json}

      {:ok, json} when is_binary(json) ->
        {:error, {:token_store_write_failed, :token_json_too_large}}

      {:error, reason} ->
        {:error, {:token_store_write_failed, {:encode_failed, reason}}}
    end
  end

  defp encode_token_json(_tokens), do: {:error, {:token_store_write_failed, :invalid_tokens}}

  defp ensure_store_dir(dir) do
    case File.mkdir_p(dir) do
      :ok ->
        # Best-effort private directory; content publication still enforces file mode 0600.
        _ = File.chmod(dir, 0o700)
        :ok

      {:error, reason} ->
        {:error, {:token_store_write_failed, reason}}
    end
  end

  defp create_temp_path(dir, key) do
    suffix =
      Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    tmp =
      Path.join(dir, ".#{key}.#{System.unique_integer([:positive])}.#{suffix}.tmp")

    {:ok, tmp}
  end

  defp write_temp_token_file(tmp, json) do
    # Exclusive create so concurrent writers never share a temp path.
    case :file.open(tmp, [:raw, :binary, :write, :exclusive]) do
      {:ok, io} ->
        try do
          # Mode 0600 BEFORE writing credential bytes.
          with :ok <- :file.change_mode(tmp, 0o600),
               :ok <- :file.write(io, json),
               :ok <- :file.sync(io),
               :ok <- :file.close(io) do
            :ok
          else
            {:error, reason} ->
              _ = close_io_silent(io)
              _ = File.rm(tmp)
              {:error, {:token_store_write_failed, reason}}
          end
        rescue
          e ->
            _ = close_io_silent(io)
            _ = File.rm(tmp)
            {:error, {:token_store_write_failed, Exception.message(e)}}
        catch
          kind, reason ->
            _ = close_io_silent(io)
            _ = File.rm(tmp)
            {:error, {:token_store_write_failed, {kind, reason}}}
        end

      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, {:token_store_write_failed, reason}}
    end
  end

  defp ensure_final_mode(path) do
    case File.chmod(path, 0o600) do
      :ok ->
        case File.stat(path) do
          {:ok, %{mode: mode}} when Bitwise.band(mode, 0o777) == 0o600 ->
            :ok

          {:ok, _} ->
            {:error, {:token_store_write_failed, :insecure_mode}}

          {:error, reason} ->
            {:error, {:token_store_write_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:token_store_write_failed, reason}}
    end
  end

  defp close_io_silent(io) do
    try do
      :file.close(io)
    catch
      _, _ -> :ok
    end
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

  # Test seam: Application env `:oauth_refresh_fun` (arity 3) replaces network refresh.
  # Production never sets this; public access_token/1 behavior is unchanged when unset.
  defp refresh(key, config, refresh_token) do
    result =
      case Application.get_env(:arbor_llm, :oauth_refresh_fun) do
        fun when is_function(fun, 3) -> fun.(key, config, refresh_token)
        _ -> do_refresh(key, config, refresh_token)
      end

    normalize_refresh_result(result)
  end

  defp normalize_refresh_result({:ok, %{} = refreshed}), do: {:ok, refreshed}

  defp normalize_refresh_result({:error, reason}) do
    if refresh_family_invalid?(reason),
      do: {:error, :oauth_relogin_required},
      else: {:error, :oauth_refresh_failed}
  end

  defp normalize_refresh_result(_result), do: {:error, :oauth_refresh_failed}

  defp refresh_family_invalid?(reason) do
    refresh_family_invalid?(reason, 4, 32)
  rescue
    _exception -> false
  catch
    _kind, _reason -> false
  end

  defp refresh_family_invalid?(_reason, _depth, remaining) when remaining <= 0, do: false
  defp refresh_family_invalid?(_reason, depth, _remaining) when depth <= 0, do: false

  defp refresh_family_invalid?(reason, _depth, _remaining)
       when reason in [:refresh_token_reused, :refresh_token_invalidated, :invalid_grant],
       do: true

  defp refresh_family_invalid?(reason, _depth, _remaining) when is_binary(reason) do
    bounded = binary_part(reason, 0, min(byte_size(reason), 1_024)) |> String.downcase()

    Enum.any?(
      ["refresh_token_reused", "refresh_token_invalidated", "invalid_grant"],
      &String.contains?(bounded, &1)
    )
  end

  defp refresh_family_invalid?(reason, depth, remaining) when is_tuple(reason) do
    reason
    |> Tuple.to_list()
    |> Enum.take(remaining)
    |> Enum.any?(&refresh_family_invalid?(&1, depth - 1, remaining - 1))
  end

  defp refresh_family_invalid?(reason, depth, remaining) when is_list(reason) do
    reason
    |> Enum.take(remaining)
    |> Enum.any?(&refresh_family_invalid?(&1, depth - 1, remaining - 1))
  end

  defp refresh_family_invalid?(reason, depth, remaining) when is_map(reason) do
    reason
    |> Map.to_list()
    |> Enum.take(remaining)
    |> Enum.any?(&refresh_family_invalid?(&1, depth - 1, remaining - 1))
  end

  defp refresh_family_invalid?(_reason, _depth, _remaining), do: false

  defp do_refresh(:openai, config, refresh_token) do
    post_token(config.refresh_url, %{
      "grant_type" => "refresh_token",
      "refresh_token" => refresh_token,
      "client_id" => config.client_id
    })
  end

  defp do_refresh(:xai, config, refresh_token) do
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

      {:ok, %{status: _status, body: body}} ->
        if refresh_family_invalid?(body),
          do: {:error, :oauth_relogin_required},
          else: {:error, :oauth_refresh_failed}

      {:error, _reason} ->
        {:error, :oauth_refresh_failed}
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
end
