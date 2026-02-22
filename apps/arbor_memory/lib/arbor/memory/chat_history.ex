defmodule Arbor.Memory.ChatHistory do
  @moduledoc """
  GenServer-based storage for chat message history per agent.

  Provides append-only message storage with ETS caching and durable persistence
  via ChannelStore (Postgres). Each agent gets a DM channel for their chat history.

  ## Storage

  Messages are kept in a named ETS table (`:arbor_chat_history`) keyed by
  `{agent_id, message_id}` for fast reads. Writes go to both ETS and the
  ChannelStore backend (Postgres `channel_messages` table).

  On init, messages are loaded from ChannelStore into ETS. Falls back to
  the legacy MemoryStore (`records` table) for backwards compatibility.

  ## Message Cap

  Each agent's history is capped at 500 messages. When the limit is exceeded,
  the oldest messages (by timestamp) are automatically removed from ETS.

  ## Signals

  All mutations emit signals via `Arbor.Memory.Signals`:
  - `{:memory, :chat_message_added}` — new message appended
  """

  use GenServer

  alias Arbor.Memory.MemoryStore
  alias Arbor.Memory.Signals

  require Logger

  @ets_table :arbor_chat_history
  @max_messages 500
  @channel_store Arbor.Persistence.ChannelStore

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Starts the ChatHistory GenServer.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Append a message to an agent's chat history.

  The message must be a map and will be assigned a unique ID if not present.
  Automatically persists to ChannelStore and trims if over the message limit.

  ## Examples

      ChatHistory.append("agent_001", %{
        role: "user",
        content: "Hello",
        timestamp: DateTime.utc_now()
      })
  """
  @spec append(String.t(), map()) :: :ok
  def append(agent_id, message) when is_binary(agent_id) and is_map(message) do
    msg = Map.put_new(message, :id, generate_id())
    :ets.insert(@ets_table, {{agent_id, msg.id}, msg})

    persist_to_channel_async(agent_id, msg)

    Signals.emit_chat_message_added(agent_id, msg.id)
    Logger.debug("Chat message added for #{agent_id}: #{msg.id}")

    maybe_trim(agent_id)
    :ok
  end

  @doc """
  Load all messages for an agent, sorted by timestamp ascending.

  Returns from ETS cache first, falling back to ChannelStore then legacy MemoryStore.
  """
  @spec load(String.t()) :: [map()]
  def load(agent_id) when is_binary(agent_id) do
    case :ets.match_object(@ets_table, {{agent_id, :_}, :_}) do
      [] ->
        load_from_durable(agent_id)

      entries ->
        entries
        |> Enum.map(fn {_key, msg} -> msg end)
        |> sort_by_timestamp()
    end
  end

  @doc """
  Load the most recent messages for an agent, sorted by timestamp ascending.

  Returns at most `:limit` messages (default 50). When `:before` is given
  (a message ID), returns only messages with timestamps strictly before
  that message's timestamp.

  ## Options

  - `:limit` — maximum messages to return (default: 50)
  - `:before` — message ID cursor; only return messages older than this one

  ## Examples

      # Load the 50 most recent messages
      ChatHistory.load_recent("agent_001")

      # Load 20 messages before a cursor
      ChatHistory.load_recent("agent_001", limit: 20, before: "chatmsg_abc123")
  """
  @spec load_recent(String.t(), keyword()) :: [map()]
  def load_recent(agent_id, opts \\ []) when is_binary(agent_id) do
    limit = Keyword.get(opts, :limit, 50)
    before_id = Keyword.get(opts, :before)

    all_messages =
      case :ets.match_object(@ets_table, {{agent_id, :_}, :_}) do
        [] -> load_from_durable(agent_id)
        entries -> Enum.map(entries, fn {_key, msg} -> msg end)
      end

    sorted_desc =
      Enum.sort(all_messages, fn a, b ->
        case {a[:timestamp], b[:timestamp]} do
          {%DateTime{} = ta, %DateTime{} = tb} -> DateTime.compare(ta, tb) == :gt
          _ -> true
        end
      end)

    filtered =
      if before_id do
        cursor_msg = Enum.find(all_messages, fn msg -> msg[:id] == before_id end)
        filter_before_cursor(sorted_desc, cursor_msg)
      else
        sorted_desc
      end

    # Take limit, then reverse so oldest-first for display
    filtered
    |> Enum.take(limit)
    |> Enum.reverse()
  end

  @doc """
  Return the total number of messages stored for an agent.

  ## Examples

      ChatHistory.count("agent_001")
      #=> 142
  """
  @spec count(String.t()) :: non_neg_integer()
  def count(agent_id) when is_binary(agent_id) do
    :ets.match_object(@ets_table, {{agent_id, :_}, :_})
    |> length()
  end

  @doc """
  Clear all messages for an agent.

  Removes from both ETS and legacy durable storage.
  """
  @spec clear(String.t()) :: :ok
  def clear(agent_id) when is_binary(agent_id) do
    match_spec = [{{{agent_id, :_}, :_}, [], [true]}]
    :ets.select_delete(@ets_table, match_spec)
    MemoryStore.delete_by_prefix("chat_history", agent_id)
    Logger.debug("Cleared chat history for #{agent_id}")
    :ok
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    ensure_ets_table()
    load_all_on_startup()
    {:ok, %{}}
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp filter_before_cursor(messages, nil), do: messages

  defp filter_before_cursor(messages, %{timestamp: %DateTime{} = cursor_ts}) do
    Enum.filter(messages, fn msg ->
      case msg[:timestamp] do
        %DateTime{} = ts -> DateTime.compare(ts, cursor_ts) == :lt
        _ -> false
      end
    end)
  end

  defp filter_before_cursor(messages, _), do: messages

  defp ensure_ets_table do
    if :ets.whereis(@ets_table) == :undefined do
      :ets.new(@ets_table, [:named_table, :public, :set])
    end
  rescue
    ArgumentError -> :ok
  end

  # ── ChannelStore persistence ──────────────────────────────────────

  defp persist_to_channel_async(agent_id, msg) do
    if channel_store_available?() do
      Task.start(fn ->
        try do
          channel_id = agent_channel_id(agent_id)
          apply(@channel_store, :ensure_channel, [channel_id, [type: "dm", owner_id: agent_id]])

          role = msg[:role] || msg["role"] || "unknown"
          content = msg[:content] || msg["content"] || ""
          display_name = msg[:display_name] || msg["display_name"]
          ts = msg[:timestamp] || DateTime.utc_now()

          apply(@channel_store, :append_message, [
            channel_id,
            %{
              sender_id: agent_id,
              sender_name: display_name,
              sender_type: sender_type_from_role(role),
              content: to_string(content),
              timestamp: ts,
              metadata: %{"message_id" => msg[:id] || msg["id"], "role" => to_string(role)}
            }
          ])
        rescue
          e -> Logger.debug("ChatHistory: channel persist failed: #{Exception.message(e)}")
        end
      end)
    else
      # Fall back to legacy MemoryStore
      persist_message_legacy(agent_id, msg)
    end
  end

  defp sender_type_from_role("user"), do: "human"
  defp sender_type_from_role("human"), do: "human"
  defp sender_type_from_role("assistant"), do: "agent"
  defp sender_type_from_role("system"), do: "system"
  defp sender_type_from_role(_), do: "agent"

  defp agent_channel_id(agent_id), do: "dm:#{agent_id}"

  defp channel_store_available? do
    Code.ensure_loaded?(@channel_store) and
      function_exported?(@channel_store, :available?, 0) and
      apply(@channel_store, :available?, [])
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  # ── Durable loading ───────────────────────────────────────────────

  defp load_from_durable(agent_id) do
    # Try ChannelStore first, fall back to legacy MemoryStore
    case load_from_channel_store(agent_id) do
      messages when is_list(messages) and messages != [] ->
        # Cache in ETS
        Enum.each(messages, fn msg ->
          msg_id = msg[:id] || msg["id"] || generate_id()
          msg = Map.put_new(msg, :id, msg_id)
          :ets.insert(@ets_table, {{agent_id, msg_id}, msg})
        end)

        messages

      _ ->
        load_from_legacy(agent_id)
    end
  end

  defp load_from_channel_store(agent_id) do
    if channel_store_available?() do
      channel_id = agent_channel_id(agent_id)

      case apply(@channel_store, :load_messages, [channel_id, [limit: @max_messages]]) do
        messages when is_list(messages) and messages != [] ->
          Enum.map(messages, &channel_message_to_chat_msg/1)

        _ ->
          []
      end
    else
      []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp channel_message_to_chat_msg(cm) do
    role = get_in(cm, [Access.key(:metadata), "role"]) || sender_type_to_role(cm.sender_type)

    %{
      id: get_in(cm, [Access.key(:metadata), "message_id"]) || cm.id,
      role: role,
      content: cm.content,
      timestamp: cm.timestamp,
      display_name: cm.sender_name
    }
  end

  defp sender_type_to_role("human"), do: "user"
  defp sender_type_to_role("agent"), do: "assistant"
  defp sender_type_to_role("system"), do: "system"
  defp sender_type_to_role(_), do: "assistant"

  # ── Legacy MemoryStore persistence ────────────────────────────────

  defp persist_message_legacy(agent_id, msg) do
    key = "#{agent_id}:#{msg.id}"

    msg_map =
      msg
      |> Map.update(:timestamp, nil, &maybe_to_iso8601/1)

    MemoryStore.persist_async("chat_history", key, msg_map)
  end

  defp load_from_legacy(agent_id) do
    if MemoryStore.available?() do
      case MemoryStore.load_by_prefix("chat_history", agent_id) do
        {:ok, pairs} ->
          restore_agent_messages(pairs, agent_id)

        _ ->
          []
      end
    else
      []
    end
  end

  defp restore_agent_messages(pairs, agent_id) do
    Enum.each(pairs, fn {key, msg_map} ->
      case String.split(key, ":", parts: 2) do
        [^agent_id, msg_id] ->
          msg = restore_timestamps(msg_map)
          :ets.insert(@ets_table, {{agent_id, msg_id}, msg})

        _ ->
          :ok
      end
    end)

    :ets.match_object(@ets_table, {{agent_id, :_}, :_})
    |> Enum.map(fn {_key, msg} -> msg end)
    |> sort_by_timestamp()
  end

  defp sort_by_timestamp(messages) do
    Enum.sort(messages, fn a, b ->
      case {a[:timestamp], b[:timestamp]} do
        {%DateTime{} = ta, %DateTime{} = tb} -> DateTime.compare(ta, tb) != :gt
        _ -> true
      end
    end)
  end

  # ── Startup loading ───────────────────────────────────────────────

  defp load_all_on_startup do
    # Try ChannelStore first for all DM channels
    loaded_from_channels = load_all_from_channel_store()

    # Fall back to legacy MemoryStore for any remaining messages
    unless loaded_from_channels do
      load_all_from_legacy()
    end
  end

  defp load_all_from_channel_store do
    if channel_store_available?() do
      channels = apply(@channel_store, :list_channels, [[type: "dm"]])

      if channels != [] do
        Enum.each(channels, &load_channel_messages_to_ets/1)
        Logger.info("ChatHistory: loaded messages from ChannelStore")
        true
      else
        false
      end
    else
      false
    end
  rescue
    e ->
      Logger.warning("ChatHistory: failed to load from ChannelStore: #{inspect(e)}")
      false
  catch
    :exit, _ -> false
  end

  defp load_channel_messages_to_ets(channel) do
    agent_id = channel.owner_id
    if not is_nil(agent_id) do
      messages =
        apply(@channel_store, :load_messages, [
          channel.channel_id,
          [limit: @max_messages]
        ])

      Enum.each(messages, fn cm ->
        msg = channel_message_to_chat_msg(cm)
        msg_id = msg[:id] || generate_id()
        msg = Map.put_new(msg, :id, msg_id)
        :ets.insert(@ets_table, {{agent_id, msg_id}, msg})
      end)
    end
  end

  defp load_all_from_legacy do
    if MemoryStore.available?() do
      case MemoryStore.load_all("chat_history") do
        {:ok, pairs} ->
          Enum.each(pairs, &restore_message_from_pair/1)
          Logger.info("ChatHistory: loaded #{length(pairs)} messages from legacy store")

        _ ->
          :ok
      end
    end
  rescue
    e ->
      Logger.warning("ChatHistory: failed to load from legacy store: #{inspect(e)}")
  end

  defp restore_message_from_pair({key, msg_map}) do
    case String.split(key, ":", parts: 2) do
      [agent_id, msg_id] ->
        msg = restore_timestamps(msg_map)
        :ets.insert(@ets_table, {{agent_id, msg_id}, msg})

      _ ->
        Logger.warning("ChatHistory: invalid key format from legacy store: #{key}")
    end
  end

  defp restore_timestamps(msg) do
    msg
    |> Map.update(:timestamp, nil, fn
      ts when is_binary(ts) ->
        case DateTime.from_iso8601(ts) do
          {:ok, dt, _} -> dt
          _ -> nil
        end

      other ->
        other
    end)
  end

  defp maybe_to_iso8601(nil), do: nil
  defp maybe_to_iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp maybe_to_iso8601(other), do: other

  defp maybe_trim(agent_id) do
    entries = :ets.match_object(@ets_table, {{agent_id, :_}, :_})

    if length(entries) > @max_messages do
      sorted =
        Enum.sort(entries, fn {_key, a}, {_key2, b} ->
          case {a[:timestamp], b[:timestamp]} do
            {%DateTime{} = ta, %DateTime{} = tb} -> DateTime.compare(ta, tb) != :gt
            _ -> true
          end
        end)

      to_remove = Enum.take(sorted, length(entries) - @max_messages)

      Enum.each(to_remove, fn {{aid, mid}, _msg} ->
        :ets.delete(@ets_table, {aid, mid})
      end)

      Logger.debug(
        "ChatHistory: trimmed #{length(to_remove)} old messages for #{agent_id}"
      )
    end
  end

  defp generate_id do
    "chatmsg_" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))
  end
end
