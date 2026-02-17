defmodule Arbor.Signals.TopicKeys do
  @moduledoc """
  Symmetric key management for restricted signal topics.

  Each restricted topic (`:security`, `:identity`) gets its own AES-256-GCM
  symmetric key. Signals on these topics are encrypted at emit time and
  decrypted at delivery time for authorized subscribers.

  Uses `apply/3` for runtime module resolution to avoid a compile-time
  dependency on `arbor_security`.

  ## Key Lifecycle

  1. Keys are generated on first access via `get_or_create/1`
  2. Authorized subscribers receive the topic key when subscription is approved
  3. Keys can be rotated via `rotate/1`, which re-encrypts for current subscribers

  ## Configuration

  The crypto module is resolved via:

      Application.get_env(:arbor_signals, :crypto_module, Arbor.Security.Crypto)
  """

  use GenServer

  require Logger

  @type topic :: atom()
  @type key_info :: %{
          key: binary(),
          version: pos_integer(),
          created_at: DateTime.t(),
          rotated_at: DateTime.t() | nil
        }

  # Client API

  @doc """
  Start the topic keys manager.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get or create a symmetric key for a topic.

  Returns `{:ok, key_info}` with the current key and version.
  """
  @spec get_or_create(topic()) :: {:ok, key_info()}
  def get_or_create(topic) when is_atom(topic) do
    GenServer.call(__MODULE__, {:get_or_create, topic})
  end

  @doc """
  Get the current key for a topic without creating one.

  Returns `{:error, :no_key}` if no key exists.
  """
  @spec get(topic()) :: {:ok, key_info()} | {:error, :no_key}
  def get(topic) when is_atom(topic) do
    GenServer.call(__MODULE__, {:get, topic})
  end

  @doc """
  Rotate the key for a topic.

  Generates a new key and increments the version. The old key is discarded.
  Returns `{:ok, new_key_info}`.
  """
  @spec rotate(topic()) :: {:ok, key_info()}
  def rotate(topic) when is_atom(topic) do
    GenServer.call(__MODULE__, {:rotate, topic})
  end

  @doc """
  Encrypt data using the topic's symmetric key.

  Returns `{:ok, encrypted_payload}` where `encrypted_payload` is a map with:
  - `:ciphertext` - The encrypted data
  - `:iv` - The initialization vector
  - `:tag` - The authentication tag
  - `:key_version` - The key version used for encryption
  """
  @spec encrypt(topic(), binary()) :: {:ok, map()} | {:error, term()}
  def encrypt(topic, plaintext) when is_atom(topic) and is_binary(plaintext) do
    GenServer.call(__MODULE__, {:encrypt, topic, plaintext})
  end

  @doc """
  Decrypt data using the topic's symmetric key.

  Returns `{:ok, plaintext}` on success, `{:error, reason}` on failure.
  """
  @spec decrypt(topic(), map()) :: {:ok, binary()} | {:error, term()}
  def decrypt(topic, encrypted_payload) when is_atom(topic) and is_map(encrypted_payload) do
    GenServer.call(__MODULE__, {:decrypt, topic, encrypted_payload})
  end

  @doc """
  Get statistics about managed topic keys.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    {:ok,
     %{
       keys: %{},
       stats: %{
         keys_created: 0,
         keys_rotated: 0,
         encryptions: 0,
         decryptions: 0
       }
     }}
  end

  @impl true
  def handle_call({:get_or_create, topic}, _from, state) do
    case Map.get(state.keys, topic) do
      nil ->
        key_info = generate_key_info()
        state = put_in(state, [:keys, topic], key_info)
        state = update_in(state, [:stats, :keys_created], &(&1 + 1))
        {:reply, {:ok, key_info}, state}

      key_info ->
        {:reply, {:ok, key_info}, state}
    end
  end

  @impl true
  def handle_call({:get, topic}, _from, state) do
    case Map.get(state.keys, topic) do
      nil -> {:reply, {:error, :no_key}, state}
      key_info -> {:reply, {:ok, key_info}, state}
    end
  end

  @impl true
  def handle_call({:rotate, topic}, _from, state) do
    current_version =
      case Map.get(state.keys, topic) do
        nil -> 0
        %{version: v} -> v
      end

    key_info = generate_key_info(current_version + 1)
    key_info = Map.put(key_info, :rotated_at, DateTime.utc_now())

    state = put_in(state, [:keys, topic], key_info)
    state = update_in(state, [:stats, :keys_rotated], &(&1 + 1))
    {:reply, {:ok, key_info}, state}
  end

  @impl true
  def handle_call({:encrypt, topic, plaintext}, _from, state) do
    case Map.get(state.keys, topic) do
      nil ->
        # Auto-create key on first encrypt
        key_info = generate_key_info()
        state = put_in(state, [:keys, topic], key_info)
        state = update_in(state, [:stats, :keys_created], &(&1 + 1))
        result = do_encrypt(plaintext, key_info)
        state = update_in(state, [:stats, :encryptions], &(&1 + 1))
        {:reply, result, state}

      key_info ->
        result = do_encrypt(plaintext, key_info)
        state = update_in(state, [:stats, :encryptions], &(&1 + 1))
        {:reply, result, state}
    end
  end

  @impl true
  def handle_call({:decrypt, topic, encrypted_payload}, _from, state) do
    case Map.get(state.keys, topic) do
      nil ->
        {:reply, {:error, :no_key}, state}

      key_info ->
        result = do_decrypt(encrypted_payload, key_info)
        state = update_in(state, [:stats, :decryptions], &(&1 + 1))
        {:reply, result, state}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats =
      Map.merge(state.stats, %{
        active_topic_keys: map_size(state.keys),
        topics: Map.keys(state.keys)
      })

    {:reply, stats, state}
  end

  # Private helpers

  defp generate_key_info(version \\ 1) do
    crypto_module = crypto_module()
    # Generate 32 bytes for AES-256
    key = :crypto.strong_rand_bytes(32)

    %{
      key: key,
      version: version,
      created_at: DateTime.utc_now(),
      rotated_at: nil,
      # Store the module used for potential future compatibility checks
      crypto_module: crypto_module
    }
  end

  defp do_encrypt(plaintext, %{key: key, version: version}) do
    crypto_module = crypto_module()

    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    {ciphertext, iv, tag} = apply(crypto_module, :encrypt, [plaintext, key])

    {:ok,
     %{
       ciphertext: ciphertext,
       iv: iv,
       tag: tag,
       key_version: version
     }}
  end

  defp do_decrypt(%{ciphertext: ciphertext, iv: iv, tag: tag, key_version: payload_version}, %{
         key: key,
         version: current_version
       }) do
    if payload_version != current_version do
      Logger.warning("Topic key version mismatch: payload=#{payload_version} current=#{current_version}")
      {:error, :key_version_mismatch}
    else
      crypto_module = crypto_module()
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(crypto_module, :decrypt, [ciphertext, key, iv, tag])
    end
  end

  defp do_decrypt(_invalid_payload, _key_info) do
    {:error, :invalid_payload}
  end

  defp crypto_module do
    Application.get_env(:arbor_signals, :crypto_module, Arbor.Security.Crypto)
  end
end
