defmodule Arbor.Security.SigningKeyStore do
  @moduledoc false
  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Contracts.Security.Identity
  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Contracts.Security.SigningAuthority.Validator, as: SigningAuthorityValidator
  alias Arbor.Security.AuthorityStore
  alias Arbor.Security.Crypto
  alias Arbor.Security.SigningKeyStore.Owner
  alias Arbor.Security.SupervisedOwner

  require Logger

  @store_name :arbor_security_signing_keys
  @key_derivation_info "arbor-signing-key-encryption-v1"
  @master_key_purposes %{
    oidc_token_cache: "arbor-oidc-token-cache-v1",
    authority_record: "arbor-authority-store-record-authentication-v1",
    capability_revocation_ledger: "arbor-capability-revocation-ledger-authentication-v1"
  }

  @doc """
  Store an agent's signing private key (encrypted at rest).

  Returns `:ok` on success.
  """
  @spec put(String.t(), binary()) :: :ok | {:error, term()}
  def put(agent_id, private_key)
      when is_binary(agent_id) and is_binary(private_key) do
    Owner.put(agent_id, private_key)
  end

  def put(_agent_id, _private_key), do: {:error, :key_mutation_unauthorized}

  @doc false
  def put_from_owner(agent_id, private_key)
      when is_binary(agent_id) and is_binary(private_key) do
    if owner_process?(),
      do: do_put(agent_id, private_key),
      else: {:error, :key_mutation_unauthorized}
  end

  def put_from_owner(_agent_id, _private_key), do: {:error, :key_mutation_unauthorized}

  defp do_put(agent_id, private_key) do
    with {:ok, enc_key} <- get_encryption_key() do
      {ciphertext, iv, tag} = Crypto.encrypt(private_key, enc_key)

      data = %{
        "v" => 1,
        "ct" => Base.encode64(ciphertext),
        "iv" => Base.encode64(iv),
        "tag" => Base.encode64(tag)
      }

      # Wrap in Record so JSONFile backend can persist (it pattern-matches on %Record{})
      record = Record.new(agent_id, data, id: "signing_key:#{agent_id}")

      acknowledged_put(agent_id, record)
    else
      {:error, _reason} -> {:error, :key_encryption_unavailable}
    end
  end

  @doc """
  Load and decrypt an agent's signing private key.

  Returns `{:ok, private_key}` or `{:error, reason}`.
  """
  @spec get(String.t()) :: {:ok, binary()} | {:error, term()}
  def get(agent_id) when is_binary(agent_id) do
    Owner.get(agent_id)
  end

  def get(_agent_id), do: {:error, :unauthorized}

  @doc false
  def get_from_owner(agent_id) when is_binary(agent_id) do
    if owner_process?(), do: do_get(agent_id), else: {:error, :unauthorized}
  end

  def get_from_owner(_agent_id), do: {:error, :unauthorized}

  if Mix.env() == :test do
    @doc false
    def put_fixture(agent_id, private_key), do: Owner.put_fixture(agent_id, private_key)

    @doc false
    def put_keypair_fixture(agent_id, signing_key, encryption_key \\ nil),
      do: Owner.put_keypair_fixture(agent_id, signing_key, encryption_key)

    @doc false
    def delete_fixture(agent_id), do: Owner.delete_fixture(agent_id)

    @doc false
    def get_for_test(agent_id) when is_binary(agent_id), do: do_get(agent_id)

    @doc false
    def get_keypair_for_test(agent_id) when is_binary(agent_id), do: do_get_keypair(agent_id)

    @doc false
    def get_authority_bundle_for_test(agent_id) when is_binary(agent_id),
      do: do_get_authority_bundle(agent_id, :application)

    @doc false
    def load_public_identity_fixture(agent_id, opts \\ []),
      do: Owner.load_public_identity_fixture(agent_id, opts)
  end

  defp do_get(agent_id) do
    with {:ok, raw} <- get_record(agent_id),
         {:ok, enc_key} <- get_read_only_encryption_key() do
      data = unwrap_record(raw)

      case data do
        %{"format" => "keypair", "v" => 2} ->
          # v2 keypair — extract the signing key
          with {:ok, keypair} <- decrypt_keypair(data, enc_key) do
            {:ok, keypair.signing}
          end

        %{"format" => "authority_bundle", "v" => 3} ->
          with {:ok, identity} <- decrypt_authority_bundle(data, enc_key) do
            {:ok, identity.private_key}
          end

        _ ->
          decrypt_single_key(data, enc_key)
      end
    else
      {:error, :not_found} -> {:error, :no_signing_key}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Report whether an agent's encrypted signing key is readable.

  This is an observation-only operation. It never creates or writes a master
  key, and it never returns decrypted key material.
  """
  @spec status(String.t()) ::
          {:ok, :available}
          | {:error,
             :invalid_principal | :store_unavailable | :no_signing_key | :invalid_key_material}
  def status(agent_id) do
    case SigningAuthorityValidator.validate_principal_id(agent_id) do
      {:error, _reason} ->
        {:error, :invalid_principal}

      :ok ->
        if available?(), do: read_status(agent_id), else: {:error, :store_unavailable}
    end
  end

  @doc false
  @spec load_public_identity(String.t(), keyword()) :: {:ok, Identity.t()} | {:error, term()}
  def load_public_identity(agent_id, opts \\ [])

  def load_public_identity(agent_id, opts) when is_binary(agent_id) and is_list(opts) do
    Owner.load_public_identity(agent_id, opts)
  end

  def load_public_identity(_, _), do: {:error, :invalid_principal}

  @doc false
  def load_public_identity_from_owner(agent_id, opts)
      when is_binary(agent_id) and is_list(opts) do
    if owner_process?(),
      do: do_load_public_identity(agent_id, opts),
      else: {:error, :unauthorized_key_owner}
  end

  def load_public_identity_from_owner(_, _), do: {:error, :invalid_principal}

  defp do_load_public_identity(agent_id, opts) do
    with {:ok, keypair} <- do_get_keypair(agent_id),
         {public_key, _private_key} <-
           :crypto.generate_key(:eddsa, :ed25519, keypair.signing),
         {:ok, identity} <-
           Identity.new(
             public_key: public_key,
             encryption_public_key: encryption_public_key(keypair),
             name: Keyword.get(opts, :name),
             metadata: Keyword.get(opts, :metadata, %{})
           ) do
      {:ok, %{identity | agent_id: agent_id}}
    end
  rescue
    _ -> {:error, :invalid_key_material}
  catch
    _, _ -> {:error, :invalid_key_material}
  end

  @doc false
  @spec build_registration_proof(Identity.t()) :: {:ok, binary()} | {:error, term()}
  def build_registration_proof(%Identity{} = public_identity) do
    Owner.build_registration_proof(public_identity)
  end

  def build_registration_proof(_identity), do: {:error, :invalid_identity}

  @doc false
  def build_registration_proof_from_owner(%Identity{} = public_identity) do
    if owner_process?(),
      do: do_build_registration_proof(public_identity),
      else: {:error, :unauthorized_key_owner}
  end

  def build_registration_proof_from_owner(_identity), do: {:error, :invalid_identity}

  defp do_build_registration_proof(public_identity) do
    with {:ok, keypair} <- do_get_keypair(public_identity.agent_id),
         {stored_public_key, _private_key} <-
           :crypto.generate_key(:eddsa, :ed25519, keypair.signing),
         true <- stored_public_key == public_identity.public_key,
         true <- Crypto.derive_agent_id(stored_public_key) == public_identity.agent_id,
         identity = %{public_identity | private_key: keypair.signing},
         {:ok, proof} <- Arbor.Security.Identity.Registry.registration_proof(identity) do
      {:ok, proof}
    else
      false -> {:error, :stored_identity_mismatch}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :identity_proof_unavailable}
    end
  rescue
    _ -> {:error, :identity_proof_unavailable}
  catch
    _, _ -> {:error, :identity_proof_unavailable}
  end

  @doc false
  @spec migrate_legacy_locator(String.t(), keyword()) ::
          {:ok, Identity.t(), :created | :existing} | {:error, term()}
  def migrate_legacy_locator(locator, opts \\ [])

  def migrate_legacy_locator(locator, opts) when is_binary(locator) and is_list(opts) do
    Owner.migrate_legacy_locator(locator, opts)
  end

  def migrate_legacy_locator(_, _), do: {:error, :invalid_legacy_locator}

  @doc false
  def migrate_legacy_locator_from_owner(locator, opts)
      when is_binary(locator) and is_list(opts) do
    if owner_process?(),
      do: do_migrate_legacy_locator(locator, opts),
      else: {:error, :unauthorized_key_owner}
  end

  def migrate_legacy_locator_from_owner(_, _), do: {:error, :invalid_legacy_locator}

  defp do_migrate_legacy_locator(locator, opts) do
    with {:ok, private_key} <- do_get(locator),
         {public_key, _private_key} <- :crypto.generate_key(:eddsa, :ed25519, private_key),
         {:ok, identity} <-
           Identity.new(
             public_key: public_key,
             name: Keyword.get(opts, :name),
             metadata: Keyword.get(opts, :metadata, %{})
           ) do
      case status(identity.agent_id) do
        {:error, :no_signing_key} ->
          with :ok <- do_put(identity.agent_id, private_key) do
            {:ok, Identity.public_only(identity), :created}
          end

        {:ok, :available} ->
          with {:ok, existing} <- do_load_public_identity(identity.agent_id, []),
               true <- existing.public_key == public_key do
            {:ok, Identity.public_only(identity), :existing}
          else
            _ -> {:error, :principal_signing_key_mismatch}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  rescue
    _ -> {:error, :legacy_key_migration_failed}
  catch
    _, _ -> {:error, :legacy_key_migration_failed}
  end

  @doc false
  @spec build_oidc_acquisition_proof(String.t(), map(), atom(), pid()) ::
          {:ok, SignedRequest.t()} | {:error, term()}
  def build_oidc_acquisition_proof(id_token, provider_config, :oidc_operator, owner)
      when is_binary(id_token) and is_map(provider_config) and is_pid(owner) and owner == self() do
    Owner.build_oidc_acquisition_proof(id_token, provider_config, :oidc_operator, owner)
  end

  def build_oidc_acquisition_proof(_, _, _, _),
    do: {:error, :invalid_oidc_authority_request}

  @doc false
  def build_oidc_acquisition_proof_from_owner(
        id_token,
        provider_config,
        :oidc_operator,
        owner
      )
      when is_binary(id_token) and is_map(provider_config) and is_pid(owner) do
    if owner_process?() do
      do_build_oidc_acquisition_proof(id_token, provider_config, owner)
    else
      {:error, :unauthorized_key_owner}
    end
  end

  def build_oidc_acquisition_proof_from_owner(_, _, _, _),
    do: {:error, :invalid_oidc_authority_request}

  defp do_build_oidc_acquisition_proof(id_token, provider_config, owner) do
    with {:ok, claims} <- Arbor.Security.OIDC.TokenVerifier.verify(id_token, provider_config),
         principal_id <- Arbor.Security.OIDC.IdentityStore.derive_agent_id(claims),
         {:ok, keypair} <- do_get_keypair(principal_id),
         payload <-
           Arbor.Security.SigningAuthorityBroker.acquisition_payload(
             principal_id,
             :oidc_operator,
             owner
           ) do
      SignedRequest.sign(payload, principal_id, keypair.signing)
    end
  end

  @doc false
  def build_oidc_registration_proof(%Identity{} = identity, id_token, provider_config)
      when is_binary(id_token) and is_map(provider_config) do
    Owner.build_oidc_registration_proof(identity, id_token, provider_config)
  end

  def build_oidc_registration_proof(_identity, _id_token, _provider_config),
    do: {:error, :invalid_oidc_registration}

  @doc false
  def build_oidc_registration_proof_from_owner(
        %Identity{} = identity,
        id_token,
        provider_config
      )
      when is_binary(id_token) and is_map(provider_config) do
    if owner_process?() do
      with {:ok, claims} <- Arbor.Security.OIDC.TokenVerifier.verify(id_token, provider_config),
           expected_id <- Arbor.Security.OIDC.IdentityStore.derive_agent_id(claims),
           true <- identity.agent_id == expected_id,
           {:ok, keypair} <- do_get_keypair(expected_id),
           {stored_public_key, _private_key} <-
             :crypto.generate_key(:eddsa, :ed25519, keypair.signing),
           true <- stored_public_key == identity.public_key do
        payload = Arbor.Security.Identity.Registry.oidc_key_possession_payload(identity, id_token)
        {:ok, Crypto.sign(payload, keypair.signing)}
      else
        false -> {:error, :stored_identity_mismatch}
        {:error, reason} -> {:error, reason}
        _ -> {:error, :invalid_oidc_registration}
      end
    else
      {:error, :unauthorized_key_owner}
    end
  rescue
    _ -> {:error, :invalid_oidc_registration}
  catch
    _, _ -> {:error, :invalid_oidc_registration}
  end

  def build_oidc_registration_proof_from_owner(_identity, _id_token, _provider_config),
    do: {:error, :invalid_oidc_registration}

  @doc false
  @spec build_named_acquisition_proof(String.t(), atom(), pid(), atom()) ::
          {:ok, SignedRequest.t()} | {:error, term()}
  def build_named_acquisition_proof(principal_id, purpose, owner, registered_owner)
      when is_binary(principal_id) and is_atom(purpose) and is_pid(owner) and
             is_atom(registered_owner) and owner == self() do
    Owner.build_named_acquisition_proof(principal_id, purpose, owner, registered_owner)
  end

  def build_named_acquisition_proof(_, _, _, _),
    do: {:error, :unauthorized_key_owner}

  @doc false
  def build_named_acquisition_proof_from_owner(
        principal_id,
        purpose,
        owner
      )
      when is_binary(principal_id) and is_atom(purpose) and is_pid(owner) do
    if owner_process?() do
      with {:ok, private_key} <- do_get(principal_id),
           payload <-
             Arbor.Security.SigningAuthorityBroker.acquisition_payload(
               principal_id,
               purpose,
               owner
             ) do
        SignedRequest.sign(payload, principal_id, private_key)
      end
    else
      {:error, :unauthorized_key_owner}
    end
  end

  def build_named_acquisition_proof_from_owner(_, _, _),
    do: {:error, :unauthorized_key_owner}

  @doc """
  Store a keypair (signing + optional encryption) for an agent, encrypted at rest.

  Stores a map of `%{"signing" => ed25519_priv, "encryption" => x25519_priv}`.
  Backwards compatible with `get/1` — `get_keypair/1` detects the format.
  """
  @spec put_keypair(String.t(), binary(), binary() | nil) :: :ok | {:error, term()}
  def put_keypair(agent_id, signing_key, encryption_key \\ nil)

  def put_keypair(agent_id, signing_key, encryption_key)
      when is_binary(agent_id) and is_binary(signing_key) do
    Owner.put_keypair(agent_id, signing_key, encryption_key)
  end

  def put_keypair(_agent_id, _signing_key, _encryption_key),
    do: {:error, :key_mutation_unauthorized}

  @doc false
  def put_keypair_from_owner(agent_id, signing_key, encryption_key)
      when is_binary(agent_id) and is_binary(signing_key) do
    if owner_process?(),
      do: do_put_keypair(agent_id, signing_key, encryption_key),
      else: {:error, :key_mutation_unauthorized}
  end

  def put_keypair_from_owner(_agent_id, _signing_key, _encryption_key),
    do: {:error, :key_mutation_unauthorized}

  defp do_put_keypair(agent_id, signing_key, encryption_key) do
    keypair_data = %{"signing" => signing_key}

    keypair_data =
      if encryption_key,
        do: Map.put(keypair_data, "encryption", encryption_key),
        else: keypair_data

    with {:ok, enc_key} <- get_encryption_key() do
      # Base64-encode binary keys for JSON serialization
      encoded_data =
        Map.new(keypair_data, fn {k, v} -> {k, Base.encode64(v)} end)

      plaintext = Jason.encode!(encoded_data)
      {ciphertext, iv, tag} = Crypto.encrypt(plaintext, enc_key)

      data = %{
        "v" => 2,
        "format" => "keypair",
        "ct" => Base.encode64(ciphertext),
        "iv" => Base.encode64(iv),
        "tag" => Base.encode64(tag)
      }

      record = Record.new(agent_id, data, id: "signing_key:#{agent_id}")

      acknowledged_put(agent_id, record)
    else
      {:error, _reason} -> {:error, :key_encryption_unavailable}
    end
  end

  @doc """
  Durably store one atomic system-authority bundle.

  The private Ed25519 and X25519 keys are serialized only inside the existing
  AES-GCM ciphertext envelope. Public identity metadata remains readable in
  the same `Record`, making the root an indivisible authority mutation.
  """
  @spec put_authority_bundle(String.t(), Identity.t()) :: :ok | {:error, atom()}
  def put_authority_bundle(agent_id, %Identity{} = identity) when is_binary(agent_id) do
    Owner.put_authority_bundle(agent_id, identity)
  end

  def put_authority_bundle(_agent_id, _identity), do: {:error, :invalid_authority_identity}

  @doc false
  def put_authority_bundle_from_owner(agent_id, %Identity{} = identity)
      when is_binary(agent_id) do
    if owner_process?(),
      do: do_put_authority_bundle(agent_id, identity, :application),
      else: {:error, :key_mutation_unauthorized}
  end

  def put_authority_bundle_from_owner(_agent_id, _identity),
    do: {:error, :invalid_authority_identity}

  @doc false
  def put_authority_bundle_from_owner(agent_id, %Identity{} = identity, supervisor)
      when is_binary(agent_id) and is_pid(supervisor) do
    if Owner.owner_process_from_supervisor?(supervisor),
      do: do_put_authority_bundle(agent_id, identity, {:supervisor, supervisor}),
      else: {:error, :key_mutation_unauthorized}
  end

  def put_authority_bundle_from_owner(_agent_id, _identity, _supervisor),
    do: {:error, :invalid_authority_identity}

  @doc false
  def delete_authority_record(key) when is_binary(key), do: Owner.delete_authority_record(key)
  def delete_authority_record(_key), do: {:error, :key_mutation_unauthorized}

  @doc false
  def delete_authority_record_from_owner(key) when is_binary(key) do
    if owner_process?(),
      do: acknowledged_delete(key, :application),
      else: {:error, :key_mutation_unauthorized}
  end

  def delete_authority_record_from_owner(_key),
    do: {:error, :key_mutation_unauthorized}

  @doc false
  def delete_authority_record_from_owner(key, supervisor)
      when is_binary(key) and is_pid(supervisor) do
    if Owner.owner_process_from_supervisor?(supervisor),
      do: acknowledged_delete(key, {:supervisor, supervisor}),
      else: {:error, :key_mutation_unauthorized}
  end

  def delete_authority_record_from_owner(_key, _supervisor),
    do: {:error, :key_mutation_unauthorized}

  defp do_put_authority_bundle(agent_id, identity, store_context) do
    with :ok <- validate_identity_keypairs(identity),
         {:ok, enc_key} <- get_encryption_key(),
         {:ok, encrypted} <-
           encrypt_keypair(identity.private_key, identity.encryption_private_key, enc_key) do
      data = %{
        "v" => 3,
        "format" => "authority_bundle",
        "ct" => encrypted.ct,
        "iv" => encrypted.iv,
        "tag" => encrypted.tag,
        "public" => %{
          "agent_id" => identity.agent_id,
          "public_key" => Base.encode64(identity.public_key),
          "encryption_public_key" => Base.encode64(identity.encryption_public_key),
          "name" => identity.name,
          "created_at" => DateTime.to_iso8601(identity.created_at)
        }
      }

      record = Record.new(agent_id, data, id: "signing_key:#{agent_id}")
      acknowledged_put(agent_id, record, store_context)
    else
      {:error, reason} when reason in [:invalid_key_material, :invalid_authority_identity] ->
        {:error, reason}

      {:error, _reason} ->
        {:error, :key_encryption_unavailable}
    end
  end

  @doc """
  Load and validate a v3 atomic system-authority bundle.

  A legacy v2 keypair is reported distinctly so `SystemAuthority` can require,
  validate, and migrate its matching legacy public metadata. Malformed v3 data
  never falls back to legacy state.
  """
  @spec get_authority_bundle(String.t()) ::
          {:ok, Identity.t()}
          | {:error,
             :legacy_keypair
             | :no_signing_key
             | :invalid_authority_bundle
             | :store_unavailable
             | :key_encryption_unavailable}
  def get_authority_bundle(agent_id) when is_binary(agent_id) do
    Owner.get_authority_bundle(agent_id)
  end

  def get_authority_bundle(_agent_id), do: {:error, :unauthorized}

  @doc false
  def get_authority_bundle_from_owner(agent_id) when is_binary(agent_id) do
    if owner_process?(),
      do: do_get_authority_bundle(agent_id, :application),
      else: {:error, :unauthorized}
  end

  def get_authority_bundle_from_owner(_agent_id), do: {:error, :unauthorized}

  @doc false
  def get_authority_bundle_from_owner(agent_id, supervisor)
      when is_binary(agent_id) and is_pid(supervisor) do
    if Owner.owner_process_from_supervisor?(supervisor),
      do: do_get_authority_bundle(agent_id, {:supervisor, supervisor}),
      else: {:error, :unauthorized}
  end

  def get_authority_bundle_from_owner(_agent_id, _supervisor), do: {:error, :unauthorized}

  defp do_get_authority_bundle(agent_id, store_context) do
    with {:ok, raw} <- get_record(agent_id, store_context),
         {:ok, enc_key} <- get_read_only_encryption_key() do
      case unwrap_record(raw) do
        %{"format" => "authority_bundle", "v" => 3} = data ->
          decrypt_authority_bundle(data, enc_key)

        %{"format" => "keypair", "v" => 2} ->
          {:error, :legacy_keypair}

        _other ->
          {:error, :invalid_authority_bundle}
      end
    else
      {:error, :not_found} -> {:error, :no_signing_key}
      {:error, :store_unavailable} = error -> error
      {:error, _reason} -> {:error, :key_encryption_unavailable}
    end
  end

  @doc """
  Load and decrypt a keypair for an agent.

  Returns `{:ok, %{signing: binary, encryption: binary}}` for v2 keypair records,
  or `{:ok, %{signing: binary}}` for legacy v1 single-key records.
  """
  @spec get_keypair(String.t()) :: {:ok, map()} | {:error, term()}
  def get_keypair(agent_id) when is_binary(agent_id) do
    Owner.get_keypair(agent_id)
  end

  def get_keypair(_agent_id), do: {:error, :unauthorized}

  @doc false
  def get_keypair_from_owner(agent_id) when is_binary(agent_id) do
    if owner_process?(), do: do_get_keypair(agent_id), else: {:error, :unauthorized}
  end

  def get_keypair_from_owner(_agent_id), do: {:error, :unauthorized}

  @doc false
  def get_keypair_from_owner(agent_id, supervisor)
      when is_binary(agent_id) and is_pid(supervisor) do
    if Owner.owner_process_from_supervisor?(supervisor),
      do: do_get_keypair(agent_id, {:supervisor, supervisor}),
      else: {:error, :unauthorized}
  end

  def get_keypair_from_owner(_agent_id, _supervisor), do: {:error, :unauthorized}

  defp do_get_keypair(agent_id, store_context \\ :application) do
    with {:ok, raw} <- get_record(agent_id, store_context),
         {:ok, enc_key} <- get_read_only_encryption_key() do
      data = unwrap_record(raw)

      case data do
        %{"format" => "keypair", "v" => 2} ->
          decrypt_keypair(data, enc_key)

        %{"format" => "authority_bundle", "v" => 3} ->
          with {:ok, identity} <- decrypt_authority_bundle(data, enc_key) do
            {:ok, %{signing: identity.private_key, encryption: identity.encryption_private_key}}
          end

        %{"v" => 1} ->
          # Legacy single signing key — decrypt and wrap
          with {:ok, signing_key} <- decrypt_single_key(data, enc_key) do
            {:ok, %{signing: signing_key}}
          end

        _ ->
          # Try legacy format
          with {:ok, signing_key} <- decrypt_single_key(data, enc_key) do
            {:ok, %{signing: signing_key}}
          end
      end
    else
      {:error, :not_found} -> {:error, :no_signing_key}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Delete an agent's signing key.
  """
  @spec delete(String.t()) ::
          :ok
          | {:error,
             :store_unavailable
             | :outcome_unknown
             | :invalid_store_record
             | :store_capacity_exceeded}
  def delete(agent_id) when is_binary(agent_id) do
    Owner.delete(agent_id)
  end

  def delete(_agent_id), do: {:error, :key_mutation_unauthorized}

  @doc false
  def delete_from_owner(agent_id) when is_binary(agent_id) do
    if owner_process?(),
      do: acknowledged_delete(agent_id),
      else: {:error, :key_mutation_unauthorized}
  end

  def delete_from_owner(_agent_id), do: {:error, :key_mutation_unauthorized}

  @doc """
  Check if the signing key store is available.
  """
  @spec available?() :: boolean()
  def available? do
    Process.whereis(@store_name) != nil
  end

  @doc false
  @spec encrypt_with_master(atom(), binary()) ::
          {:ok, %{ciphertext: binary(), iv: binary(), tag: binary()}} | {:error, term()}
  def encrypt_with_master(purpose, plaintext) when is_binary(plaintext) do
    if token_cache_owner_process?() and purpose == :oidc_token_cache do
      with {:ok, key} <- purpose_key(purpose, :write) do
        {ciphertext, iv, tag} = Crypto.encrypt(plaintext, key)
        {:ok, %{ciphertext: ciphertext, iv: iv, tag: tag}}
      end
    else
      {:error, :master_key_access_unauthorized}
    end
  rescue
    _ -> {:error, :key_encryption_unavailable}
  catch
    _, _ -> {:error, :key_encryption_unavailable}
  end

  def encrypt_with_master(_, _), do: {:error, :invalid_master_key_operation}

  @doc false
  @spec decrypt_with_master(atom(), binary(), binary(), binary()) ::
          {:ok, binary()} | {:error, term()}
  def decrypt_with_master(purpose, ciphertext, iv, tag)
      when is_binary(ciphertext) and is_binary(iv) and is_binary(tag) do
    if token_cache_owner_process?() and purpose == :oidc_token_cache do
      with {:ok, key} <- purpose_key(purpose, :read) do
        Crypto.decrypt(ciphertext, key, iv, tag)
      end
    else
      {:error, :master_key_access_unauthorized}
    end
  rescue
    _ -> {:error, :key_encryption_unavailable}
  catch
    _, _ -> {:error, :key_encryption_unavailable}
  end

  def decrypt_with_master(_, _, _, _), do: {:error, :invalid_master_key_operation}

  @doc false
  @spec authenticate_with_master(atom(), binary()) :: {:ok, binary()} | {:error, term()}
  def authenticate_with_master(purpose, bytes) when is_binary(bytes) do
    if master_key_owner_process?() do
      with {:ok, key} <- purpose_key(purpose, :write) do
        {:ok, :crypto.mac(:hmac, :sha256, key, bytes)}
      end
    else
      {:error, :master_key_access_unauthorized}
    end
  end

  def authenticate_with_master(_, _), do: {:error, :invalid_master_key_operation}

  @doc false
  @spec authenticate_with_master_from_supervisor(pid(), atom(), binary()) ::
          {:ok, binary()} | {:error, term()}
  def authenticate_with_master_from_supervisor(supervisor, purpose, bytes)
      when is_pid(supervisor) and is_binary(bytes) do
    if Arbor.Security.MasterKeyAccessOwner.owner_process_from_supervisor?(supervisor) do
      with {:ok, key} <- purpose_key(purpose, :write) do
        {:ok, :crypto.mac(:hmac, :sha256, key, bytes)}
      end
    else
      {:error, :master_key_access_unauthorized}
    end
  end

  def authenticate_with_master_from_supervisor(_, _, _),
    do: {:error, :invalid_master_key_operation}

  @doc false
  @spec verify_with_master(atom(), binary(), binary()) :: :ok | {:error, term()}
  def verify_with_master(purpose, bytes, expected)
      when is_binary(bytes) and is_binary(expected) do
    if master_key_owner_process?() do
      with {:ok, key} <- purpose_key(purpose, :read) do
        actual = :crypto.mac(:hmac, :sha256, key, bytes)

        if byte_size(actual) == byte_size(expected) and :crypto.hash_equals(actual, expected),
          do: :ok,
          else: {:error, :record_authentication_failed}
      end
    else
      {:error, :master_key_access_unauthorized}
    end
  end

  def verify_with_master(_, _, _), do: {:error, :invalid_master_key_operation}

  @doc false
  @spec verify_with_master_from_supervisor(pid(), atom(), binary(), binary()) ::
          :ok | {:error, term()}
  def verify_with_master_from_supervisor(supervisor, purpose, bytes, expected)
      when is_pid(supervisor) and is_binary(bytes) and is_binary(expected) do
    if Arbor.Security.MasterKeyAccessOwner.owner_process_from_supervisor?(supervisor) do
      with {:ok, key} <- purpose_key(purpose, :read) do
        actual = :crypto.mac(:hmac, :sha256, key, bytes)

        if byte_size(actual) == byte_size(expected) and :crypto.hash_equals(actual, expected),
          do: :ok,
          else: {:error, :record_authentication_failed}
      end
    else
      {:error, :master_key_access_unauthorized}
    end
  end

  def verify_with_master_from_supervisor(_, _, _, _),
    do: {:error, :invalid_master_key_operation}

  # -- Private --

  defp owner_process?, do: Owner.owner_process?()
  defp master_key_owner_process?, do: Arbor.Security.MasterKeyAccessOwner.owner_process?()
  defp token_cache_owner_process?, do: Arbor.Security.OIDC.TokenCacheOwner.owner_process?()

  defp purpose_key(purpose, mode) when mode in [:read, :write] do
    with {:ok, info} <- Map.fetch(@master_key_purposes, purpose),
         {:ok, master_key} <- master_key_for_mode(mode) do
      {:ok, Crypto.derive_key(master_key, info, 32)}
    else
      :error -> {:error, :unsupported_master_key_purpose}
      {:error, _} = error -> error
    end
  end

  defp purpose_key(_, _), do: {:error, :invalid_master_key_operation}

  defp master_key_for_mode(:write), do: ensure_master_key()
  defp master_key_for_mode(:read), do: read_master_key(master_key_path())

  defp encryption_public_key(%{encryption: private_key}) when is_binary(private_key) do
    {public_key, _private_key} = :crypto.generate_key(:ecdh, :x25519, private_key)
    public_key
  end

  defp encryption_public_key(_), do: nil

  defp unwrap_record(%Record{data: data}), do: data

  defp get_record(agent_id, store_context \\ :application) do
    if available?(store_context) do
      try do
        case store_context do
          :application ->
            AuthorityStore.authoritative_get(agent_id, name: @store_name)

          {:supervisor, supervisor} ->
            AuthorityStore.authoritative_get_from_supervisor(
              supervisor,
              agent_id,
              name: @store_name
            )
        end
      rescue
        _ -> {:error, :store_unavailable}
      catch
        :exit, _ -> {:error, :store_unavailable}
        _, _ -> {:error, :store_unavailable}
      end
    else
      {:error, :store_unavailable}
    end
  end

  defp acknowledged_put(key, %Record{} = record, store_context \\ :application) do
    if available?(store_context) do
      try do
        result =
          case store_context do
            :application ->
              AuthorityStore.acknowledged_put(key, record, name: @store_name)

            {:supervisor, supervisor} ->
              AuthorityStore.acknowledged_put_from_supervisor(
                supervisor,
                key,
                record,
                name: @store_name
              )
          end

        case result do
          {:ok, %Record{}} -> :ok
          {:error, :outcome_unknown} -> {:error, :outcome_unknown}
          {:error, reason} -> normalize_known_mutation_error(reason)
          _other -> {:error, :outcome_unknown}
        end
      rescue
        _ -> {:error, :outcome_unknown}
      catch
        _, _ -> {:error, :outcome_unknown}
      end
    else
      {:error, :store_unavailable}
    end
  end

  defp acknowledged_delete(key, store_context \\ :application) do
    if available?(store_context) do
      try do
        result =
          case store_context do
            :application ->
              AuthorityStore.acknowledged_delete(key, name: @store_name)

            {:supervisor, supervisor} ->
              AuthorityStore.acknowledged_delete_from_supervisor(
                supervisor,
                key,
                name: @store_name
              )
          end

        case result do
          :ok -> :ok
          {:error, :outcome_unknown} -> {:error, :outcome_unknown}
          {:error, reason} -> normalize_known_mutation_error(reason)
          _other -> {:error, :outcome_unknown}
        end
      rescue
        _ -> {:error, :outcome_unknown}
      catch
        _, _ -> {:error, :outcome_unknown}
      end
    else
      {:error, :store_unavailable}
    end
  end

  defp normalize_known_mutation_error(reason)
       when reason in [:backend_unavailable, :invalid_backend_response],
       do: {:error, :store_unavailable}

  defp normalize_known_mutation_error(reason)
       when reason in [:key_mismatch, :invalid_key, :unsupported_value],
       do: {:error, :invalid_store_record}

  defp normalize_known_mutation_error(:inventory_limit_exceeded),
    do: {:error, :store_capacity_exceeded}

  defp normalize_known_mutation_error(_reason), do: {:error, :store_unavailable}

  defp available?(:application), do: available?()

  defp available?({:supervisor, supervisor}) when is_pid(supervisor),
    do: is_pid(SupervisedOwner.child_pid(supervisor, @store_name))

  defp get_encryption_key do
    with {:ok, master_key} <- ensure_master_key() do
      {:ok, Crypto.derive_key(master_key, @key_derivation_info, 32)}
    end
  end

  defp get_read_only_encryption_key do
    case read_master_key(master_key_path()) do
      {:ok, master_key} ->
        {:ok, Crypto.derive_key(master_key, @key_derivation_info, 32)}

      {:error, {:master_key_read_failed, :enoent}} ->
        {:error, :master_key_missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_master_key do
    path = master_key_path()

    case read_master_key(path) do
      {:error, {:master_key_read_failed, :enoent}} ->
        generate_master_key(path)

      result ->
        result
    end
  end

  defp read_master_key(path) do
    case File.read(path) do
      {:ok, encoded_key} -> parse_master_key(encoded_key)
      {:error, reason} -> {:error, {:master_key_read_failed, reason}}
    end
  end

  defp parse_master_key(<<key::binary-size(32)>>), do: {:ok, key}

  defp parse_master_key(hex) when is_binary(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, key} when byte_size(key) == 32 -> {:ok, key}
      _ -> {:error, :invalid_master_key}
    end
  end

  defp generate_master_key(path) do
    key = :crypto.strong_rand_bytes(32)
    dir = Path.dirname(path)
    tmp = path <> ".tmp"

    # C6 review fix (2026-06-09): the previous `File.write(path) |> File.chmod(0600)`
    # left a umask-dependent window where the 32-byte master key was
    # world-readable (commonly 0644) before the chmod landed. Close it two ways:
    #   1. Restrict the containing directory to 0700 BEFORE writing, so the key
    #      is unreachable by other users even during any transient file-mode
    #      window (directory not traversable).
    #   2. Write to a temp file (inside the now-0700 dir), chmod it 0600, then
    #      atomically rename into place — so the final path never exists with a
    #      permissive mode.
    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700),
         :ok <- File.write(tmp, key),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.rename(tmp, path) do
      case File.stat(path) do
        {:ok, %{access: access}} when access in [:read_write, :read] ->
          Logger.info("Generated new master key at #{path} (dir 0700, file 0600)")

        {:ok, _} ->
          Logger.warning("Master key at #{path} may have incorrect permissions")

        {:error, _} ->
          :ok
      end

      {:ok, key}
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, {:master_key_write_failed, reason}}
    end
  end

  defp master_key_path do
    default = Path.join(System.user_home!(), ".arbor/security/master.key")
    Application.get_env(:arbor_security, :master_key_path, default)
  end

  defp decrypt_single_key(data, enc_key) do
    with {:ok, ciphertext} <- Base.decode64(data["ct"]),
         {:ok, iv} <- Base.decode64(data["iv"]),
         {:ok, tag} <- Base.decode64(data["tag"]) do
      Crypto.decrypt(ciphertext, enc_key, iv, tag)
    else
      :error -> {:error, :invalid_key_record}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decrypt_keypair(data, enc_key) do
    with {:ok, ciphertext} <- Base.decode64(data["ct"]),
         {:ok, iv} <- Base.decode64(data["iv"]),
         {:ok, tag} <- Base.decode64(data["tag"]),
         {:ok, plaintext} <- Crypto.decrypt(ciphertext, enc_key, iv, tag),
         {:ok, keypair_map} <- Jason.decode(plaintext),
         {:ok, signing} <- Base.decode64(keypair_map["signing"]) do
      result = %{signing: signing}

      result =
        case keypair_map["encryption"] do
          nil ->
            result

          enc_b64 ->
            case Base.decode64(enc_b64) do
              {:ok, enc} -> Map.put(result, :encryption, enc)
              :error -> result
            end
        end

      {:ok, result}
    else
      :error -> {:error, :invalid_key_record}
      {:error, reason} -> {:error, reason}
    end
  end

  defp encrypt_keypair(signing_key, encryption_key, enc_key)
       when is_binary(signing_key) and is_binary(encryption_key) do
    plaintext =
      Jason.encode!(%{
        "signing" => Base.encode64(signing_key),
        "encryption" => Base.encode64(encryption_key)
      })

    {ciphertext, iv, tag} = Crypto.encrypt(plaintext, enc_key)

    {:ok,
     %{
       ct: Base.encode64(ciphertext),
       iv: Base.encode64(iv),
       tag: Base.encode64(tag)
     }}
  rescue
    _ -> {:error, :key_encryption_failed}
  catch
    _, _ -> {:error, :key_encryption_failed}
  end

  defp encrypt_keypair(_signing_key, _encryption_key, _enc_key),
    do: {:error, :invalid_key_material}

  defp decrypt_authority_bundle(%{"public" => public} = data, enc_key)
       when is_map(public) do
    with true <-
           exact_string_keys?(data, ["ct", "format", "iv", "public", "tag", "v"]),
         true <-
           exact_string_keys?(public, [
             "agent_id",
             "created_at",
             "encryption_public_key",
             "name",
             "public_key"
           ]),
         {:ok, %{signing: signing, encryption: encryption}} <-
           decrypt_required_keypair(data, enc_key),
         {:ok, public_key} <- decode_required_base64(public["public_key"]),
         {:ok, encryption_public_key} <-
           decode_required_base64(public["encryption_public_key"]),
         {:ok, created_at} <- decode_required_datetime(public["created_at"]),
         :ok <- validate_bundle_name(public["name"]),
         {:ok, identity} <-
           Identity.new(
             public_key: public_key,
             private_key: signing,
             encryption_public_key: encryption_public_key,
             encryption_private_key: encryption,
             name: public["name"],
             created_at: created_at
           ),
         true <- public["agent_id"] == identity.agent_id,
         :ok <- validate_identity_keypairs(identity) do
      {:ok, identity}
    else
      _ -> {:error, :invalid_authority_bundle}
    end
  rescue
    _ -> {:error, :invalid_authority_bundle}
  catch
    _, _ -> {:error, :invalid_authority_bundle}
  end

  defp decrypt_authority_bundle(_data, _enc_key), do: {:error, :invalid_authority_bundle}

  defp decrypt_required_keypair(data, enc_key) do
    with {:ok, ciphertext} <- decode_required_base64(data["ct"]),
         {:ok, iv} <- decode_required_base64(data["iv"]),
         {:ok, tag} <- decode_required_base64(data["tag"]),
         {:ok, plaintext} <- Crypto.decrypt(ciphertext, enc_key, iv, tag),
         {:ok, %{"signing" => signing_b64, "encryption" => encryption_b64} = keypair} <-
           Jason.decode(plaintext),
         true <- exact_string_keys?(keypair, ["encryption", "signing"]),
         {:ok, signing} <- decode_required_base64(signing_b64),
         {:ok, encryption} <- decode_required_base64(encryption_b64) do
      {:ok, %{signing: signing, encryption: encryption}}
    else
      _ -> {:error, :invalid_authority_bundle}
    end
  end

  defp validate_identity_keypairs(%Identity{} = identity) do
    with true <- is_binary(identity.private_key),
         true <- is_binary(identity.public_key),
         true <- is_binary(identity.encryption_private_key),
         true <- is_binary(identity.encryption_public_key),
         {signing_public, _} <-
           :crypto.generate_key(:eddsa, :ed25519, identity.private_key),
         {encryption_public, _} <-
           :crypto.generate_key(:ecdh, :x25519, identity.encryption_private_key),
         true <- signing_public == identity.public_key,
         true <- encryption_public == identity.encryption_public_key do
      :ok
    else
      _ -> {:error, :invalid_authority_identity}
    end
  rescue
    _ -> {:error, :invalid_authority_identity}
  catch
    _, _ -> {:error, :invalid_authority_identity}
  end

  defp decode_required_base64(value) when is_binary(value) and byte_size(value) > 0 do
    case Base.decode64(value) do
      {:ok, decoded} when byte_size(decoded) > 0 -> {:ok, decoded}
      _ -> {:error, :invalid_base64}
    end
  end

  defp decode_required_base64(_value), do: {:error, :invalid_base64}

  defp decode_required_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, datetime}
      _ -> {:error, :invalid_datetime}
    end
  end

  defp decode_required_datetime(_value), do: {:error, :invalid_datetime}

  defp validate_bundle_name(nil), do: :ok
  defp validate_bundle_name(name) when is_binary(name) and byte_size(name) > 0, do: :ok
  defp validate_bundle_name(_name), do: {:error, :invalid_name}

  defp exact_string_keys?(map, expected) when is_map(map) do
    map
    |> Map.keys()
    |> Enum.sort()
    |> Kernel.==(expected)
  end

  defp read_status(agent_id) do
    try do
      with {:ok, raw} <- get_record(agent_id),
           {:ok, enc_key} <- get_read_only_encryption_key(),
           :ok <- validate_signing_record(raw, enc_key) do
        {:ok, :available}
      else
        {:error, :not_found} -> {:error, :no_signing_key}
        {:error, :store_unavailable} -> {:error, :store_unavailable}
        {:error, _reason} -> {:error, :invalid_key_material}
      end
    rescue
      ArgumentError -> {:error, :store_unavailable}
      _ -> {:error, :invalid_key_material}
    catch
      :exit, _reason -> {:error, :store_unavailable}
      :throw, _value -> {:error, :invalid_key_material}
    end
  end

  defp validate_signing_record(raw, enc_key) do
    case unwrap_record(raw) do
      %{"format" => "keypair", "v" => 2} = data ->
        with {:ok, %{signing: signing_key}} <- decrypt_keypair(data, enc_key) do
          validate_signing_key(signing_key)
        end

      %{"format" => "authority_bundle", "v" => 3} = data ->
        with {:ok, identity} <- decrypt_authority_bundle(data, enc_key) do
          validate_signing_key(identity.private_key)
        end

      data ->
        with {:ok, signing_key} <- decrypt_single_key(data, enc_key) do
          validate_signing_key(signing_key)
        end
    end
  end

  defp validate_signing_key(signing_key)
       when is_binary(signing_key) and byte_size(signing_key) in [32, 64],
       do: :ok

  defp validate_signing_key(_signing_key), do: {:error, :invalid_key_material}
end
