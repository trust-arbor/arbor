defmodule Arbor.Security.Keychain do
  @moduledoc """
  Agent keychain for managing cryptographic keys and peer relationships.

  A keychain holds an agent's own Ed25519 (signing) and X25519 (encryption)
  keypairs, plus the public keys of known peers. It also stores symmetric
  channel keys for encrypted channel communication.

  ## Double Ratchet Integration

  For peer-to-peer communications, the keychain can maintain Double Ratchet
  sessions that provide per-message forward secrecy. When a ratchet session
  exists for a peer, `seal_for_peer/3` and `unseal_from_peer/3` will use it
  automatically.

  ## Persistence

  Keychains can be serialized for checkpoint persistence using `serialize/2`
  and restored using `deserialize/2`. Private keys are encrypted with the
  provided encryption key before serialization.

  ## Usage

      keychain = Keychain.new("agent_abc123")

      # Add a known peer
      keychain = Keychain.add_peer(keychain, peer_id,
        peer_signing_pub, peer_encryption_pub, "reviewer-bot")

      # Seal a message for a peer
      {:ok, sealed} = Keychain.seal_for_peer(keychain, peer_id, "secret data")

      # Unseal a message from a peer
      {:ok, plaintext} = Keychain.unseal_from_peer(keychain, sender_id, sealed)

      # Serialize for persistence
      {:ok, payload} = Keychain.serialize(keychain, encryption_key)

      # Restore from checkpoint
      {:ok, restored} = Keychain.deserialize(payload, encryption_key)
  """

  alias Arbor.Security.Crypto
  alias Arbor.Security.DoubleRatchet

  @type peer_keys :: %{
          signing_public: binary(),
          encryption_public: binary(),
          name: String.t() | nil,
          trusted_at: DateTime.t(),
          ratchet_session: DoubleRatchet.t() | nil
        }

  @type t :: %__MODULE__{
          agent_id: String.t(),
          signing_keypair: %{public: binary(), private: binary()},
          encryption_keypair: %{public: binary(), private: binary()},
          peers: %{String.t() => peer_keys()},
          channel_keys: %{String.t() => binary()}
        }

  @enforce_keys [:agent_id, :signing_keypair, :encryption_keypair]
  defstruct [
    :agent_id,
    :signing_keypair,
    :encryption_keypair,
    peers: %{},
    channel_keys: %{}
  ]

  @keychain_version 1

  @doc """
  Create a new keychain with fresh Ed25519 and X25519 keypairs.
  """
  @spec new(String.t()) :: t()
  def new(agent_id) when is_binary(agent_id) do
    {sign_pub, sign_priv} = Crypto.generate_keypair()
    {enc_pub, enc_priv} = Crypto.generate_encryption_keypair()

    %__MODULE__{
      agent_id: agent_id,
      signing_keypair: %{public: sign_pub, private: sign_priv},
      encryption_keypair: %{public: enc_pub, private: enc_priv}
    }
  end

  @doc """
  Create a keychain from existing keypairs.
  """
  @spec from_keypairs(String.t(), {binary(), binary()}, {binary(), binary()}) :: t()
  def from_keypairs(agent_id, {sign_pub, sign_priv}, {enc_pub, enc_priv}) do
    %__MODULE__{
      agent_id: agent_id,
      signing_keypair: %{public: sign_pub, private: sign_priv},
      encryption_keypair: %{public: enc_pub, private: enc_priv}
    }
  end

  # -------------------------------------------------------------------
  # Peer Management
  # -------------------------------------------------------------------

  @doc """
  Add a known peer to the keychain.
  """
  @spec add_peer(t(), String.t(), binary(), binary(), String.t() | nil) :: t()
  def add_peer(%__MODULE__{} = keychain, agent_id, signing_public, encryption_public, name \\ nil)
      when is_binary(agent_id) and is_binary(signing_public) and is_binary(encryption_public) do
    peer = %{
      signing_public: signing_public,
      encryption_public: encryption_public,
      name: name,
      trusted_at: DateTime.utc_now(),
      ratchet_session: nil
    }

    %{keychain | peers: Map.put(keychain.peers, agent_id, peer)}
  end

  @doc """
  Remove a peer from the keychain.
  """
  @spec remove_peer(t(), String.t()) :: t()
  def remove_peer(%__MODULE__{} = keychain, agent_id) do
    %{keychain | peers: Map.delete(keychain.peers, agent_id)}
  end

  @doc """
  Look up a peer's keys.
  """
  @spec get_peer(t(), String.t()) :: {:ok, peer_keys()} | {:error, :unknown_peer}
  def get_peer(%__MODULE__{peers: peers}, agent_id) do
    case Map.get(peers, agent_id) do
      nil -> {:error, :unknown_peer}
      peer -> {:ok, peer}
    end
  end

  # -------------------------------------------------------------------
  # Double Ratchet Session Management
  # -------------------------------------------------------------------

  @doc """
  Initialize a Double Ratchet session with a peer as the sender (initiator).

  This creates a new ratchet session using a shared secret derived from
  ECDH between our encryption key and the peer's encryption public key.

  Returns the updated keychain with the ratchet session stored.
  """
  @spec init_ratchet_sender(t(), String.t()) :: {:ok, t()} | {:error, :unknown_peer}
  def init_ratchet_sender(%__MODULE__{} = keychain, peer_agent_id) do
    case get_peer(keychain, peer_agent_id) do
      {:ok, peer} ->
        # Derive shared secret from ECDH
        shared_secret =
          Crypto.derive_shared_secret(
            keychain.encryption_keypair.private,
            peer.encryption_public
          )

        # Initialize ratchet session as sender
        session = DoubleRatchet.init_sender(shared_secret, peer.encryption_public)

        # Store session in peer entry
        updated_peer = %{peer | ratchet_session: session}
        updated_keychain = %{keychain | peers: Map.put(keychain.peers, peer_agent_id, updated_peer)}

        {:ok, updated_keychain}

      {:error, :unknown_peer} = error ->
        error
    end
  end

  @doc """
  Initialize a Double Ratchet session with a peer as the receiver.

  This creates a new ratchet session ready to receive the first message
  from the peer.

  Returns the updated keychain with the ratchet session stored.
  """
  @spec init_ratchet_receiver(t(), String.t()) :: {:ok, t()} | {:error, :unknown_peer}
  def init_ratchet_receiver(%__MODULE__{} = keychain, peer_agent_id) do
    case get_peer(keychain, peer_agent_id) do
      {:ok, peer} ->
        # Derive shared secret from ECDH
        shared_secret =
          Crypto.derive_shared_secret(
            keychain.encryption_keypair.private,
            peer.encryption_public
          )

        # Initialize ratchet session as receiver
        my_keypair =
          {keychain.encryption_keypair.public, keychain.encryption_keypair.private}

        session = DoubleRatchet.init_receiver(shared_secret, my_keypair)

        # Store session in peer entry
        updated_peer = %{peer | ratchet_session: session}
        updated_keychain = %{keychain | peers: Map.put(keychain.peers, peer_agent_id, updated_peer)}

        {:ok, updated_keychain}

      {:error, :unknown_peer} = error ->
        error
    end
  end

  @doc """
  Check if a Double Ratchet session exists for a peer.
  """
  @spec has_ratchet_session?(t(), String.t()) :: boolean()
  def has_ratchet_session?(%__MODULE__{} = keychain, peer_agent_id) do
    case get_peer(keychain, peer_agent_id) do
      {:ok, %{ratchet_session: session}} when not is_nil(session) -> true
      _ -> false
    end
  end

  @doc """
  Clear the Double Ratchet session for a peer.

  Use this to force fallback to one-shot ECDH encryption.
  """
  @spec clear_ratchet_session(t(), String.t()) :: t()
  def clear_ratchet_session(%__MODULE__{} = keychain, peer_agent_id) do
    case get_peer(keychain, peer_agent_id) do
      {:ok, peer} ->
        updated_peer = %{peer | ratchet_session: nil}
        %{keychain | peers: Map.put(keychain.peers, peer_agent_id, updated_peer)}

      {:error, :unknown_peer} ->
        keychain
    end
  end

  # -------------------------------------------------------------------
  # Channel Key Management
  # -------------------------------------------------------------------

  @doc """
  Store a symmetric key for a channel.
  """
  @spec store_channel_key(t(), String.t(), binary()) :: t()
  def store_channel_key(%__MODULE__{} = keychain, channel_id, key)
      when is_binary(channel_id) and is_binary(key) do
    %{keychain | channel_keys: Map.put(keychain.channel_keys, channel_id, key)}
  end

  @doc """
  Retrieve a channel's symmetric key.
  """
  @spec get_channel_key(t(), String.t()) :: {:ok, binary()} | {:error, :unknown_channel}
  def get_channel_key(%__MODULE__{channel_keys: keys}, channel_id) do
    case Map.get(keys, channel_id) do
      nil -> {:error, :unknown_channel}
      key -> {:ok, key}
    end
  end

  @doc """
  Remove a channel key.
  """
  @spec remove_channel_key(t(), String.t()) :: t()
  def remove_channel_key(%__MODULE__{} = keychain, channel_id) do
    %{keychain | channel_keys: Map.delete(keychain.channel_keys, channel_id)}
  end

  # -------------------------------------------------------------------
  # Sealed Communication
  # -------------------------------------------------------------------

  @doc """
  Seal a message for a known peer.

  If a Double Ratchet session exists for the peer, uses the ratchet for
  per-message forward secrecy. Otherwise, falls back to one-shot ECDH.

  Returns `{:ok, sealed, updated_keychain}` with the ratchet-encrypted message,
  or `{:ok, sealed}` for one-shot ECDH (keychain unchanged).
  """
  @spec seal_for_peer(t(), String.t(), binary()) ::
          {:ok, map()} | {:ok, map(), t()} | {:error, :unknown_peer}
  def seal_for_peer(%__MODULE__{} = keychain, peer_agent_id, plaintext)
      when is_binary(plaintext) do
    case get_peer(keychain, peer_agent_id) do
      {:ok, %{ratchet_session: session} = peer} when not is_nil(session) ->
        # Use Double Ratchet
        {updated_session, header, ciphertext} = DoubleRatchet.encrypt(session, plaintext)

        sealed = %{
          __ratchet__: true,
          header: header,
          ciphertext: ciphertext
        }

        # Update session in keychain
        updated_peer = %{peer | ratchet_session: updated_session}
        updated_keychain = %{keychain | peers: Map.put(keychain.peers, peer_agent_id, updated_peer)}

        {:ok, sealed, updated_keychain}

      {:ok, peer} ->
        # Fall back to one-shot ECDH
        sealed =
          Crypto.seal(plaintext, peer.encryption_public, keychain.encryption_keypair.private)

        {:ok, sealed}

      {:error, :unknown_peer} = error ->
        error
    end
  end

  @doc """
  Unseal a message from a known peer.

  If the message was ratchet-encrypted and a session exists, uses the
  ratchet. Otherwise, uses one-shot ECDH.

  Returns `{:ok, plaintext, updated_keychain}` for ratchet messages,
  or `{:ok, plaintext}` for one-shot ECDH.
  """
  @spec unseal_from_peer(t(), String.t(), map()) ::
          {:ok, binary()}
          | {:ok, binary(), t()}
          | {:error, :unknown_peer | :decryption_failed | :max_skip_exceeded}
  def unseal_from_peer(%__MODULE__{} = keychain, sender_agent_id, sealed) do
    case get_peer(keychain, sender_agent_id) do
      {:ok, peer} ->
        if Map.get(sealed, :__ratchet__) do
          # Ratchet-encrypted message
          unseal_ratchet_message(keychain, sender_agent_id, peer, sealed)
        else
          # One-shot ECDH
          Crypto.unseal(sealed, keychain.encryption_keypair.private)
        end

      {:error, :unknown_peer} = error ->
        error
    end
  end

  defp unseal_ratchet_message(keychain, sender_agent_id, peer, sealed) do
    session = peer.ratchet_session

    if is_nil(session) do
      # No ratchet session, can't decrypt
      {:error, :decryption_failed}
    else
      case DoubleRatchet.decrypt(session, sealed.header, sealed.ciphertext) do
        {:ok, updated_session, plaintext} ->
          updated_peer = %{peer | ratchet_session: updated_session}
          updated_keychain = %{keychain | peers: Map.put(keychain.peers, sender_agent_id, updated_peer)}
          {:ok, plaintext, updated_keychain}

        {:error, _reason} = error ->
          error
      end
    end
  end

  # -------------------------------------------------------------------
  # Serialization / Persistence
  # -------------------------------------------------------------------

  @doc """
  Serialize a keychain for checkpoint persistence.

  Private keys and sensitive data are encrypted with the provided encryption
  key before serialization. The encryption key should be derived from the
  system authority's signing key via HKDF.

  Returns `{:ok, binary()}` containing the serialized payload.
  """
  @spec serialize(t(), binary()) :: {:ok, binary()}
  def serialize(%__MODULE__{} = keychain, encryption_key)
      when is_binary(encryption_key) and byte_size(encryption_key) == 32 do
    # Separate public and private data
    public_data = serialize_public_data(keychain)
    private_data = serialize_private_data(keychain)

    # Encrypt private data
    private_json = Jason.encode!(private_data)
    {ciphertext, iv, tag} = Crypto.encrypt(private_json, encryption_key)

    # Combine into payload
    payload = %{
      "version" => @keychain_version,
      "public" => public_data,
      "private_encrypted" => Base.encode64(ciphertext),
      "iv" => Base.encode64(iv),
      "tag" => Base.encode64(tag)
    }

    {:ok, Jason.encode!(payload)}
  end

  @doc """
  Deserialize a keychain from a checkpoint payload.

  Decrypts the private keys using the provided encryption key.

  Returns `{:ok, keychain}` or `{:error, reason}`.
  """
  @spec deserialize(binary(), binary()) :: {:ok, t()} | {:error, term()}
  def deserialize(payload, encryption_key)
      when is_binary(payload) and is_binary(encryption_key) and byte_size(encryption_key) == 32 do
    with {:ok, data} <- Jason.decode(payload),
         :ok <- verify_version(data["version"]),
         {:ok, ciphertext} <- Base.decode64(data["private_encrypted"]),
         {:ok, iv} <- Base.decode64(data["iv"]),
         {:ok, tag} <- Base.decode64(data["tag"]),
         {:ok, private_json} <- Crypto.decrypt(ciphertext, encryption_key, iv, tag),
         {:ok, private_data} <- Jason.decode(private_json) do
      build_keychain_from_data(data["public"], private_data)
    else
      {:error, :decryption_failed} -> {:error, :invalid_encryption_key}
      {:error, reason} -> {:error, reason}
      :error -> {:error, :invalid_payload}
    end
  rescue
    _ -> {:error, :invalid_payload}
  end

  @doc """
  Create an escrow backup of the keychain.

  Double-encrypts the keychain: first with the agent's encryption key,
  then with the escrow key. Used for disaster recovery by the system
  authority.

  Returns `{:ok, escrowed_binary}`.
  """
  @spec create_escrow(t(), binary(), binary()) :: {:ok, binary()}
  def create_escrow(%__MODULE__{} = keychain, agent_encryption_key, escrow_key)
      when is_binary(agent_encryption_key) and byte_size(agent_encryption_key) == 32 and
             is_binary(escrow_key) and byte_size(escrow_key) == 32 do
    # First layer: serialize with agent key
    {:ok, serialized} = serialize(keychain, agent_encryption_key)

    # Second layer: wrap with escrow key
    {ciphertext, iv, tag} = Crypto.encrypt(serialized, escrow_key)

    escrowed = %{
      "escrow_version" => 1,
      "wrapped" => Base.encode64(ciphertext),
      "iv" => Base.encode64(iv),
      "tag" => Base.encode64(tag)
    }

    {:ok, Jason.encode!(escrowed)}
  end

  @doc """
  Recover a keychain from escrow.

  Unwraps the escrow encryption, then deserializes with the agent's key.

  Returns `{:ok, keychain}` or `{:error, reason}`.
  """
  @spec recover_from_escrow(binary(), binary(), binary()) :: {:ok, t()} | {:error, term()}
  def recover_from_escrow(escrowed, escrow_key, agent_encryption_key)
      when is_binary(escrowed) and is_binary(escrow_key) and byte_size(escrow_key) == 32 and
             is_binary(agent_encryption_key) and byte_size(agent_encryption_key) == 32 do
    with {:ok, data} <- Jason.decode(escrowed),
         {:ok, ciphertext} <- Base.decode64(data["wrapped"]),
         {:ok, iv} <- Base.decode64(data["iv"]),
         {:ok, tag} <- Base.decode64(data["tag"]),
         {:ok, serialized} <- Crypto.decrypt(ciphertext, escrow_key, iv, tag) do
      deserialize(serialized, agent_encryption_key)
    else
      {:error, :decryption_failed} -> {:error, :invalid_escrow_key}
      {:error, reason} -> {:error, reason}
      :error -> {:error, :invalid_escrow_payload}
    end
  rescue
    _ -> {:error, :invalid_escrow_payload}
  end

  # -------------------------------------------------------------------
  # Private Serialization Helpers
  # -------------------------------------------------------------------

  defp serialize_public_data(keychain) do
    peers_public =
      keychain.peers
      |> Enum.map(fn {id, peer} ->
        {id,
         %{
           "signing_public" => Base.encode64(peer.signing_public),
           "encryption_public" => Base.encode64(peer.encryption_public),
           "name" => peer.name,
           "trusted_at" => DateTime.to_iso8601(peer.trusted_at)
         }}
      end)
      |> Map.new()

    %{
      "agent_id" => keychain.agent_id,
      "signing_public" => Base.encode64(keychain.signing_keypair.public),
      "encryption_public" => Base.encode64(keychain.encryption_keypair.public),
      "peers" => peers_public,
      "channel_ids" => Map.keys(keychain.channel_keys)
    }
  end

  defp serialize_private_data(keychain) do
    # Serialize ratchet sessions for each peer
    ratchet_sessions =
      keychain.peers
      |> Enum.filter(fn {_id, peer} -> not is_nil(peer.ratchet_session) end)
      |> Enum.map(fn {id, peer} -> {id, DoubleRatchet.to_map(peer.ratchet_session)} end)
      |> Map.new()

    %{
      "signing_private" => Base.encode64(keychain.signing_keypair.private),
      "encryption_private" => Base.encode64(keychain.encryption_keypair.private),
      "channel_keys" =>
        keychain.channel_keys
        |> Enum.map(fn {id, key} -> {id, Base.encode64(key)} end)
        |> Map.new(),
      "ratchet_sessions" => ratchet_sessions
    }
  end

  defp verify_version(@keychain_version), do: :ok
  defp verify_version(_), do: {:error, :unsupported_version}

  defp build_keychain_from_data(public, private) do
    with {:ok, sign_pub} <- Base.decode64(public["signing_public"]),
         {:ok, enc_pub} <- Base.decode64(public["encryption_public"]),
         {:ok, sign_priv} <- Base.decode64(private["signing_private"]),
         {:ok, enc_priv} <- Base.decode64(private["encryption_private"]),
         {:ok, peers} <- build_peers(public["peers"], private["ratchet_sessions"]),
         {:ok, channel_keys} <- build_channel_keys(private["channel_keys"]) do
      {:ok,
       %__MODULE__{
         agent_id: public["agent_id"],
         signing_keypair: %{public: sign_pub, private: sign_priv},
         encryption_keypair: %{public: enc_pub, private: enc_priv},
         peers: peers,
         channel_keys: channel_keys
       }}
    end
  end

  defp build_peers(nil, _ratchet_sessions), do: {:ok, %{}}
  defp build_peers(peers_data, ratchet_sessions) when is_map(peers_data) do
    ratchet_sessions = ratchet_sessions || %{}

    result =
      Enum.reduce_while(peers_data, {:ok, %{}}, fn {id, data}, {:ok, acc} ->
        with {:ok, sign_pub} <- Base.decode64(data["signing_public"]),
             {:ok, enc_pub} <- Base.decode64(data["encryption_public"]),
             {:ok, trusted_at, _} <- DateTime.from_iso8601(data["trusted_at"]) do
          # Restore ratchet session if one existed
          ratchet_session =
            case Map.get(ratchet_sessions, id) do
              nil -> nil
              session_data ->
                case DoubleRatchet.from_map(session_data) do
                  {:ok, session} -> session
                  {:error, _} -> nil
                end
            end

          peer = %{
            signing_public: sign_pub,
            encryption_public: enc_pub,
            name: data["name"],
            trusted_at: trusted_at,
            ratchet_session: ratchet_session
          }

          {:cont, {:ok, Map.put(acc, id, peer)}}
        else
          _ -> {:halt, {:error, :invalid_peer_data}}
        end
      end)

    result
  end

  defp build_channel_keys(nil), do: {:ok, %{}}
  defp build_channel_keys(keys_data) when is_map(keys_data) do
    result =
      Enum.reduce_while(keys_data, {:ok, %{}}, fn {id, encoded}, {:ok, acc} ->
        case Base.decode64(encoded) do
          {:ok, key} -> {:cont, {:ok, Map.put(acc, id, key)}}
          :error -> {:halt, {:error, :invalid_channel_key}}
        end
      end)

    result
  end
end
