defmodule Arbor.Security.SigningKeyStore do
  @moduledoc """
  Encrypted storage for agent signing private keys.

  Wraps `Arbor.Security.AuthorityStore` with AES-256-GCM encryption at the
  application layer.
  Private keys are encrypted before storage and decrypted on retrieval.

  ## Encryption

  Uses a stable master key stored at `~/.arbor/security/master.key`. The master
  key is generated on first use and persists across restarts. The signing key
  encryption key is derived from the master key via HKDF with purpose-specific
  info string.

  ## Storage

  Backed by the `:arbor_security_signing_keys` AuthorityStore instance.
  Reads always consult its authoritative backend and mutations use its
  acknowledged API so callers never confuse an attempted write with a
  durably acknowledged write.
  """

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Contracts.Security.Identity
  alias Arbor.Contracts.Security.SigningAuthority.Validator, as: SigningAuthorityValidator
  alias Arbor.Security.AuthorityStore
  alias Arbor.Security.Crypto

  require Logger

  @store_name :arbor_security_signing_keys
  @key_derivation_info "arbor-signing-key-encryption-v1"

  @doc """
  Store an agent's signing private key (encrypted at rest).

  Returns `:ok` on success.
  """
  @spec put(String.t(), binary()) :: :ok | {:error, term()}
  def put(agent_id, private_key)
      when is_binary(agent_id) and is_binary(private_key) do
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
    with {:ok, enc_key} <- get_encryption_key(),
         {:ok, raw} <- get_record(agent_id) do
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

  @doc """
  Store a keypair (signing + optional encryption) for an agent, encrypted at rest.

  Stores a map of `%{"signing" => ed25519_priv, "encryption" => x25519_priv}`.
  Backwards compatible with `get/1` — `get_keypair/1` detects the format.
  """
  @spec put_keypair(String.t(), binary(), binary() | nil) :: :ok | {:error, term()}
  def put_keypair(agent_id, signing_key, encryption_key \\ nil)
      when is_binary(agent_id) and is_binary(signing_key) do
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
      acknowledged_put(agent_id, record)
    else
      {:error, reason} when reason in [:invalid_key_material, :invalid_authority_identity] ->
        {:error, reason}

      {:error, _reason} ->
        {:error, :key_encryption_unavailable}
    end
  end

  def put_authority_bundle(_agent_id, _identity), do: {:error, :invalid_authority_identity}

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
    with {:ok, enc_key} <- get_encryption_key(),
         {:ok, raw} <- get_record(agent_id) do
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
    with {:ok, enc_key} <- get_encryption_key(),
         {:ok, raw} <- get_record(agent_id) do
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
    acknowledged_delete(agent_id)
  end

  @doc """
  Check if the signing key store is available.
  """
  @spec available?() :: boolean()
  def available? do
    Process.whereis(@store_name) != nil
  end

  @doc """
  Returns the master key for OIDC token cache encryption.

  This is a public wrapper around the internal master key management
  for use by the OIDC subsystem only.
  """
  @spec ensure_master_key_for_oidc() :: {:ok, binary()} | {:error, term()}
  def ensure_master_key_for_oidc, do: ensure_master_key()

  # -- Private --

  defp unwrap_record(%Record{data: data}), do: data

  defp get_record(agent_id) do
    if available?() do
      try do
        AuthorityStore.authoritative_get(agent_id, name: @store_name)
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

  defp acknowledged_put(key, %Record{} = record) do
    if available?() do
      try do
        case AuthorityStore.acknowledged_put(key, record, name: @store_name) do
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

  defp acknowledged_delete(key) do
    if available?() do
      try do
        case AuthorityStore.acknowledged_delete(key, name: @store_name) do
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

  defp get_encryption_key do
    with {:ok, master_key} <- ensure_master_key() do
      {:ok, Crypto.derive_key(master_key, @key_derivation_info, 32)}
    end
  end

  defp get_read_only_encryption_key do
    with {:ok, master_key} <- read_master_key(master_key_path()) do
      {:ok, Crypto.derive_key(master_key, @key_derivation_info, 32)}
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
