defmodule Arbor.Security.OIDC do
  @moduledoc """
  OIDC authentication facade for Arbor.

  Orchestrates the full authentication flow:
  1. Device flow (for CLI) or direct token verification
  2. OIDC claim extraction
  3. Persistent human keypair binding (via IdentityStore)
  4. Identity registration
  5. Owner-bound signing-authority acquisition

  ## Usage

      # Full device flow (interactive CLI)
      {:ok, agent_id, authority} = Arbor.Security.OIDC.authenticate_device_flow(config)

      # Verify an existing JWT
      {:ok, agent_id, authority} = Arbor.Security.OIDC.authenticate_token(id_token, config)
  """

  alias Arbor.Contracts.Security.Identity, as: IdentityContract
  alias Arbor.Contracts.Security.SigningAuthority
  alias Arbor.Security.OIDC.Config
  alias Arbor.Security.OIDC.DeviceFlow
  alias Arbor.Security.OIDC.IdentityStore
  alias Arbor.Security.OIDC.TokenCacheOwner
  alias Arbor.Security.OIDC.TokenVerifier
  alias Arbor.Security.SigningKeyStore

  require Logger

  @doc """
  Run the full device authorization flow (interactive CLI).

  1. Starts device flow → prints URL + user code to stderr
  2. Polls until user authorizes
  3. Verifies the ID token
  4. Loads or creates persistent keypair
  5. Registers identity
  Returns `{:ok, agent_id, signing_authority}` on success. The authority is
  owned by the calling process and is revoked automatically when that process
  exits.
  """
  @spec authenticate_device_flow(map() | nil) ::
          {:ok, String.t(), SigningAuthority.t()} | {:error, term()}
  def authenticate_device_flow(config \\ nil) do
    config = config || Config.device_flow()

    if is_nil(config) do
      {:error, :no_device_flow_configured}
    else
      with {:ok, device_response} <- DeviceFlow.start(config),
           :ok <- print_device_flow_instructions(device_response),
           {:ok, token_response} <- DeviceFlow.poll(config, device_response),
           id_token when is_binary(id_token) <- Map.get(token_response, "id_token"),
           {:ok, _claims} <- TokenVerifier.verify(id_token, config),
           {:ok, identity, status} <- IdentityStore.load_or_create(id_token, config),
           :ok <- ensure_registered(identity, id_token, config) do
        with {:ok, authority} <- open_operator_authority(identity, id_token, config) do
          log_auth_result(identity, status)
          {:ok, identity.agent_id, authority}
        end
      else
        nil -> {:error, :no_id_token_in_response}
        {:error, _} = error -> error
      end
    end
  end

  @doc """
  Authenticate using an existing ID token (e.g., from cache).

  Verifies the token, loads the persistent keypair, and returns an owner-bound
  signing authority.
  """
  @spec authenticate_token(String.t(), map() | nil) ::
          {:ok, String.t(), SigningAuthority.t()} | {:error, term()}
  def authenticate_token(id_token, config \\ nil) do
    config = config || resolve_provider_for_token(id_token)

    if is_nil(config) do
      {:error, :no_matching_provider}
    else
      with {:ok, _claims} <- TokenVerifier.verify(id_token, config),
           {:ok, identity, _status} <- IdentityStore.load_or_create(id_token, config),
           :ok <- ensure_registered(identity, id_token, config) do
        with {:ok, authority} <- open_operator_authority(identity, id_token, config) do
          {:ok, identity.agent_id, authority}
        end
      end
    end
  end

  @doc false
  @spec open_operator_authority(IdentityContract.t()) ::
          {:ok, SigningAuthority.t()} | {:error, term()}
  def open_operator_authority(%IdentityContract{
        agent_id: principal_id,
        private_key: private_key
      })
      when is_binary(principal_id) and is_binary(private_key) do
    with {:ok, proof} <-
           Arbor.Security.build_signing_authority_acquisition_proof(
             principal_id,
             private_key,
             purpose: :oidc_operator,
             owner: self()
           ) do
      Arbor.Security.open_signing_authority(proof)
    end
  end

  def open_operator_authority(_identity), do: {:error, :invalid_oidc_identity}

  @doc false
  @spec open_operator_authority(IdentityContract.t(), String.t(), map()) ::
          {:ok, SigningAuthority.t()} | {:error, term()}
  def open_operator_authority(
        %IdentityContract{agent_id: principal_id, private_key: nil},
        id_token,
        provider_config
      )
      when is_binary(principal_id) and is_binary(id_token) and is_map(provider_config) do
    with {:ok, proof} <-
           SigningKeyStore.build_oidc_acquisition_proof(
             id_token,
             provider_config,
             :oidc_operator,
             self()
           ) do
      Arbor.Security.open_signing_authority(proof)
    end
  end

  def open_operator_authority(%IdentityContract{} = identity, _id_token, _provider_config),
    do: open_operator_authority(identity)

  def open_operator_authority(_, _, _), do: {:error, :invalid_oidc_identity}

  @doc """
  Retired OIDC token-cache read boundary.

  OIDC bearer and refresh tokens are never returned from persisted storage.
  """
  @spec load_cached_token() :: {:error, :oidc_token_cache_unauthorized}
  def load_cached_token, do: TokenCacheOwner.load()

  @doc """
  Retired OIDC token-cache write boundary.

  Device authentication keeps provider tokens only for the live operation and
  does not persist them.
  """
  @spec cache_token(map(), map()) :: {:error, :oidc_token_cache_unauthorized}
  def cache_token(token_response, claims), do: TokenCacheOwner.store(token_response, claims)

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

  defp ensure_registered(identity, id_token, provider_config) do
    case Arbor.Security.register_oidc_identity(identity, id_token, provider_config) do
      :ok -> :ok
      {:error, {:already_registered, _}} -> :ok
      {:error, reason} -> {:error, {:registration_failed, reason}}
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

  defp log_auth_result(identity, status) do
    name = IdentityContract.display_name(identity)
    action = if status == :created, do: "Created new", else: "Loaded existing"
    Logger.info("[OIDC] #{action} identity: #{name}")
  end
end
