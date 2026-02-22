defmodule Arbor.Security.SigningKeyStore do
  @moduledoc """
  Encrypted storage for agent signing private keys.

  Wraps BufferedStore with AES-256-GCM encryption at the application layer.
  Private keys are encrypted before storage and decrypted on retrieval.

  ## Encryption

  Uses a stable master key stored at `~/.arbor/security/master.key`. The master
  key is generated on first use and persists across restarts. The signing key
  encryption key is derived from the master key via HKDF with purpose-specific
  info string.

  ## Storage

  Backed by the `:arbor_security_signing_keys` BufferedStore instance,
  which provides ETS caching for fast reads and durable persistence via
  the configured security backend (JSONFile by default).
  """

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Security.Crypto

  require Logger

  @store_name :arbor_security_signing_keys
  @key_derivation_info "arbor-signing-key-encryption-v1"

  # Runtime bridge — arbor_persistence is Level 1 peer
  @buffered_store Arbor.Persistence.BufferedStore

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
      record = %Record{id: agent_id, key: agent_id, data: data, metadata: %{}}

      if available?() do
        apply(@buffered_store, :put, [agent_id, record, [name: @store_name]])
        :ok
      else
        {:error, :store_unavailable}
      end
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
      # Unwrap Record struct (from disk) or use plain map (legacy ETS)
      data = unwrap_record(raw)

      with {:ok, ciphertext} <- Base.decode64(data["ct"]),
           {:ok, iv} <- Base.decode64(data["iv"]),
           {:ok, tag} <- Base.decode64(data["tag"]) do
        Crypto.decrypt(ciphertext, enc_key, iv, tag)
      else
        :error -> {:error, :invalid_key_record}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :not_found} -> {:error, :no_signing_key}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Delete an agent's signing key.
  """
  @spec delete(String.t()) :: :ok
  def delete(agent_id) when is_binary(agent_id) do
    if available?() do
      apply(@buffered_store, :delete, [agent_id, [name: @store_name]])
    end

    :ok
  end

  @doc """
  Check if the signing key store is available.
  """
  @spec available?() :: boolean()
  def available? do
    Code.ensure_loaded?(@buffered_store) and
      Process.whereis(@store_name) != nil
  end

  # -- Private --

  # Record struct from JSONFile backend (loaded from disk after restart)
  defp unwrap_record(%Record{data: data}), do: data
  # Plain map from ETS (stored during current session)
  defp unwrap_record(%{"ct" => _} = data), do: data

  defp get_record(agent_id) do
    if available?() do
      apply(@buffered_store, :get, [agent_id, [name: @store_name]])
    else
      {:error, :store_unavailable}
    end
  end

  defp get_encryption_key do
    with {:ok, master_key} <- ensure_master_key() do
      {:ok, Crypto.derive_key(master_key, @key_derivation_info, 32)}
    end
  end

  defp ensure_master_key do
    path = master_key_path()

    case File.read(path) do
      {:ok, <<key::binary-size(32)>>} ->
        {:ok, key}

      {:ok, hex} when is_binary(hex) ->
        # Support hex-encoded master key
        case Base.decode16(hex, case: :mixed) do
          {:ok, key} when byte_size(key) == 32 -> {:ok, key}
          _ -> {:error, :invalid_master_key}
        end

      {:error, :enoent} ->
        generate_master_key(path)

      {:error, reason} ->
        {:error, {:master_key_read_failed, reason}}
    end
  end

  defp generate_master_key(path) do
    key = :crypto.strong_rand_bytes(32)
    dir = Path.dirname(path)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(path, key),
         :ok <- File.chmod(path, 0o600) do
      # Verify permissions were actually applied
      case File.stat(path) do
        {:ok, %{access: access}} when access in [:read_write, :read] ->
          Logger.info("Generated new master key at #{path} (mode 0600)")

        {:ok, _} ->
          Logger.warning("Master key at #{path} may have incorrect permissions")

        {:error, _} ->
          :ok
      end

      {:ok, key}
    else
      {:error, reason} ->
        {:error, {:master_key_write_failed, reason}}
    end
  end

  defp master_key_path do
    default = Path.join(System.user_home!(), ".arbor/security/master.key")
    Application.get_env(:arbor_security, :master_key_path, default)
  end
end
