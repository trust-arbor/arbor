defmodule Arbor.Security.Keychain do
  @moduledoc """
  Agent keychain for managing cryptographic keys and peer relationships.

  A keychain holds an agent's own Ed25519 (signing) and X25519 (encryption)
  keypairs, plus the public keys of known peers. It also stores symmetric
  channel keys for encrypted channel communication.

  This is a pure struct with functional operations — no GenServer, no
  side effects. State management is the caller's responsibility.

  ## Usage

      keychain = Keychain.new("agent_abc123")

      # Add a known peer
      keychain = Keychain.add_peer(keychain, peer_id,
        peer_signing_pub, peer_encryption_pub, "reviewer-bot")

      # Seal a message for a peer
      {:ok, sealed} = Keychain.seal_for_peer(keychain, peer_id, "secret data")

      # Unseal a message from a peer
      {:ok, plaintext} = Keychain.unseal_from_peer(keychain, sender_id, sealed)
  """

  alias Arbor.Security.Crypto

  @type peer_keys :: %{
          signing_public: binary(),
          encryption_public: binary(),
          name: String.t() | nil,
          trusted_at: DateTime.t()
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
      trusted_at: DateTime.utc_now()
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
  Seal a message for a known peer using ECDH + AES-256-GCM.

  Looks up the peer's encryption public key and seals the message so only
  they can decrypt it.
  """
  @spec seal_for_peer(t(), String.t(), binary()) :: {:ok, map()} | {:error, :unknown_peer}
  def seal_for_peer(%__MODULE__{} = keychain, peer_agent_id, plaintext)
      when is_binary(plaintext) do
    case get_peer(keychain, peer_agent_id) do
      {:ok, peer} ->
        sealed =
          Crypto.seal(plaintext, peer.encryption_public, keychain.encryption_keypair.private)

        {:ok, sealed}

      {:error, :unknown_peer} = error ->
        error
    end
  end

  @doc """
  Unseal a message from a known peer.

  The sealed message must contain the sender's public key. This function
  verifies the sender is a known peer before decrypting.
  """
  @spec unseal_from_peer(t(), String.t(), map()) ::
          {:ok, binary()} | {:error, :unknown_peer | :decryption_failed}
  def unseal_from_peer(%__MODULE__{} = keychain, sender_agent_id, sealed) do
    case get_peer(keychain, sender_agent_id) do
      {:ok, _peer} ->
        Crypto.unseal(sealed, keychain.encryption_keypair.private)

      {:error, :unknown_peer} = error ->
        error
    end
  end
end
