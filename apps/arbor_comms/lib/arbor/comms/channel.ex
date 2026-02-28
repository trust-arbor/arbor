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
          metadata: map()
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
    GenServer.call(server, {:send_message, sender_id, sender_name, sender_type, content, metadata})
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
      pubsub_topic: "channel:#{channel_id}"
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
  def handle_call({:send_message, sender_id, sender_name, sender_type, content, metadata}, _from, state) do
    with :ok <- check_membership(sender_id, state),
         :ok <- check_rate_limit(sender_id, state) do
      message = %{
        id: generate_message_id(),
        channel_id: state.channel_id,
        sender_id: sender_id,
        sender_name: sender_name,
        sender_type: sender_type,
        content: content,
        timestamp: DateTime.utc_now(),
        metadata: metadata
      }

      # Update in-memory state
      messages = [message | state.messages] |> Enum.take(state.max_history)
      rate_limits = Map.put(state.rate_limits, sender_id, System.monotonic_time(:millisecond))
      new_state = %{state | messages: messages, rate_limits: rate_limits}

      # Persist async
      persist_message(state.channel_id, message)

      # Broadcast to PubSub subscribers
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
      new_state = %{state | members: Map.delete(state.members, member_id)}

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
      pubsub_topic: state.pubsub_topic
    }

    {:reply, info, state}
  end

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

  defp persist_message(channel_id, message) do
    Task.start(fn ->
      if channel_store_available?() do
        apply(Arbor.Persistence.ChannelStore, :append_message, [
          channel_id,
          %{
            sender_id: message.sender_id,
            sender_name: message.sender_name,
            sender_type: Atom.to_string(message.sender_type),
            content: message.content,
            timestamp: message.timestamp,
            metadata: message.metadata
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

  defp generate_id do
    suffix = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    "chan_#{suffix}"
  end

  defp generate_message_id do
    suffix = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    "msg_#{suffix}"
  end

end
