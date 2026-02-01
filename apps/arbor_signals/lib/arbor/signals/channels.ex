defmodule Arbor.Signals.Channels do
  @moduledoc """
  Manager for encrypted communication channels.

  Handles channel lifecycle: create, invite, accept invitation, send messages,
  leave, and key rotation. Uses `apply/3` for runtime module resolution to
  avoid compile-time dependencies on `arbor_security`.

  ## Channel Keys

  Each channel has an AES-256-GCM symmetric key. When inviting a member:

  1. Look up invitee's encryption public key from Identity Registry
  2. Seal the channel key using ECDH + AES-GCM (via Arbor.Security.Crypto.seal/3)
  3. Emit an invitation signal with the sealed key
  4. Invitee accepts by unsealing the key and storing in their keychain

  ## Configuration

  Modules are resolved via application config:

      config :arbor_signals,
        crypto_module: Arbor.Security.Crypto,
        identity_registry_module: Arbor.Security.Identity.Registry
  """

  use GenServer

  alias Arbor.Identifiers
  alias Arbor.Signals.Bus
  alias Arbor.Signals.Channel
  alias Arbor.Signals.Signal

  @type channel_id :: String.t()
  @type agent_id :: String.t()

  @type channel_entry :: %{
          channel: Channel.t(),
          key: binary(),
          pending_invitations: %{agent_id() => map()}
        }

  # Client API

  @doc """
  Start the channels manager.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Create a new encrypted channel.

  Generates an AES-256-GCM key and creates the channel with the creator
  as the first member.

  Returns `{:ok, channel, key}` where `key` is the symmetric channel key
  that the creator should store in their keychain.
  """
  @spec create(String.t(), String.t(), keyword()) :: {:ok, Channel.t(), binary()}
  def create(name, creator_id, opts \\ []) when is_binary(name) and is_binary(creator_id) do
    GenServer.call(__MODULE__, {:create, name, creator_id, opts})
  end

  @doc """
  Invite an agent to a channel.

  Looks up the invitee's encryption public key from the Identity Registry
  and seals the channel key for them. The sealed key is included in an
  invitation signal.

  Requires `sender_keychain` to contain the sender's encryption private key.

  Returns `{:ok, invitation}` with the sealed key, or an error.
  """
  @spec invite(channel_id(), agent_id(), map()) ::
          {:ok, map()} | {:error, term()}
  def invite(channel_id, invitee_id, sender_keychain)
      when is_binary(channel_id) and is_binary(invitee_id) and is_map(sender_keychain) do
    GenServer.call(__MODULE__, {:invite, channel_id, invitee_id, sender_keychain})
  end

  @doc """
  Accept a channel invitation.

  Unseals the channel key using the recipient's encryption private key
  and adds the agent as a member.

  Returns `{:ok, channel, key}` where `key` is the decrypted channel key.
  """
  @spec accept_invitation(channel_id(), agent_id(), map(), map()) ::
          {:ok, Channel.t(), binary()} | {:error, term()}
  def accept_invitation(channel_id, agent_id, sealed_key, recipient_keychain)
      when is_binary(channel_id) and is_binary(agent_id) and is_map(sealed_key) and
             is_map(recipient_keychain) do
    GenServer.call(__MODULE__, {:accept_invitation, channel_id, agent_id, sealed_key, recipient_keychain})
  end

  @doc """
  Send a message on a channel.

  Encrypts the message data with the channel key and publishes a signal
  on the channel topic.

  Returns `:ok` on success.
  """
  @spec send(channel_id(), agent_id(), atom(), map()) :: :ok | {:error, term()}
  def send(channel_id, sender_id, message_type, data)
      when is_binary(channel_id) and is_binary(sender_id) and is_atom(message_type) and is_map(data) do
    GenServer.call(__MODULE__, {:send, channel_id, sender_id, message_type, data})
  end

  @doc """
  Leave a channel.

  Removes the agent from the channel. If the leaving agent is the creator
  and other members remain, a new creator is assigned and the key is rotated.

  Returns `:ok` on success.
  """
  @spec leave(channel_id(), agent_id()) :: :ok | {:error, term()}
  def leave(channel_id, agent_id) when is_binary(channel_id) and is_binary(agent_id) do
    GenServer.call(__MODULE__, {:leave, channel_id, agent_id})
  end

  @doc """
  Rotate the channel key.

  Generates a new key and increments the version. Callers must re-distribute
  the new key to members via sealed invitations.

  Returns `{:ok, new_key, members_to_reinvite}`.
  """
  @spec rotate_key(channel_id(), agent_id()) :: {:ok, binary(), [agent_id()]} | {:error, term()}
  def rotate_key(channel_id, requester_id) when is_binary(channel_id) and is_binary(requester_id) do
    GenServer.call(__MODULE__, {:rotate_key, channel_id, requester_id})
  end

  @doc """
  Get a channel by ID.

  Returns `{:ok, channel}` or `{:error, :not_found}`.
  """
  @spec get(channel_id()) :: {:ok, Channel.t()} | {:error, :not_found}
  def get(channel_id) when is_binary(channel_id) do
    GenServer.call(__MODULE__, {:get, channel_id})
  end

  @doc """
  Get the channel key for a member.

  Returns `{:ok, key}` or `{:error, reason}`.
  """
  @spec get_key(channel_id(), agent_id()) :: {:ok, binary()} | {:error, term()}
  def get_key(channel_id, agent_id) when is_binary(channel_id) and is_binary(agent_id) do
    GenServer.call(__MODULE__, {:get_key, channel_id, agent_id})
  end

  @doc """
  List all channels an agent is a member of.
  """
  @spec list_channels(agent_id()) :: [Channel.t()]
  def list_channels(agent_id) when is_binary(agent_id) do
    GenServer.call(__MODULE__, {:list_channels, agent_id})
  end

  @doc """
  Get statistics about managed channels.
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
       channels: %{},
       stats: %{
         channels_created: 0,
         invitations_sent: 0,
         invitations_accepted: 0,
         messages_sent: 0,
         key_rotations: 0
       }
     }}
  end

  @impl true
  def handle_call({:create, name, creator_id, opts}, _from, state) do
    channel_id = generate_channel_id()
    key = :crypto.strong_rand_bytes(32)
    channel = Channel.new(channel_id, name, creator_id, opts)

    entry = %{
      channel: channel,
      key: key,
      pending_invitations: %{}
    }

    state = put_in(state, [:channels, channel_id], entry)
    state = update_in(state, [:stats, :channels_created], &(&1 + 1))

    {:reply, {:ok, channel, key}, state}
  end

  @impl true
  def handle_call({:invite, channel_id, invitee_id, sender_keychain}, _from, state) do
    with {:ok, entry} <- get_channel_entry(state, channel_id),
         :ok <- verify_member(entry.channel, sender_keychain.agent_id),
         {:ok, invitee_enc_pub} <- lookup_encryption_key(invitee_id) do
      # Seal the channel key for the invitee
      sealed_key = seal_key(entry.key, invitee_enc_pub, sender_keychain.encryption_keypair.private)

      invitation = %{
        channel_id: channel_id,
        channel_name: entry.channel.name,
        inviter_id: sender_keychain.agent_id,
        sealed_key: sealed_key,
        invited_at: DateTime.utc_now()
      }

      # Store pending invitation
      state =
        update_in(state, [:channels, channel_id, :pending_invitations], fn pending ->
          Map.put(pending, invitee_id, invitation)
        end)

      state = update_in(state, [:stats, :invitations_sent], &(&1 + 1))

      # Emit invitation signal (not encrypted since it contains the sealed key)
      signal = Signal.new(:channel, :invitation, invitation)
      Bus.publish(signal)

      {:reply, {:ok, invitation}, state}
    else
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:accept_invitation, channel_id, agent_id, sealed_key, recipient_keychain}, _from, state) do
    with {:ok, entry} <- get_channel_entry(state, channel_id),
         {:ok, key} <- unseal_key(sealed_key, recipient_keychain.encryption_keypair.private) do
      # Verify the unsealed key matches (in case of tampering or wrong key)
      if key != entry.key do
        {:reply, {:error, :key_mismatch}, state}
      else
        # Add member to channel
        updated_channel = Channel.add_member(entry.channel, agent_id)

        state =
          state
          |> put_in([:channels, channel_id, :channel], updated_channel)
          |> update_in([:channels, channel_id, :pending_invitations], &Map.delete(&1, agent_id))
          |> update_in([:stats, :invitations_accepted], &(&1 + 1))

        # Emit acceptance signal
        signal =
          Signal.new(:channel, :member_joined, %{
            channel_id: channel_id,
            agent_id: agent_id
          })

        Bus.publish(signal)

        {:reply, {:ok, updated_channel, key}, state}
      end
    else
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:send, channel_id, sender_id, message_type, data}, _from, state) do
    with {:ok, entry} <- get_channel_entry(state, channel_id),
         :ok <- verify_member(entry.channel, sender_id) do
      # Encrypt data with channel key
      case encrypt_message(data, entry.key, entry.channel.key_version) do
        {:ok, encrypted_payload} ->
          signal =
            Signal.new(
              :channel,
              message_type,
              %{
                __channel_encrypted__: true,
                channel_id: channel_id,
                sender_id: sender_id,
                payload: encrypted_payload
              },
              source: sender_id
            )

          Bus.publish(signal)
          state = update_in(state, [:stats, :messages_sent], &(&1 + 1))
          {:reply, :ok, state}

        {:error, _reason} = error ->
          {:reply, error, state}
      end
    else
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:leave, channel_id, agent_id}, _from, state) do
    with {:ok, entry} <- get_channel_entry(state, channel_id),
         :ok <- verify_member(entry.channel, agent_id) do
      updated_channel = Channel.remove_member(entry.channel, agent_id)

      if MapSet.size(updated_channel.members) == 0 do
        # Last member left, delete channel
        state = update_in(state, [:channels], &Map.delete(&1, channel_id))
        {:reply, :ok, state}
      else
        # Assign new creator if the leaving member was creator
        updated_channel =
          if updated_channel.creator_id == agent_id do
            [new_creator | _] = MapSet.to_list(updated_channel.members)
            %{updated_channel | creator_id: new_creator}
          else
            updated_channel
          end

        state = put_in(state, [:channels, channel_id, :channel], updated_channel)

        # Emit leave signal
        signal =
          Signal.new(:channel, :member_left, %{
            channel_id: channel_id,
            agent_id: agent_id
          })

        Bus.publish(signal)

        {:reply, :ok, state}
      end
    else
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:rotate_key, channel_id, requester_id}, _from, state) do
    with {:ok, entry} <- get_channel_entry(state, channel_id),
         :ok <- verify_creator(entry.channel, requester_id) do
      new_key = :crypto.strong_rand_bytes(32)
      updated_channel = Channel.increment_key_version(entry.channel)

      state =
        state
        |> put_in([:channels, channel_id, :key], new_key)
        |> put_in([:channels, channel_id, :channel], updated_channel)
        |> update_in([:stats, :key_rotations], &(&1 + 1))

      # Members who need to be re-invited with new key (except requester)
      members_to_reinvite =
        updated_channel.members
        |> MapSet.delete(requester_id)
        |> MapSet.to_list()

      # Emit key rotation signal
      signal =
        Signal.new(:channel, :key_rotated, %{
          channel_id: channel_id,
          new_version: updated_channel.key_version,
          rotated_by: requester_id
        })

      Bus.publish(signal)

      {:reply, {:ok, new_key, members_to_reinvite}, state}
    else
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:get, channel_id}, _from, state) do
    case Map.get(state.channels, channel_id) do
      nil -> {:reply, {:error, :not_found}, state}
      entry -> {:reply, {:ok, entry.channel}, state}
    end
  end

  @impl true
  def handle_call({:get_key, channel_id, agent_id}, _from, state) do
    with {:ok, entry} <- get_channel_entry(state, channel_id),
         :ok <- verify_member(entry.channel, agent_id) do
      {:reply, {:ok, entry.key}, state}
    else
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:list_channels, agent_id}, _from, state) do
    channels =
      state.channels
      |> Map.values()
      |> Enum.filter(fn entry -> Channel.member?(entry.channel, agent_id) end)
      |> Enum.map(fn entry -> entry.channel end)

    {:reply, channels, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats =
      Map.merge(state.stats, %{
        active_channels: map_size(state.channels),
        total_members:
          state.channels
          |> Map.values()
          |> Enum.map(fn entry -> MapSet.size(entry.channel.members) end)
          |> Enum.sum()
      })

    {:reply, stats, state}
  end

  # Private helpers

  defp get_channel_entry(state, channel_id) do
    case Map.get(state.channels, channel_id) do
      nil -> {:error, :not_found}
      entry -> {:ok, entry}
    end
  end

  defp verify_member(channel, agent_id) do
    if Channel.member?(channel, agent_id) do
      :ok
    else
      {:error, :not_a_member}
    end
  end

  defp verify_creator(channel, agent_id) do
    if channel.creator_id == agent_id do
      :ok
    else
      {:error, :not_creator}
    end
  end

  defp lookup_encryption_key(agent_id) do
    registry_module = identity_registry_module()
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    apply(registry_module, :lookup_encryption_key, [agent_id])
  end

  defp seal_key(key, recipient_public, sender_private) do
    crypto_module = crypto_module()
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    apply(crypto_module, :seal, [key, recipient_public, sender_private])
  end

  defp unseal_key(sealed, recipient_private) do
    crypto_module = crypto_module()
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    apply(crypto_module, :unseal, [sealed, recipient_private])
  end

  defp encrypt_message(data, key, key_version) do
    case Jason.encode(data) do
      {:ok, json} ->
        crypto_module = crypto_module()
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        {ciphertext, iv, tag} = apply(crypto_module, :encrypt, [json, key])

        {:ok,
         %{
           ciphertext: ciphertext,
           iv: iv,
           tag: tag,
           key_version: key_version
         }}

      {:error, reason} ->
        {:error, {:json_encode_failed, reason}}
    end
  end

  defp generate_channel_id do
    Identifiers.generate_id("chan_")
  end

  defp crypto_module do
    Application.get_env(:arbor_signals, :crypto_module, Arbor.Security.Crypto)
  end

  defp identity_registry_module do
    Application.get_env(:arbor_signals, :identity_registry_module, Arbor.Security.Identity.Registry)
  end
end
