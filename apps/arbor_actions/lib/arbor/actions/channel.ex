defmodule Arbor.Actions.Channel do
  @moduledoc """
  Channel actions for internal Arbor channel communication.

  These actions allow agents to interact with unified channels (group, dm,
  public, ops_room) managed by `Arbor.Comms`. Unlike `Arbor.Actions.Comms`
  which bridges external services (Signal, Email), these operate on internal
  channels.

  All calls go through a runtime bridge (`Code.ensure_loaded?` + `apply/3`)
  so that `arbor_actions` has no compile-time dependency on `arbor_comms`.
  """

  @comms_module Arbor.Comms

  defp comms_available? do
    Code.ensure_loaded?(@comms_module)
  end

  @doc false
  def call_comms(fun, args) do
    if comms_available?() do
      apply(@comms_module, fun, args)
    else
      {:error, :comms_unavailable}
    end
  end

  # ============================================================================
  # Channel.List
  # ============================================================================

  defmodule List do
    @moduledoc """
    List active channels with their metadata.

    Returns channel IDs, names, types, member counts, and encryption info.
    Supports filtering by type, name, owner, and member.
    """

    use Jido.Action,
      name: "channel_list",
      description: "List active internal channels with optional filters",
      category: "channel",
      tags: ["channel", "list", "discovery"],
      schema: [
        type: [
          type: :string,
          doc: "Filter by type (group, dm, public, private, ops_room)"
        ],
        name: [
          type: :string,
          doc: "Filter by name substring (case-insensitive)"
        ],
        owner_id: [
          type: :string,
          doc: "Filter by owner agent ID"
        ],
        member_id: [
          type: :string,
          doc: "Filter by member agent ID"
        ],
        limit: [
          type: :integer,
          default: 50,
          doc: "Maximum number of channels to return"
        ]
      ]

    alias Arbor.Actions

    def taint_roles do
      %{type: :data, name: :data, owner_id: :data, member_id: :data, limit: :data}
    end

    @impl true
    def run(params, _context) do
      Actions.emit_started(__MODULE__, params)

      has_filters? = params[:name] || params[:owner_id] || params[:member_id]

      channel_infos =
        if has_filters? do
          search_with_filters(params)
        else
          list_and_enrich(params)
        end

      result = %{channels: channel_infos}
      Actions.emit_completed(__MODULE__, result)
      {:ok, result}
    rescue
      _ ->
        Actions.emit_failed(__MODULE__, :unexpected_error)
        {:ok, %{channels: []}}
    catch
      :exit, _ ->
        Actions.emit_failed(__MODULE__, :comms_unavailable)
        {:ok, %{channels: []}}
    end

    defp search_with_filters(params) do
      opts =
        []
        |> maybe_add(:name, params[:name])
        |> maybe_add(:type, params[:type])
        |> maybe_add(:owner_id, params[:owner_id])
        |> maybe_add(:member_id, params[:member_id])
        |> maybe_add(:limit, params[:limit])

      case Arbor.Actions.Channel.call_comms(:search_channels, [opts]) do
        {:error, _} -> []
        results when is_list(results) -> Enum.map(results, &normalize_info/1)
      end
    end

    defp list_and_enrich(params) do
      case Arbor.Actions.Channel.call_comms(:list_channels, []) do
        {:error, _} ->
          []

        channels when is_list(channels) ->
          channels
          |> Enum.map(fn {channel_id, _pid} ->
            case Arbor.Actions.Channel.call_comms(:get_channel_info, [channel_id]) do
              {:ok, info} -> normalize_info(Map.put(info, :channel_id, channel_id))
              _ -> nil
            end
          end)
          |> Enum.reject(&is_nil/1)
          |> maybe_filter_type(params[:type])
          |> Enum.take(params[:limit] || 50)
      end
    end

    defp normalize_info(info) do
      %{
        channel_id: Map.get(info, :channel_id),
        name: Map.get(info, :name, "unnamed"),
        type: Map.get(info, :type, :group),
        owner_id: Map.get(info, :owner_id),
        member_count: Map.get(info, :member_count, 0),
        message_count: Map.get(info, :message_count, 0),
        encrypted: Map.get(info, :encrypted, false),
        encryption_type: Map.get(info, :encryption_type)
      }
    end

    defp maybe_add(opts, _key, nil), do: opts
    defp maybe_add(opts, key, value), do: [{key, value} | opts]

    defp maybe_filter_type(channels, nil), do: channels

    defp maybe_filter_type(channels, type_str) when is_binary(type_str) do
      type_atom = String.to_existing_atom(type_str)
      Enum.filter(channels, &(&1.type == type_atom))
    rescue
      ArgumentError -> channels
    end
  end

  # ============================================================================
  # Channel.Read
  # ============================================================================

  defmodule Read do
    @moduledoc """
    Read message history from a channel.

    Returns messages oldest-first with sender info and timestamps.
    """

    use Jido.Action,
      name: "channel_read",
      description: "Read message history from an internal channel",
      category: "channel",
      tags: ["channel", "read", "history"],
      schema: [
        channel_id: [
          type: :string,
          required: true,
          doc: "Channel ID to read from"
        ],
        limit: [
          type: :integer,
          default: 20,
          doc: "Maximum number of messages to return"
        ]
      ]

    alias Arbor.Actions

    def taint_roles do
      %{channel_id: :control, limit: :data}
    end

    @impl true
    def run(params, context) do
      Actions.emit_started(__MODULE__, params)
      channel_id = params.channel_id
      limit = params[:limit] || 20
      reader_id = Map.get(context, :agent_id)

      case Arbor.Actions.Channel.call_comms(:channel_history, [channel_id, [limit: limit]]) do
        {:error, :comms_unavailable} = err ->
          Actions.emit_failed(__MODULE__, :comms_unavailable)
          err

        {:error, :not_found} ->
          Actions.emit_failed(__MODULE__, :not_found)
          {:error, :not_found}

        {:ok, messages} when is_list(messages) ->
          formatted =
            Enum.map(messages, fn msg ->
              content = Map.get(msg, :content, "")

              # Attempt DM decryption if content is DM-encrypted
              content = maybe_dm_decrypt(content, reader_id)

              %{
                sender_name: Map.get(msg, :sender_name, "unknown"),
                sender_type: Map.get(msg, :sender_type, :unknown),
                content: content,
                timestamp: Map.get(msg, :timestamp) |> format_timestamp(),
                signed: Map.get(msg, :signed, false),
                verified: verify_message(msg)
              }
            end)

          result = %{channel_id: channel_id, messages: formatted, count: length(formatted)}
          Actions.emit_completed(__MODULE__, result)
          {:ok, result}
      end
    end

    defp verify_message(%{signature: nil}), do: nil
    defp verify_message(%{signed: false}), do: nil

    defp verify_message(msg) do
      channel_mod = Arbor.Comms.Channel

      if Code.ensure_loaded?(channel_mod) and
           function_exported?(channel_mod, :verify_message_signature, 1) do
        try do
          apply(channel_mod, :verify_message_signature, [msg])
        rescue
          _ -> nil
        catch
          :exit, _ -> nil
        end
      else
        nil
      end
    end

    defp maybe_dm_decrypt(content, nil), do: content

    defp maybe_dm_decrypt(content, reader_id) when is_binary(content) do
      case Jason.decode(content) do
        {:ok, %{"__dm_encrypted__" => true, "sender_id" => sender_id, "sealed" => sealed_data}} ->
          decrypt_dm_message(reader_id, sender_id, sealed_data)

        _ ->
          content
      end
    rescue
      _ -> content
    end

    defp maybe_dm_decrypt(content, _reader_id), do: content

    defp decrypt_dm_message(reader_id, sender_id, sealed_data) do
      keychain_mod = Arbor.Security.Keychain

      with true <- Code.ensure_loaded?(keychain_mod),
           {:ok, keychain} <- get_reader_keychain(reader_id),
           sealed <- deserialize_sealed(sealed_data) do
        case apply(keychain_mod, :unseal_from_peer, [keychain, sender_id, sealed]) do
          {:ok, plaintext, updated_keychain} ->
            # Ratchet decryption — persist updated keychain
            Process.put({:dm_keychain, reader_id}, updated_keychain)
            plaintext

          {:ok, plaintext} ->
            plaintext

          {:error, _reason} ->
            "[encrypted — cannot decrypt]"
        end
      else
        _ -> "[encrypted — no keychain]"
      end
    rescue
      _ -> "[encrypted — error]"
    catch
      :exit, _ -> "[encrypted — error]"
    end

    defp get_reader_keychain(reader_id) do
      cache_key = {:dm_keychain, reader_id}

      case Process.get(cache_key) do
        nil ->
          keychain_mod = Arbor.Security.Keychain
          signing_key_store = Arbor.Security.SigningKeyStore

          with true <- Code.ensure_loaded?(signing_key_store),
               true <- Code.ensure_loaded?(keychain_mod),
               {:ok, keypair} <- apply(signing_key_store, :get_keypair, [reader_id]) do
            signing_priv = keypair.signing
            enc_priv = Map.get(keypair, :encryption)

            if enc_priv do
              crypto = Arbor.Security.Crypto
              {sign_pub, _} = apply(crypto, :generate_keypair, [])
              {enc_pub, _} = :crypto.generate_key(:ecdh, :x25519, enc_priv)

              keychain =
                apply(keychain_mod, :from_keypairs, [
                  reader_id,
                  {sign_pub, signing_priv},
                  {enc_pub, enc_priv}
                ])

              Process.put(cache_key, keychain)
              {:ok, keychain}
            else
              {:error, :no_encryption_key}
            end
          end

        keychain ->
          {:ok, keychain}
      end
    rescue
      _ -> {:error, :keychain_unavailable}
    catch
      :exit, _ -> {:error, :keychain_unavailable}
    end

    defp deserialize_sealed(%{"type" => "ratchet"} = data) do
      {:ok, header_bin} = Base.decode64(data["header"])
      {:ok, ciphertext} = Base.decode64(data["ciphertext"])

      %{
        __ratchet__: true,
        header: :erlang.binary_to_term(header_bin, [:safe]),
        ciphertext: ciphertext
      }
    end

    defp deserialize_sealed(%{"type" => "ecdh"} = data) do
      {:ok, ciphertext} = Base.decode64(data["ciphertext"])
      {:ok, iv} = Base.decode64(data["iv"])
      {:ok, tag} = Base.decode64(data["tag"])
      {:ok, sender_public} = Base.decode64(data["sender_public"])

      %{
        ciphertext: ciphertext,
        iv: iv,
        tag: tag,
        sender_public: sender_public
      }
    end

    defp format_timestamp(nil), do: nil
    defp format_timestamp(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
    defp format_timestamp(other), do: to_string(other)
  end

  # ============================================================================
  # Channel.Send
  # ============================================================================

  defmodule Send do
    @moduledoc """
    Send a message to an internal channel.

    Extracts sender identity from the execution context (`agent_id`, `agent_name`).
    """

    use Jido.Action,
      name: "channel_send",
      description: "Send a message to an internal channel",
      category: "channel",
      tags: ["channel", "send", "messaging"],
      schema: [
        channel_id: [
          type: :string,
          required: true,
          doc: "Channel ID to send to"
        ],
        content: [
          type: :string,
          required: true,
          doc: "Message content"
        ],
        metadata: [
          type: :map,
          default: %{},
          doc: "Optional message metadata"
        ]
      ]

    alias Arbor.Actions

    def taint_roles do
      %{channel_id: :control, content: :data, metadata: :data}
    end

    @impl true
    def run(params, context) do
      Actions.emit_started(__MODULE__, params)

      channel_id = params.channel_id
      content = params.content
      metadata = params[:metadata] || %{}
      sender_id = Map.get(context, :agent_id, "unknown")
      sender_name = Map.get(context, :agent_name, "Agent")
      sender_type = :agent

      # Sign the message content if a signing key is available
      metadata = maybe_sign_content(sender_id, content, metadata)

      # For DM channels, encrypt content with Double Ratchet before sending
      {send_content, metadata} = maybe_dm_encrypt(channel_id, sender_id, content, metadata)

      case Arbor.Actions.Channel.call_comms(:send_to_channel, [
             channel_id,
             sender_id,
             sender_name,
             sender_type,
             send_content,
             metadata
           ]) do
        {:error, :comms_unavailable} = err ->
          Actions.emit_failed(__MODULE__, :comms_unavailable)
          err

        {:error, :not_found} ->
          Actions.emit_failed(__MODULE__, :not_found)
          {:error, :not_found}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, reason}

        {:ok, message} ->
          result = %{
            channel_id: channel_id,
            message_id: Map.get(message, :id, "unknown"),
            status: :sent,
            signed: Map.get(message, :signed, false)
          }

          Actions.emit_completed(__MODULE__, result)
          {:ok, result}
      end
    end

    defp maybe_sign_content(sender_id, content, metadata) do
      signing_key_store = Arbor.Security.SigningKeyStore
      crypto = Arbor.Security.Crypto

      with true <- Code.ensure_loaded?(signing_key_store),
           true <- Code.ensure_loaded?(crypto),
           {:ok, private_key} <- apply(signing_key_store, :get, [sender_id]) do
        signature = apply(crypto, :sign, [content, private_key])
        Map.put(metadata, :signature, signature)
      else
        _ -> metadata
      end
    rescue
      _ -> metadata
    catch
      :exit, _ -> metadata
    end

    defp maybe_dm_encrypt(channel_id, sender_id, content, metadata) do
      # Check if this is a DM channel
      case Arbor.Actions.Channel.call_comms(:get_channel_info, [channel_id]) do
        {:ok, %{type: :dm}} ->
          dm_encrypt(channel_id, sender_id, content, metadata)

        _ ->
          {content, metadata}
      end
    rescue
      _ -> {content, metadata}
    catch
      :exit, _ -> {content, metadata}
    end

    defp dm_encrypt(channel_id, sender_id, content, metadata) do
      keychain_mod = Arbor.Security.Keychain

      with true <- Code.ensure_loaded?(keychain_mod),
           {:ok, keychain} <- get_agent_keychain(sender_id),
           {:ok, peer_id} <- find_dm_peer(channel_id, sender_id) do
        case apply(keychain_mod, :seal_for_peer, [keychain, peer_id, content]) do
          {:ok, sealed, updated_keychain} ->
            # Ratchet-encrypted — persist updated keychain
            persist_agent_keychain(sender_id, updated_keychain)

            encrypted_content =
              Jason.encode!(%{
                "__dm_encrypted__" => true,
                "sender_id" => sender_id,
                "sealed" => serialize_sealed(sealed)
              })

            {encrypted_content, Map.put(metadata, :dm_encrypted, true)}

          {:ok, sealed} ->
            # One-shot ECDH
            encrypted_content =
              Jason.encode!(%{
                "__dm_encrypted__" => true,
                "sender_id" => sender_id,
                "sealed" => serialize_sealed(sealed)
              })

            {encrypted_content, Map.put(metadata, :dm_encrypted, true)}

          {:error, _reason} ->
            # Can't encrypt — send plaintext
            {content, metadata}
        end
      else
        _ -> {content, metadata}
      end
    rescue
      _ -> {content, metadata}
    catch
      :exit, _ -> {content, metadata}
    end

    defp serialize_sealed(%{__ratchet__: true} = sealed) do
      %{
        "type" => "ratchet",
        "header" => Base.encode64(:erlang.term_to_binary(sealed.header)),
        "ciphertext" => Base.encode64(sealed.ciphertext)
      }
    end

    defp serialize_sealed(sealed) do
      %{
        "type" => "ecdh",
        "ciphertext" => Base.encode64(sealed.ciphertext),
        "iv" => Base.encode64(sealed.iv),
        "tag" => Base.encode64(sealed.tag),
        "sender_public" => Base.encode64(sealed.sender_public)
      }
    end

    # Keychain management — these use a process dictionary cache or ETS for the session
    defp get_agent_keychain(agent_id) do
      keychain_mod = Arbor.Security.Keychain

      # Check if agent has a keychain in the process cache
      cache_key = {:dm_keychain, agent_id}

      case Process.get(cache_key) do
        nil ->
          # Create a new keychain from the agent's existing keys
          signing_key_store = Arbor.Security.SigningKeyStore

          with true <- Code.ensure_loaded?(signing_key_store),
               {:ok, keypair} <- apply(signing_key_store, :get_keypair, [agent_id]) do
            signing_priv = keypair.signing
            enc_priv = Map.get(keypair, :encryption)

            if enc_priv do
              crypto = Arbor.Security.Crypto
              {sign_pub, _} = apply(crypto, :generate_keypair, [])
              {enc_pub, _} = :crypto.generate_key(:ecdh, :x25519, enc_priv)

              keychain =
                apply(keychain_mod, :from_keypairs, [
                  agent_id,
                  {sign_pub, signing_priv},
                  {enc_pub, enc_priv}
                ])

              Process.put(cache_key, keychain)
              {:ok, keychain}
            else
              {:error, :no_encryption_key}
            end
          end

        keychain ->
          {:ok, keychain}
      end
    rescue
      _ -> {:error, :keychain_unavailable}
    catch
      :exit, _ -> {:error, :keychain_unavailable}
    end

    defp persist_agent_keychain(agent_id, keychain) do
      Process.put({:dm_keychain, agent_id}, keychain)
    end

    defp find_dm_peer(channel_id, sender_id) do
      case Arbor.Actions.Channel.call_comms(:channel_members, [channel_id]) do
        {:ok, members} ->
          case Enum.find(members, fn m -> m.id != sender_id end) do
            nil -> {:error, :no_peer}
            peer -> {:ok, peer.id}
          end

        _ ->
          {:error, :cannot_find_peer}
      end
    end
  end

  # ============================================================================
  # Channel.Join
  # ============================================================================

  defmodule Join do
    @moduledoc """
    Join an internal channel.

    Builds a member map from the execution context and adds the agent as a member.
    """

    use Jido.Action,
      name: "channel_join",
      description: "Join an internal channel",
      category: "channel",
      tags: ["channel", "join", "membership"],
      schema: [
        channel_id: [
          type: :string,
          required: true,
          doc: "Channel ID to join"
        ]
      ]

    alias Arbor.Actions

    def taint_roles do
      %{channel_id: :control}
    end

    @impl true
    def run(params, context) do
      Actions.emit_started(__MODULE__, params)

      channel_id = params.channel_id
      agent_id = Map.get(context, :agent_id, "unknown")
      agent_name = Map.get(context, :agent_name, "Agent")

      member = %{id: agent_id, name: agent_name, type: :agent}

      case Arbor.Actions.Channel.call_comms(:join_channel, [channel_id, member]) do
        {:error, :comms_unavailable} = err ->
          Actions.emit_failed(__MODULE__, :comms_unavailable)
          err

        {:error, :not_found} ->
          Actions.emit_failed(__MODULE__, :not_found)
          {:error, :not_found}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, reason}

        :ok ->
          result = %{channel_id: channel_id, status: :joined}
          Actions.emit_completed(__MODULE__, result)
          {:ok, result}
      end
    end
  end

  # ============================================================================
  # Channel.Create
  # ============================================================================

  defmodule Create do
    @moduledoc """
    Create a new internal channel.

    The calling agent becomes the owner and first member automatically.
    """

    use Jido.Action,
      name: "channel_create",
      description: "Create a new internal channel",
      category: "channel",
      tags: ["channel", "create", "management"],
      schema: [
        name: [
          type: :string,
          required: true,
          doc: "Display name for the channel"
        ],
        type: [
          type: :string,
          default: "group",
          doc: "Channel type (group, public, private, ops_room)"
        ]
      ]

    alias Arbor.Actions

    def taint_roles do
      %{name: :data, type: :data}
    end

    @impl true
    def run(params, context) do
      Actions.emit_started(__MODULE__, params)

      name = params.name
      type = String.to_existing_atom(params[:type] || "group")
      owner_id = Map.get(context, :agent_id, "unknown")
      owner_name = Map.get(context, :agent_name, "Agent")

      opts = [
        type: type,
        owner_id: owner_id,
        members: [%{id: owner_id, name: owner_name, type: :agent}],
        rate_limit_ms: 2000
      ]

      case Arbor.Actions.Channel.call_comms(:create_channel, [name, opts]) do
        {:ok, channel_id} ->
          result = %{channel_id: channel_id, name: name, type: type, status: :created}
          Actions.emit_completed(__MODULE__, result)
          {:ok, result}

        {:error, :comms_unavailable} = err ->
          Actions.emit_failed(__MODULE__, :comms_unavailable)
          err

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, reason}
      end
    rescue
      ArgumentError ->
        Actions.emit_failed(__MODULE__, :invalid_type)
        {:error, :invalid_type}
    end
  end

  # ============================================================================
  # Channel.Members
  # ============================================================================

  defmodule Members do
    @moduledoc """
    List members of a channel.

    Returns member list with id, name, type, and joined_at timestamp.
    """

    use Jido.Action,
      name: "channel_members",
      description: "List members of an internal channel",
      category: "channel",
      tags: ["channel", "members", "discovery"],
      schema: [
        channel_id: [
          type: :string,
          required: true,
          doc: "Channel ID to list members for"
        ]
      ]

    alias Arbor.Actions

    def taint_roles do
      %{channel_id: :control}
    end

    @impl true
    def run(params, _context) do
      Actions.emit_started(__MODULE__, params)
      channel_id = params.channel_id

      case Arbor.Actions.Channel.call_comms(:channel_members, [channel_id]) do
        {:ok, members} when is_list(members) ->
          formatted =
            Enum.map(members, fn m ->
              %{
                id: m.id,
                name: m.name,
                type: m.type,
                joined_at: format_timestamp(m[:joined_at])
              }
            end)

          result = %{channel_id: channel_id, members: formatted, count: length(formatted)}
          Actions.emit_completed(__MODULE__, result)
          {:ok, result}

        {:error, :comms_unavailable} = err ->
          Actions.emit_failed(__MODULE__, :comms_unavailable)
          err

        {:error, :not_found} ->
          Actions.emit_failed(__MODULE__, :not_found)
          {:error, :not_found}
      end
    end

    defp format_timestamp(nil), do: nil
    defp format_timestamp(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
    defp format_timestamp(other), do: to_string(other)
  end

  # ============================================================================
  # Channel.Update
  # ============================================================================

  defmodule Update do
    @moduledoc """
    Update a channel's name or topic. Owner-only.

    Checks that the calling agent is the channel owner before applying changes.
    """

    use Jido.Action,
      name: "channel_update",
      description: "Update channel name or topic (owner only)",
      category: "channel",
      tags: ["channel", "update", "management"],
      schema: [
        channel_id: [
          type: :string,
          required: true,
          doc: "Channel ID to update"
        ],
        name: [
          type: :string,
          doc: "New display name"
        ],
        topic: [
          type: :string,
          doc: "New channel topic"
        ]
      ]

    alias Arbor.Actions

    def taint_roles do
      %{channel_id: :control, name: :data, topic: :data}
    end

    @impl true
    def run(params, context) do
      Actions.emit_started(__MODULE__, params)

      channel_id = params.channel_id
      agent_id = Map.get(context, :agent_id)

      with {:ok, info} <- Arbor.Actions.Channel.call_comms(:get_channel_info, [channel_id]),
           :ok <- check_owner(info, agent_id) do
        opts =
          []
          |> maybe_add(:name, params[:name])
          |> maybe_add(:topic, params[:topic])

        case Arbor.Actions.Channel.call_comms(:update_channel, [channel_id, opts]) do
          :ok ->
            result = %{channel_id: channel_id, status: :updated}
            Actions.emit_completed(__MODULE__, result)
            {:ok, result}

          {:error, reason} ->
            Actions.emit_failed(__MODULE__, reason)
            {:error, reason}
        end
      else
        {:error, :not_owner} ->
          Actions.emit_failed(__MODULE__, :not_owner)
          {:error, :not_owner}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, reason}
      end
    end

    defp check_owner(%{owner_id: owner_id}, agent_id) when owner_id == agent_id, do: :ok
    defp check_owner(_, _), do: {:error, :not_owner}

    defp maybe_add(opts, _key, nil), do: opts
    defp maybe_add(opts, key, value), do: [{key, value} | opts]
  end

  # ============================================================================
  # Channel.Invite
  # ============================================================================

  defmodule Invite do
    @moduledoc """
    Invite a member to a channel (owner-only).

    Adds the invitee as a member. For private channels, the existing ECDH key
    distribution in `Channel.add_member/2` handles encryption automatically.
    """

    use Jido.Action,
      name: "channel_invite",
      description: "Invite a member to a channel (owner only)",
      category: "channel",
      tags: ["channel", "invite", "management"],
      schema: [
        channel_id: [
          type: :string,
          required: true,
          doc: "Channel ID to invite to"
        ],
        invitee_id: [
          type: :string,
          required: true,
          doc: "Agent/user ID to invite"
        ],
        invitee_name: [
          type: :string,
          default: "Agent",
          doc: "Display name of the invitee"
        ],
        invitee_type: [
          type: :string,
          default: "agent",
          doc: "Type: agent, human, or system"
        ]
      ]

    alias Arbor.Actions

    def taint_roles do
      %{channel_id: :control, invitee_id: :data, invitee_name: :data, invitee_type: :data}
    end

    @impl true
    def run(params, context) do
      Actions.emit_started(__MODULE__, params)

      channel_id = params.channel_id
      agent_id = Map.get(context, :agent_id)
      invitee_id = params.invitee_id

      with {:ok, info} <- Arbor.Actions.Channel.call_comms(:get_channel_info, [channel_id]),
           :ok <- check_owner(info, agent_id) do
        member = %{
          id: invitee_id,
          name: params[:invitee_name] || "Agent",
          type: normalize_type(params[:invitee_type] || "agent")
        }

        case Arbor.Actions.Channel.call_comms(:join_channel, [channel_id, member]) do
          :ok ->
            result = %{channel_id: channel_id, invitee_id: invitee_id, status: :invited}
            Actions.emit_completed(__MODULE__, result)
            {:ok, result}

          {:error, :already_member} ->
            result = %{channel_id: channel_id, invitee_id: invitee_id, status: :already_member}
            Actions.emit_completed(__MODULE__, result)
            {:ok, result}

          {:error, reason} ->
            Actions.emit_failed(__MODULE__, reason)
            {:error, reason}
        end
      else
        {:error, :not_owner} ->
          Actions.emit_failed(__MODULE__, :not_owner)
          {:error, :not_owner}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, reason}
      end
    end

    defp check_owner(%{owner_id: owner_id}, agent_id) when owner_id == agent_id, do: :ok
    defp check_owner(_, _), do: {:error, :not_owner}

    defp normalize_type("human"), do: :human
    defp normalize_type("agent"), do: :agent
    defp normalize_type("system"), do: :system
    defp normalize_type(_), do: :agent
  end

  # ============================================================================
  # Channel.Leave
  # ============================================================================

  defmodule Leave do
    @moduledoc """
    Leave an internal channel.

    Uses `agent_id` from the execution context as the member to remove.
    """

    use Jido.Action,
      name: "channel_leave",
      description: "Leave an internal channel",
      category: "channel",
      tags: ["channel", "leave", "membership"],
      schema: [
        channel_id: [
          type: :string,
          required: true,
          doc: "Channel ID to leave"
        ]
      ]

    alias Arbor.Actions

    def taint_roles do
      %{channel_id: :control}
    end

    @impl true
    def run(params, context) do
      Actions.emit_started(__MODULE__, params)

      channel_id = params.channel_id
      agent_id = Map.get(context, :agent_id, "unknown")

      case Arbor.Actions.Channel.call_comms(:leave_channel, [channel_id, agent_id]) do
        {:error, :comms_unavailable} = err ->
          Actions.emit_failed(__MODULE__, :comms_unavailable)
          err

        {:error, :not_found} ->
          Actions.emit_failed(__MODULE__, :not_found)
          {:error, :not_found}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, reason}

        :ok ->
          result = %{channel_id: channel_id, status: :left}
          Actions.emit_completed(__MODULE__, result)
          {:ok, result}
      end
    end
  end
end
