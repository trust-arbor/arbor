defmodule Arbor.Security.DoubleRatchet do
  @moduledoc """
  Double Ratchet protocol for per-message forward secrecy.

  Uses X25519 DH ratchet + HKDF symmetric-key ratchet + AES-256-GCM.
  Two-party only — for multi-party channels, use periodic rotation.

  ## Protocol Overview

  The Double Ratchet provides per-message forward secrecy for two-party
  (peer-to-peer) sealed communications. If any single message key is
  compromised, past and future messages remain secure.

  ### Protocol Flow

  1. Agents establish a shared secret via X25519 ECDH
  2. Sender calls `encrypt/3` — KDF chain produces per-message key
  3. Receiver calls `decrypt/4` — if new DH public key in header, DH ratchet step
  4. Skipped messages: receiver stores skipped message keys for out-of-order delivery

  ## Session Structure

  Each session maintains:
  - `dh_keypair` — current X25519 ratchet keypair
  - `dh_remote` — peer's current DH public key
  - `root_key` — root chain key (32 bytes)
  - `send_chain` — sending KDF chain state
  - `recv_chain` — receiving KDF chain state
  - `skipped_keys` — message keys for out-of-order decryption
  - `max_skip` — maximum skipped messages to store (default: 100)

  ## Usage

      # Alice initiates (sender)
      alice_session = DoubleRatchet.init_sender(shared_secret, bob_dh_public)
      {alice_session, header, ciphertext} = DoubleRatchet.encrypt(alice_session, "hello")

      # Bob receives (receiver)
      bob_session = DoubleRatchet.init_receiver(shared_secret, bob_dh_keypair)
      {:ok, bob_session, plaintext} = DoubleRatchet.decrypt(bob_session, header, ciphertext)

  """

  alias Arbor.Security.Crypto

  @default_max_skip 100
  @root_info "arbor-dr-root-v1"
  @chain_info "arbor-dr-chain-v1"
  @msg_info "arbor-dr-msg-v1"

  @type chain :: %{key: binary(), n: non_neg_integer()}

  @type t :: %__MODULE__{
          dh_keypair: {public :: binary(), private :: binary()},
          dh_remote: binary() | nil,
          root_key: binary(),
          send_chain: chain(),
          recv_chain: chain(),
          skipped_keys: %{{binary(), non_neg_integer()} => binary()},
          max_skip: non_neg_integer()
        }

  @enforce_keys [:dh_keypair, :root_key, :send_chain, :recv_chain]
  defstruct [
    :dh_keypair,
    :dh_remote,
    :root_key,
    send_chain: %{key: nil, n: 0},
    recv_chain: %{key: nil, n: 0},
    skipped_keys: %{},
    max_skip: @default_max_skip
  ]

  @type header :: %{
          dh_public: binary(),
          n: non_neg_integer(),
          pn: non_neg_integer()
        }

  # ===========================================================================
  # Session Initialization
  # ===========================================================================

  @doc """
  Initialize a sender session for the Double Ratchet protocol.

  The sender creates a new DH keypair and derives initial chain keys from
  the shared secret and remote party's DH public key.

  ## Parameters

  - `shared_secret` — pre-shared secret established via initial key exchange
  - `remote_dh_public` — the peer's X25519 DH public key (32 bytes)
  - `opts` — optional settings:
    - `:max_skip` — maximum skipped messages to store (default: #{@default_max_skip})

  ## Returns

  A session struct ready for sending messages.
  """
  @spec init_sender(binary(), binary(), keyword()) :: t()
  def init_sender(shared_secret, remote_dh_public, opts \\ [])
      when is_binary(shared_secret) and is_binary(remote_dh_public) do
    max_skip = Keyword.get(opts, :max_skip, @default_max_skip)

    # Generate sender's DH keypair
    dh_keypair = Crypto.generate_encryption_keypair()
    {dh_public, dh_private} = dh_keypair

    # Perform DH to derive initial root and chain keys
    dh_output = Crypto.derive_shared_secret(dh_private, remote_dh_public)
    {root_key, send_chain_key} = kdf_root(shared_secret, dh_output)

    %__MODULE__{
      dh_keypair: {dh_public, dh_private},
      dh_remote: remote_dh_public,
      root_key: root_key,
      send_chain: %{key: send_chain_key, n: 0},
      recv_chain: %{key: nil, n: 0},
      skipped_keys: %{},
      max_skip: max_skip
    }
  end

  @doc """
  Initialize a receiver session for the Double Ratchet protocol.

  The receiver uses their existing DH keypair and waits for the first
  message to perform the initial DH ratchet step.

  ## Parameters

  - `shared_secret` — pre-shared secret established via initial key exchange
  - `my_dh_keypair` — the receiver's X25519 keypair `{public, private}`
  - `opts` — optional settings:
    - `:max_skip` — maximum skipped messages to store (default: #{@default_max_skip})

  ## Returns

  A session struct ready for receiving messages.
  """
  @spec init_receiver(binary(), {binary(), binary()}, keyword()) :: t()
  def init_receiver(shared_secret, {dh_public, dh_private} = dh_keypair, opts \\ [])
      when is_binary(shared_secret) and is_binary(dh_public) and is_binary(dh_private) do
    max_skip = Keyword.get(opts, :max_skip, @default_max_skip)

    %__MODULE__{
      dh_keypair: dh_keypair,
      dh_remote: nil,
      root_key: shared_secret,
      send_chain: %{key: nil, n: 0},
      recv_chain: %{key: nil, n: 0},
      skipped_keys: %{},
      max_skip: max_skip
    }
  end

  # ===========================================================================
  # Message Encryption
  # ===========================================================================

  @doc """
  Encrypt a message using the Double Ratchet protocol.

  Advances the sending chain and produces a unique message key for this message.
  Returns the updated session, a header (containing DH public key and counters),
  and the ciphertext.

  ## Parameters

  - `session` — the sender's session state
  - `plaintext` — the message to encrypt (binary)
  - `aad` — optional additional authenticated data (default: "")

  ## Returns

  `{updated_session, header, ciphertext}` where:
  - `header` — contains `:dh_public`, `:n`, `:pn` (previous chain length)
  - `ciphertext` — the encrypted message (includes IV and tag)
  """
  @spec encrypt(t(), binary(), binary()) :: {t(), header(), binary()}
  def encrypt(%__MODULE__{} = session, plaintext, aad \\ "")
      when is_binary(plaintext) and is_binary(aad) do
    # Advance the sending chain
    {chain_key, message_key} = kdf_chain(session.send_chain.key)

    # Build header
    {dh_public, _dh_private} = session.dh_keypair

    header = %{
      dh_public: dh_public,
      n: session.send_chain.n,
      pn: session.recv_chain.n
    }

    # Encrypt with message key
    ciphertext = encrypt_with_key(plaintext, message_key, header, aad)

    # Update session
    updated_session = %{
      session
      | send_chain: %{key: chain_key, n: session.send_chain.n + 1}
    }

    {updated_session, header, ciphertext}
  end

  # ===========================================================================
  # Message Decryption
  # ===========================================================================

  @doc """
  Decrypt a message using the Double Ratchet protocol.

  May perform a DH ratchet step if the header contains a new DH public key.
  Handles out-of-order messages using the skipped keys store.

  ## Parameters

  - `session` — the receiver's session state
  - `header` — the message header from `encrypt/3`
  - `ciphertext` — the encrypted message
  - `aad` — optional additional authenticated data (must match encryption)

  ## Returns

  - `{:ok, updated_session, plaintext}` on success
  - `{:error, :decryption_failed}` if decryption fails
  - `{:error, :max_skip_exceeded}` if too many messages were skipped
  """
  @spec decrypt(t(), header(), binary(), binary()) ::
          {:ok, t(), binary()} | {:error, :decryption_failed | :max_skip_exceeded}
  def decrypt(%__MODULE__{} = session, header, ciphertext, aad \\ "")
      when is_map(header) and is_binary(ciphertext) and is_binary(aad) do
    # Check skipped keys first
    case try_skipped_keys(session, header, ciphertext, aad) do
      {:ok, session, plaintext} ->
        {:ok, session, plaintext}

      :not_found ->
        # Need to ratchet or advance chain
        with {:ok, session} <- maybe_dh_ratchet(session, header),
             {:ok, session} <- skip_message_keys(session, header.n) do
          decrypt_current(session, header, ciphertext, aad)
        end
    end
  end

  # ===========================================================================
  # Serialization (for Keychain persistence)
  # ===========================================================================

  @doc """
  Serialize a session to a map for storage.

  Returns a map that can be JSON-encoded and encrypted.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = session) do
    {dh_public, dh_private} = session.dh_keypair

    skipped_keys_list =
      session.skipped_keys
      |> Enum.map(fn {{dh_pub, n}, key} ->
        %{
          "dh_public" => Base.encode64(dh_pub),
          "n" => n,
          "key" => Base.encode64(key)
        }
      end)

    %{
      "dh_public" => Base.encode64(dh_public),
      "dh_private" => Base.encode64(dh_private),
      "dh_remote" => if(session.dh_remote, do: Base.encode64(session.dh_remote), else: nil),
      "root_key" => Base.encode64(session.root_key),
      "send_chain_key" =>
        if(session.send_chain.key, do: Base.encode64(session.send_chain.key), else: nil),
      "send_chain_n" => session.send_chain.n,
      "recv_chain_key" =>
        if(session.recv_chain.key, do: Base.encode64(session.recv_chain.key), else: nil),
      "recv_chain_n" => session.recv_chain.n,
      "skipped_keys" => skipped_keys_list,
      "max_skip" => session.max_skip
    }
  end

  @doc """
  Deserialize a session from a map.

  Returns `{:ok, session}` or `{:error, reason}`.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(data) when is_map(data) do
    with {:ok, dh_public} <- decode_binary(data["dh_public"]),
         {:ok, dh_private} <- decode_binary(data["dh_private"]),
         {:ok, dh_remote} <- decode_optional_binary(data["dh_remote"]),
         {:ok, root_key} <- decode_binary(data["root_key"]),
         {:ok, send_chain_key} <- decode_optional_binary(data["send_chain_key"]),
         {:ok, recv_chain_key} <- decode_optional_binary(data["recv_chain_key"]),
         {:ok, skipped_keys} <- decode_skipped_keys(data["skipped_keys"]) do
      {:ok,
       %__MODULE__{
         dh_keypair: {dh_public, dh_private},
         dh_remote: dh_remote,
         root_key: root_key,
         send_chain: %{key: send_chain_key, n: data["send_chain_n"] || 0},
         recv_chain: %{key: recv_chain_key, n: data["recv_chain_n"] || 0},
         skipped_keys: skipped_keys,
         max_skip: data["max_skip"] || @default_max_skip
       }}
    end
  rescue
    _ -> {:error, :invalid_session_data}
  end

  # ===========================================================================
  # Private Functions — Key Derivation
  # ===========================================================================

  # Root KDF: derive new root key and chain key from root key and DH output
  defp kdf_root(root_key, dh_output) do
    # Combine root key and DH output
    ikm = root_key <> dh_output

    # Derive 64 bytes: first 32 for new root key, next 32 for chain key
    output = Crypto.derive_key(ikm, @root_info, 64)
    <<new_root_key::binary-size(32), chain_key::binary-size(32)>> = output
    {new_root_key, chain_key}
  end

  # Chain KDF: derive new chain key and message key from chain key
  defp kdf_chain(chain_key) do
    # Derive 64 bytes: first 32 for new chain key, next 32 for message key
    output = Crypto.derive_key(chain_key, @chain_info, 64)
    <<new_chain_key::binary-size(32), message_key::binary-size(32)>> = output
    {new_chain_key, message_key}
  end

  # ===========================================================================
  # Private Functions — Encryption/Decryption
  # ===========================================================================

  defp encrypt_with_key(plaintext, message_key, header, aad) do
    # Derive encryption key from message key
    enc_key = Crypto.derive_key(message_key, @msg_info, 32)

    # Include header in AAD for authentication
    header_bytes = encode_header(header)
    full_aad = header_bytes <> aad

    {ciphertext, iv, tag} = Crypto.encrypt(plaintext, enc_key, full_aad)

    # Pack ciphertext, IV, and tag together
    iv <> tag <> ciphertext
  end

  defp decrypt_with_key(packed_ciphertext, message_key, header, aad) do
    # Unpack IV, tag, and ciphertext
    <<iv::binary-size(12), tag::binary-size(16), ciphertext::binary>> = packed_ciphertext

    # Derive encryption key from message key
    enc_key = Crypto.derive_key(message_key, @msg_info, 32)

    # Include header in AAD for authentication
    header_bytes = encode_header(header)
    full_aad = header_bytes <> aad

    Crypto.decrypt(ciphertext, enc_key, iv, tag, full_aad)
  end

  defp encode_header(header) do
    # Simple binary encoding for AAD
    header.dh_public <> <<header.n::32, header.pn::32>>
  end

  # ===========================================================================
  # Private Functions — Ratchet Steps
  # ===========================================================================

  defp try_skipped_keys(session, header, ciphertext, aad) do
    key_id = {header.dh_public, header.n}

    case Map.get(session.skipped_keys, key_id) do
      nil ->
        :not_found

      message_key ->
        case decrypt_with_key(ciphertext, message_key, header, aad) do
          {:ok, plaintext} ->
            # Remove used key
            session = %{session | skipped_keys: Map.delete(session.skipped_keys, key_id)}
            {:ok, session, plaintext}

          {:error, :decryption_failed} ->
            {:error, :decryption_failed}
        end
    end
  end

  defp maybe_dh_ratchet(session, header) do
    if session.dh_remote != header.dh_public do
      # New DH public key — perform DH ratchet
      with {:ok, session} <- skip_message_keys(session, header.pn) do
        dh_ratchet(session, header.dh_public)
      end
    else
      {:ok, session}
    end
  end

  defp dh_ratchet(session, remote_dh_public) do
    {_my_public, my_private} = session.dh_keypair

    # Derive receive chain from current DH
    dh_output = Crypto.derive_shared_secret(my_private, remote_dh_public)
    {root_key, recv_chain_key} = kdf_root(session.root_key, dh_output)

    # Generate new DH keypair
    new_dh_keypair = Crypto.generate_encryption_keypair()
    {new_dh_public, new_dh_private} = new_dh_keypair

    # Derive send chain from new DH
    dh_output2 = Crypto.derive_shared_secret(new_dh_private, remote_dh_public)
    {root_key2, send_chain_key} = kdf_root(root_key, dh_output2)

    {:ok,
     %{
       session
       | dh_keypair: {new_dh_public, new_dh_private},
         dh_remote: remote_dh_public,
         root_key: root_key2,
         send_chain: %{key: send_chain_key, n: 0},
         recv_chain: %{key: recv_chain_key, n: 0}
     }}
  end

  defp skip_message_keys(session, until) do
    if session.recv_chain.key == nil do
      {:ok, session}
    else
      skip_count = until - session.recv_chain.n

      if skip_count > session.max_skip do
        {:error, :max_skip_exceeded}
      else
        do_skip_keys(session, until)
      end
    end
  end

  defp do_skip_keys(session, until) when session.recv_chain.n >= until do
    {:ok, session}
  end

  defp do_skip_keys(session, until) do
    # Advance chain and store the message key
    {chain_key, message_key} = kdf_chain(session.recv_chain.key)
    key_id = {session.dh_remote, session.recv_chain.n}

    session = %{
      session
      | recv_chain: %{key: chain_key, n: session.recv_chain.n + 1},
        skipped_keys: Map.put(session.skipped_keys, key_id, message_key)
    }

    do_skip_keys(session, until)
  end

  defp decrypt_current(session, header, ciphertext, aad) do
    # Advance receive chain
    {chain_key, message_key} = kdf_chain(session.recv_chain.key)

    case decrypt_with_key(ciphertext, message_key, header, aad) do
      {:ok, plaintext} ->
        session = %{session | recv_chain: %{key: chain_key, n: session.recv_chain.n + 1}}
        {:ok, session, plaintext}

      {:error, :decryption_failed} ->
        {:error, :decryption_failed}
    end
  end

  # ===========================================================================
  # Private Functions — Serialization Helpers
  # ===========================================================================

  defp decode_binary(nil), do: {:error, :missing_field}
  defp decode_binary(str) when is_binary(str), do: Base.decode64(str)

  defp decode_optional_binary(nil), do: {:ok, nil}
  defp decode_optional_binary(str), do: Base.decode64(str)

  defp decode_skipped_keys(nil), do: {:ok, %{}}
  defp decode_skipped_keys([]), do: {:ok, %{}}

  defp decode_skipped_keys(list) when is_list(list) do
    result =
      Enum.reduce_while(list, {:ok, %{}}, fn entry, {:ok, acc} ->
        with {:ok, dh_pub} <- decode_binary(entry["dh_public"]),
             {:ok, key} <- decode_binary(entry["key"]) do
          key_id = {dh_pub, entry["n"]}
          {:cont, {:ok, Map.put(acc, key_id, key)}}
        else
          error -> {:halt, error}
        end
      end)

    result
  end
end
