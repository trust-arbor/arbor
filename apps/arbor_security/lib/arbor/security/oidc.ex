defmodule Arbor.Security.OIDC do
  @moduledoc """
  OIDC authentication facade for Arbor.

  Orchestrates the full authentication flow:
  1. Device flow (for CLI) or token verification (for cached tokens)
  2. OIDC claim extraction
  3. Persistent human keypair binding (via IdentityStore)
  4. Identity registration + capability grants
  5. Signer function creation

  ## Usage

      # Full device flow (interactive CLI)
      {:ok, agent_id, signer} = Arbor.Security.OIDC.authenticate_device_flow(config)

      # Verify an existing JWT
      {:ok, agent_id, signer} = Arbor.Security.OIDC.authenticate_token(id_token, config)
  """

  alias Arbor.Contracts.Security.Identity, as: IdentityContract
  alias Arbor.Security.Crypto
  alias Arbor.Security.Identity.Registry, as: IdentityRegistry
  alias Arbor.Security.OIDC.Config
  alias Arbor.Security.OIDC.DeviceFlow
  alias Arbor.Security.OIDC.IdentityStore
  alias Arbor.Security.OIDC.TokenVerifier
  alias Arbor.Security.SigningKeyStore

  require Logger

  @token_cache_encryption_info "arbor-oidc-token-cache-v1"

  @doc """
  Run the full device authorization flow (interactive CLI).

  1. Starts device flow → prints URL + user code to stderr
  2. Polls until user authorizes
  3. Verifies the ID token
  4. Loads or creates persistent keypair
  5. Registers identity + grants capabilities
  6. Caches the token for future sessions

  Returns `{:ok, agent_id, signer}` on success.
  """
  @spec authenticate_device_flow(map() | nil) :: {:ok, String.t(), function()} | {:error, term()}
  def authenticate_device_flow(config \\ nil) do
    config = config || Config.device_flow()

    if is_nil(config) do
      {:error, :no_device_flow_configured}
    else
      with {:ok, device_response} <- DeviceFlow.start(config),
           :ok <- print_device_flow_instructions(device_response),
           {:ok, token_response} <- DeviceFlow.poll(config, device_response),
           id_token when is_binary(id_token) <- Map.get(token_response, "id_token"),
           {:ok, claims} <- TokenVerifier.verify(id_token, config),
           {:ok, identity, status} <- IdentityStore.load_or_create(claims),
           :ok <- ensure_registered(identity),
           :ok <- ensure_capabilities(identity.agent_id) do
        cache_token(token_response, claims)
        signer = Arbor.Security.make_signer(identity.agent_id, identity.private_key)
        log_auth_result(identity, status)

        {:ok, identity.agent_id, signer}
      else
        nil -> {:error, :no_id_token_in_response}
        {:error, _} = error -> error
      end
    end
  end

  @doc """
  Authenticate using an existing ID token (e.g., from cache).

  Verifies the token, loads the persistent keypair, and returns a signer.
  """
  @spec authenticate_token(String.t(), map() | nil) ::
          {:ok, String.t(), function()} | {:error, term()}
  def authenticate_token(id_token, config \\ nil) do
    config = config || resolve_provider_for_token(id_token)

    if is_nil(config) do
      {:error, :no_matching_provider}
    else
      with {:ok, claims} <- TokenVerifier.verify(id_token, config),
           {:ok, identity, _status} <- IdentityStore.load_or_create(claims),
           :ok <- ensure_registered(identity),
           :ok <- ensure_capabilities(identity.agent_id) do
        signer = Arbor.Security.make_signer(identity.agent_id, identity.private_key)
        {:ok, identity.agent_id, signer}
      end
    end
  end

  @doc """
  Load a cached OIDC token from disk.

  Returns `{:ok, token_map}` if a valid (non-expired) cached token exists,
  `:expired` if cached but expired, or `{:error, reason}` on failure.
  """
  @spec load_cached_token() :: {:ok, map()} | :expired | {:error, term()}
  def load_cached_token do
    path = Config.token_cache_path()

    case File.read(path) do
      {:ok, encrypted} ->
        decrypt_cached_token(encrypted)

      {:error, :enoent} ->
        {:error, :no_cached_token}

      {:error, reason} ->
        {:error, {:cache_read_failed, reason}}
    end
  end

  @doc """
  Cache an OIDC token response to disk (encrypted).
  """
  @spec cache_token(map(), map()) :: :ok | {:error, term()}
  def cache_token(token_response, claims) do
    path = Config.token_cache_path()

    cache_data = %{
      "token_response" => token_response,
      "claims" => claims,
      "cached_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    with {:ok, enc_key} <- get_cache_encryption_key(),
         {:ok, json} <- Jason.encode(cache_data) do
      {ciphertext, iv, tag} = Crypto.encrypt(json, enc_key)

      # Pack: iv (12) + tag (16) + ciphertext
      packed = iv <> tag <> ciphertext

      dir = Path.dirname(path)
      File.mkdir_p!(dir)

      case File.write(path, packed) do
        :ok ->
          File.chmod(path, 0o600)
          :ok

        {:error, reason} ->
          {:error, {:cache_write_failed, reason}}
      end
    end
  end

  # --- Private ---

  defp print_device_flow_instructions(response) do
    verification_uri =
      response["verification_uri_complete"] || response["verification_uri"]

    user_code = response["user_code"]

    IO.puts(:stderr, "")
    IO.puts(:stderr, "  Arbor OIDC Authentication")
    IO.puts(:stderr, "  ─────────────────────────")
    IO.puts(:stderr, "  Visit: #{verification_uri}")

    if user_code do
      IO.puts(:stderr, "  Code:  #{user_code}")
    end

    IO.puts(:stderr, "")
    IO.puts(:stderr, "  Waiting for authorization...")
    IO.puts(:stderr, "")
    :ok
  end

  defp ensure_registered(identity) do
    if Code.ensure_loaded?(IdentityRegistry) and
         Process.whereis(IdentityRegistry) != nil do
      public_identity = IdentityContract.public_only(identity)

      case Arbor.Security.register_identity(public_identity) do
        :ok -> :ok
        {:error, {:already_registered, _}} -> :ok
        {:error, reason} -> {:error, {:registration_failed, reason}}
      end
    else
      # Registry not running — skip (dev/test without full security stack)
      :ok
    end
  end

  defp ensure_capabilities(agent_id) do
    if Code.ensure_loaded?(Arbor.Security) and
         function_exported?(Arbor.Security, :grant, 1) do
      capabilities = [
        "arbor://orchestrator/execute/**",
        "arbor://actions/execute/**"
      ]

      Enum.each(capabilities, fn resource ->
        # Idempotent — grant silently if already exists
        case Arbor.Security.grant(principal: agent_id, resource: resource, action: :execute) do
          {:ok, _cap} -> :ok
          {:error, _} -> :ok
        end
      end)

      :ok
    else
      :ok
    end
  end

  defp resolve_provider_for_token(id_token) do
    with {:ok, claims} <- TokenVerifier.decode_unverified(id_token),
         issuer when is_binary(issuer) <- Map.get(claims, "iss") do
      # Find a configured provider matching this issuer
      case Enum.find(Config.providers(), fn p -> p.issuer == issuer end) do
        nil ->
          # Check if device_flow config matches
          case Config.device_flow() do
            %{issuer: ^issuer} = config -> config
            _ -> nil
          end

        provider ->
          provider
      end
    else
      _ -> nil
    end
  end

  defp decrypt_cached_token(packed) when byte_size(packed) > 28 do
    <<iv::binary-size(12), tag::binary-size(16), ciphertext::binary>> = packed

    with {:ok, enc_key} <- get_cache_encryption_key(),
         {:ok, json} <- Crypto.decrypt(ciphertext, enc_key, iv, tag),
         {:ok, cache_data} <- Jason.decode(json) do
      # Check if the ID token is expired
      case get_in(cache_data, ["claims", "exp"]) do
        exp when is_integer(exp) ->
          now = DateTime.utc_now() |> DateTime.to_unix()

          if exp > now do
            {:ok, cache_data}
          else
            :expired
          end

        _ ->
          {:ok, cache_data}
      end
    else
      {:error, :decryption_failed} -> {:error, :cache_corrupted}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decrypt_cached_token(_), do: {:error, :invalid_cache_format}

  defp get_cache_encryption_key do
    with {:ok, master_key} <- SigningKeyStore.ensure_master_key_for_oidc() do
      {:ok, Crypto.derive_key(master_key, @token_cache_encryption_info, 32)}
    end
  end

  defp log_auth_result(identity, status) do
    name = IdentityContract.display_name(identity)
    action = if status == :created, do: "Created new", else: "Loaded existing"
    Logger.info("[OIDC] #{action} identity: #{name}")
  end
end
