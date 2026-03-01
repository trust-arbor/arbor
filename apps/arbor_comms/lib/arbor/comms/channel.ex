defmodule Arbor.Comms.Channel do
  @moduledoc """
  Pure message container GenServer for channel-based communication.

  A Channel is a "dumb container" — it stores messages, persists them,
  broadcasts to subscribers, and enforces rate limits. Zero orchestration.
  Agents see channel messages via heartbeat integration (Phase 2).

  ## Usage

      {:ok, pid} = Channel.start_link(channel_id: "chan_abc123", name: "brainstorm", type: :group)
      Channel.send_message(pid, "human_1", "User", :human, "Hello!")
      Channel.get_history(pid)
  """

  use GenServer

  require Logger

  @default_rate_limit_ms 2000
  @default_max_history 200

  # ── Types ──────────────────────────────────────────────────────────

  @type member_info :: %{
          id: String.t(),
          name: String.t(),
          type: :human | :agent | :system,
          joined_at: DateTime.t()
        }

  @type channel_type :: :public | :private | :dm | :ops_room | :group

  @type message :: %{
          id: String.t(),
          channel_id: String.t(),
          sender_id: String.t(),
          sender_name: String.t(),
          sender_type: :human | :agent | :system,
          content: String.t(),
          timestamp: DateTime.t(),
          metadata: map(),
          signature: binary() | nil,
          signed: boolean()
        }

  # ── Client API ─────────────────────────────────────────────────────

  @doc """
  Start a Channel GenServer.

  ## Options

  - `:channel_id` — unique identifier (auto-generated if not provided)
  - `:name` — display name (required)
  - `:type` — channel type atom (default: `:group`)
  - `:owner_id` — creator ID
  - `:members` — list of `%{id, name, type}` maps
  - `:rate_limit_ms` — rate limit cooldown (default: #{@default_rate_limit_ms}ms)
  - `:max_history` — max in-memory messages (default: #{@default_max_history})
  """
  def start_link(opts) do
    channel_id = Keyword.get(opts, :channel_id, generate_id())
    name = {:via, Registry, {Arbor.Comms.ChannelRegistry, channel_id}}
    GenServer.start_link(__MODULE__, Keyword.put(opts, :channel_id, channel_id), name: name)
  end

  @doc """
  Send a message to the channel. Synchronous — returns `{:ok, message}` or `{:error, reason}`.

  Validates membership, checks rate limit, persists, broadcasts via PubSub, emits signal.
  """
  @spec send_message(GenServer.server(), String.t(), String.t(), atom(), String.t(), map()) ::
          {:ok, message()} | {:error, atom()}
  def send_message(server, sender_id, sender_name, sender_type, content, metadata \\ %{}) do
    GenServer.call(
      server,
      {:send_message, sender_id, sender_name, sender_type, content, metadata}
    )
  end

  @doc "Add a member to the channel."
  @spec add_member(GenServer.server(), map()) :: :ok | {:error, atom()}
  def add_member(server, member) do
    GenServer.call(server, {:add_member, member})
  end

  @doc "Remove a member from the channel."
  @spec remove_member(GenServer.server(), String.t()) :: :ok | {:error, atom()}
  def remove_member(server, member_id) do
    GenServer.call(server, {:remove_member, member_id})
  end

  @doc "Get the current member list."
  @spec get_members(GenServer.server()) :: [member_info()]
  def get_members(server) do
    GenServer.call(server, :get_members)
  end

  @doc "Get recent message history from in-memory buffer."
  @spec get_history(GenServer.server(), keyword()) :: [message()]
  def get_history(server, opts \\ []) do
    GenServer.call(server, {:get_history, opts})
  end

  @doc "Get channel metadata."
  @spec channel_info(GenServer.server()) :: map()
  def channel_info(server) do
    GenServer.call(server, :channel_info)
  end

  # ── Server Callbacks ───────────────────────────────────────────────

  @impl true
  def init(opts) do
    channel_id = Keyword.fetch!(opts, :channel_id)
    name = Keyword.get(opts, :name, "Unnamed Channel")
    type = Keyword.get(opts, :type, :group)
    owner_id = Keyword.get(opts, :owner_id)
    raw_members = Keyword.get(opts, :members, [])
    rate_limit_ms = Keyword.get(opts, :rate_limit_ms, @default_rate_limit_ms)
    max_history = Keyword.get(opts, :max_history, @default_max_history)

    # Normalize members with joined_at timestamps
    now = DateTime.utc_now()

    members =
      raw_members
      |> Enum.map(fn m ->
        member = %{
          id: m[:id] || m["id"],
          name: m[:name] || m["name"],
          type: normalize_type(m[:type] || m["type"]),
          joined_at: m[:joined_at] || now
        }

        {member.id, member}
      end)
      |> Map.new()

    # Generate encryption key for private channels
    encryption_key = if type == :private, do: :crypto.strong_rand_bytes(32), else: nil

    state = %{
      channel_id: channel_id,
      name: name,
      type: type,
      owner_id: owner_id,
      members: members,
      messages: [],
      rate_limits: %{},
      rate_limit_ms: rate_limit_ms,
      max_history: max_history,
      pubsub_topic: "channel:#{channel_id}",
      encryption_key: encryption_key
    }

    # Ensure channel exists in Postgres (async, non-blocking)
    ensure_persisted(state)

    # Emit creation signal
    emit_signal(:channel_created, %{
      channel_id: channel_id,
      name: name,
      type: type,
      owner_id: owner_id
    })

    {:ok, state}
  end

  @impl true
  def handle_call(
        {:send_message, sender_id, sender_name, sender_type, content, metadata},
        _from,
        state
      ) do
    with :ok <- check_membership(sender_id, state),
         :ok <- check_rate_limit(sender_id, state) do
      # Extract signature from metadata (placed there by Channel.Send action)
      {signature, clean_metadata} = Map.pop(metadata, :signature)

      message = %{
        id: generate_message_id(),
        channel_id: state.channel_id,
        sender_id: sender_id,
        sender_name: sender_name,
        sender_type: sender_type,
        content: content,
        timestamp: DateTime.utc_now(),
        metadata: clean_metadata,
        signature: signature,
        signed: signature != nil
      }

      # Optionally verify signature if Identity Registry is available
      message = maybe_verify_signature(message)

      # Update in-memory state
      messages = [message | state.messages] |> Enum.take(state.max_history)
      rate_limits = Map.put(state.rate_limits, sender_id, System.monotonic_time(:millisecond))
      new_state = %{state | messages: messages, rate_limits: rate_limits}

      # Persist async — encrypt content for private channels
      persist_message(state.channel_id, message, state.encryption_key)

      # Broadcast to PubSub subscribers (plaintext — within process trust boundary)
      broadcast(state, {:channel_message, message})

      # Emit signal (state changes only)
      emit_signal(:channel_message_sent, %{
        channel_id: state.channel_id,
        sender_id: sender_id,
        sender_name: sender_name,
        message_id: message.id
      })

      {:reply, {:ok, message}, new_state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:add_member, member_attrs}, _from, state) do
    member_id = member_attrs[:id] || member_attrs["id"]

    if Map.has_key?(state.members, member_id) do
      {:reply, {:error, :already_member}, state}
    else
      member = %{
        id: member_id,
        name: member_attrs[:name] || member_attrs["name"],
        type: normalize_type(member_attrs[:type] || member_attrs["type"]),
        joined_at: DateTime.utc_now()
      }

      new_state = %{state | members: Map.put(state.members, member_id, member)}

      # Distribute sealed encryption key for private channels
      maybe_distribute_channel_key(state, member_id)

      # Persist member change
      persist_member_add(state.channel_id, member)

      # Broadcast join
      broadcast(state, {:channel_member_joined, member})

      emit_signal(:channel_member_joined, %{
        channel_id: state.channel_id,
        member_id: member_id,
        member_name: member.name
      })

      {:reply, :ok, new_state}
    end
  end

  def handle_call({:remove_member, member_id}, _from, state) do
    if Map.has_key?(state.members, member_id) do
      new_members = Map.delete(state.members, member_id)
      new_state = %{state | members: new_members}

      # Rotate encryption key for private channels (forward secrecy)
      new_state = maybe_rotate_encryption_key(new_state, member_id)

      persist_member_remove(state.channel_id, member_id)

      broadcast(state, {:channel_member_left, member_id})

      emit_signal(:channel_member_left, %{
        channel_id: state.channel_id,
        member_id: member_id
      })

      {:reply, :ok, new_state}
    else
      {:reply, {:error, :not_member}, state}
    end
  end

  def handle_call(:get_members, _from, state) do
    {:reply, Map.values(state.members), state}
  end

  def handle_call({:get_history, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 50)
    # Messages stored newest-first; return oldest-first for display
    history = state.messages |> Enum.take(limit) |> Enum.reverse()
    {:reply, history, state}
  end

  def handle_call(:channel_info, _from, state) do
    info = %{
      channel_id: state.channel_id,
      name: state.name,
      type: state.type,
      owner_id: state.owner_id,
      member_count: map_size(state.members),
      message_count: length(state.messages),
      pubsub_topic: state.pubsub_topic,
      encrypted: state.encryption_key != nil,
      encryption_type: encryption_type(state)
    }

    {:reply, info, state}
  end

  # ── Signature Verification ─────────────────────────────────────────

  @doc """
  Verify a message's signature against the sender's registered public key.

  Returns:
  - `true` — signature present and valid
  - `false` — signature present but invalid (tampered)
  - `nil` — no signature or no public key available
  """
  @spec verify_message_signature(message()) :: boolean() | nil
  def verify_message_signature(%{signature: nil}), do: nil

  def verify_message_signature(%{signature: signature, sender_id: sender_id, content: content})
      when is_binary(signature) do
    with {:ok, public_key} <- lookup_identity_public_key(sender_id) do
      crypto_verify(content, signature, public_key)
    else
      _ -> nil
    end
  end

  def verify_message_signature(_), do: nil

  # ── Private Helpers ────────────────────────────────────────────────

  defp check_membership(sender_id, state) do
    if Map.has_key?(state.members, sender_id) do
      :ok
    else
      {:error, :not_member}
    end
  end

  defp check_rate_limit(sender_id, state) do
    case Map.get(state.rate_limits, sender_id) do
      nil ->
        :ok

      last_send ->
        now = System.monotonic_time(:millisecond)

        if now - last_send >= state.rate_limit_ms do
          :ok
        else
          {:error, :rate_limited}
        end
    end
  end

  defp broadcast(state, message) do
    pubsub = get_pubsub_module()

    if pubsub do
      try do
        Phoenix.PubSub.broadcast(pubsub, state.pubsub_topic, message)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end
  end

  defp get_pubsub_module do
    cond do
      Process.whereis(Arbor.Dashboard.PubSub) -> Arbor.Dashboard.PubSub
      Process.whereis(Arbor.Web.PubSub) -> Arbor.Web.PubSub
      true -> nil
    end
  end

  defp emit_signal(type, data) do
    if Code.ensure_loaded?(Arbor.Signals) and
         function_exported?(Arbor.Signals, :emit, 3) do
      try do
        apply(Arbor.Signals, :emit, [:comms, type, data])
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end
  end

  defp ensure_persisted(state) do
    Task.start(fn ->
      if channel_store_available?() do
        type_str = Atom.to_string(state.type)

        members_list =
          state.members
          |> Map.values()
          |> Enum.map(fn m ->
            %{
              "id" => m.id,
              "name" => m.name,
              "type" => Atom.to_string(m.type)
            }
          end)

        apply(Arbor.Persistence.ChannelStore, :ensure_channel, [
          state.channel_id,
          [
            type: type_str,
            name: state.name,
            owner_id: state.owner_id,
            members: members_list
          ]
        ])
      end
    end)
  end

  defp persist_message(channel_id, message, encryption_key) do
    # Encrypt content for private channels before persistence
    # JSON-encode encrypted maps so they fit the text column in Postgres
    persisted_content =
      case encrypt_content(message.content, encryption_key) do
        %{} = map -> Jason.encode!(map)
        plain -> plain
      end

    persisted_metadata =
      if encryption_key do
        Map.put(message.metadata, :encrypted, true)
      else
        message.metadata
      end

    Task.start(fn ->
      if channel_store_available?() do
        apply(Arbor.Persistence.ChannelStore, :append_message, [
          channel_id,
          %{
            sender_id: message.sender_id,
            sender_name: message.sender_name,
            sender_type: Atom.to_string(message.sender_type),
            content: persisted_content,
            timestamp: message.timestamp,
            metadata: persisted_metadata
          }
        ])
      end
    end)
  end

  defp persist_member_add(channel_id, member) do
    Task.start(fn ->
      if channel_store_available?() do
        apply(Arbor.Persistence.ChannelStore, :add_member, [
          channel_id,
          %{
            "id" => member.id,
            "name" => member.name,
            "type" => Atom.to_string(member.type)
          }
        ])
      end
    end)
  end

  defp persist_member_remove(channel_id, member_id) do
    Task.start(fn ->
      if channel_store_available?() do
        apply(Arbor.Persistence.ChannelStore, :remove_member, [channel_id, member_id])
      end
    end)
  end

  defp channel_store_available? do
    Code.ensure_loaded?(Arbor.Persistence.ChannelStore) and
      apply(Arbor.Persistence.ChannelStore, :available?, [])
  end

  defp normalize_type(type) when is_atom(type), do: type
  defp normalize_type("human"), do: :human
  defp normalize_type("agent"), do: :agent
  defp normalize_type("system"), do: :system
  defp normalize_type(_), do: :system

  # ── Encryption Helpers ──────────────────────────────────────────────

  defp encryption_type(%{type: :private, encryption_key: key}) when key != nil, do: :aes_256_gcm
  defp encryption_type(%{type: :dm}), do: :double_ratchet
  defp encryption_type(_), do: nil

  defp maybe_distribute_channel_key(%{encryption_key: nil}, _member_id), do: :ok

  defp maybe_distribute_channel_key(
         %{encryption_key: key, channel_id: channel_id} = state,
         member_id
       ) do
    # Seal the symmetric key for the new member via ECDH
    registry = Arbor.Security.Identity.Registry
    crypto = Arbor.Security.Crypto

    with true <- Code.ensure_loaded?(registry) and Process.whereis(registry) != nil,
         true <- Code.ensure_loaded?(crypto),
         {:ok, member_enc_pub} <- apply(registry, :lookup_encryption_key, [member_id]) do
      # We need the channel owner's encryption private key for ECDH seal.
      # Use a channel-specific ephemeral keypair derived from the encryption key instead.
      {ephemeral_pub, ephemeral_priv} = apply(crypto, :generate_encryption_keypair, [])
      sealed = apply(crypto, :seal, [key, member_enc_pub, ephemeral_priv])
      sealed = Map.put(sealed, :ephemeral_public, ephemeral_pub)

      # Store sealed key for channel restore
      Arbor.Comms.ChannelKeyStore.put(channel_id, member_id, sealed)

      emit_signal(:channel_key_distributed, %{
        channel_id: channel_id,
        member_id: member_id
      })
    else
      _ ->
        # Member has no encryption key registered — they can still participate
        # but won't have a sealed key copy for offline restore
        Logger.debug("No encryption key for member #{member_id} in channel #{state.channel_id}")
    end

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp maybe_rotate_encryption_key(%{encryption_key: nil} = state, _removed_member_id), do: state

  defp maybe_rotate_encryption_key(%{encryption_key: _old_key} = state, removed_member_id) do
    # Generate new encryption key
    new_key = :crypto.strong_rand_bytes(32)
    new_state = %{state | encryption_key: new_key}

    # Remove old sealed key for departed member
    Arbor.Comms.ChannelKeyStore.delete(state.channel_id, removed_member_id)

    # Re-seal for all remaining members
    Enum.each(state.members, fn {member_id, _member} ->
      maybe_distribute_channel_key(new_state, member_id)
    end)

    emit_signal(:channel_key_rotated, %{
      channel_id: state.channel_id,
      removed_member_id: removed_member_id,
      remaining_members: Map.keys(state.members)
    })

    new_state
  end

  defp encrypt_content(content, nil), do: content

  defp encrypt_content(content, encryption_key) do
    crypto = Arbor.Security.Crypto

    if Code.ensure_loaded?(crypto) do
      {ciphertext, iv, tag} = apply(crypto, :encrypt, [content, encryption_key])

      %{
        "__encrypted__" => true,
        "ciphertext" => Base.encode64(ciphertext),
        "iv" => Base.encode64(iv),
        "tag" => Base.encode64(tag)
      }
    else
      content
    end
  rescue
    _ -> content
  catch
    :exit, _ -> content
  end

  @doc false
  def decrypt_content(content, nil), do: content

  def decrypt_content(json, encryption_key) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{"__encrypted__" => true} = encrypted} ->
        decrypt_content(encrypted, encryption_key)

      _ ->
        json
    end
  end

  def decrypt_content(%{"__encrypted__" => true} = encrypted, encryption_key) do
    crypto = Arbor.Security.Crypto

    with true <- Code.ensure_loaded?(crypto),
         {:ok, ciphertext} <- Base.decode64(encrypted["ciphertext"]),
         {:ok, iv} <- Base.decode64(encrypted["iv"]),
         {:ok, tag} <- Base.decode64(encrypted["tag"]),
         {:ok, plaintext} <- apply(crypto, :decrypt, [ciphertext, encryption_key, iv, tag]) do
      plaintext
    else
      _ ->
        Logger.warning("Failed to decrypt channel message content")
        "[encrypted]"
    end
  rescue
    _ -> "[encrypted]"
  catch
    :exit, _ -> "[encrypted]"
  end

  def decrypt_content(content, _key), do: content

  # ── Signature Helpers ──────────────────────────────────────────────

  defp maybe_verify_signature(%{signature: nil} = message), do: message

  defp maybe_verify_signature(%{signature: _sig} = message) do
    # Verification is informational — log warnings but never reject messages
    case verify_message_signature(message) do
      false ->
        Logger.warning(
          "Channel message #{message.id} from #{message.sender_id} has invalid signature"
        )

        message

      _ ->
        message
    end
  end

  defp lookup_identity_public_key(agent_id) do
    registry = Arbor.Security.Identity.Registry

    if Code.ensure_loaded?(registry) and Process.whereis(registry) do
      try do
        apply(registry, :lookup, [agent_id])
      rescue
        _ -> {:error, :registry_unavailable}
      catch
        :exit, _ -> {:error, :registry_unavailable}
      end
    else
      {:error, :registry_unavailable}
    end
  end

  defp crypto_verify(message, signature, public_key) do
    crypto = Arbor.Security.Crypto

    if Code.ensure_loaded?(crypto) do
      try do
        apply(crypto, :verify, [message, signature, public_key])
      rescue
        _ -> nil
      catch
        :exit, _ -> nil
      end
    else
      nil
    end
  end

  defp generate_id do
    suffix = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    "chan_#{suffix}"
  end

  defp generate_message_id do
    suffix = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    "msg_#{suffix}"
  end
end
