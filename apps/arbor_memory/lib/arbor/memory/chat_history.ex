defmodule Arbor.Memory.ChatHistory do
  @moduledoc """
  GenServer-based storage for chat message history per agent.

  Provides append-only message storage with automatic persistence and
  configurable message limits. Messages are stored in ETS for fast access
  and automatically persisted to durable storage.

  ## Storage

  Messages are kept in a named ETS table (`:arbor_chat_history`) keyed by
  `{agent_id, message_id}`. This allows efficient per-agent queries while
  maintaining O(1) lookups by ID.

  ## Message Cap

  Each agent's history is capped at 500 messages. When the limit is exceeded,
  the oldest messages (by timestamp) are automatically removed from both ETS
  and durable storage.

  ## Signals

  All mutations emit signals via `Arbor.Memory.Signals`:
  - `{:memory, :chat_message_added}` — new message appended
  """

  use GenServer

  alias Arbor.Memory.DurableStore
  alias Arbor.Memory.Signals

  require Logger

  @ets_table :arbor_chat_history
  @max_messages 500

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
  Automatically persists to durable storage and trims if over the message limit.

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
    persist_message_async(agent_id, msg)

    Signals.emit_chat_message_added(agent_id, msg.id)
    Logger.debug("Chat message added for #{agent_id}: #{msg.id}")

    maybe_trim(agent_id)
    :ok
  end

  @doc """
  Load all messages for an agent, sorted by timestamp ascending.

  Returns an empty list if no messages are found in ETS. Will attempt to
  load from durable storage if ETS is empty.
  """
  @spec load(String.t()) :: [map()]
  def load(agent_id) when is_binary(agent_id) do
    case :ets.match_object(@ets_table, {{agent_id, :_}, :_}) do
      [] ->
        load_messages_from_postgres(agent_id)

      entries ->
        entries
        |> Enum.map(fn {_key, msg} -> msg end)
        |> Enum.sort(fn a, b ->
          case {a[:timestamp], b[:timestamp]} do
            {%DateTime{} = ta, %DateTime{} = tb} -> DateTime.compare(ta, tb) != :gt
            _ -> true
          end
        end)
    end
  end

  @doc """
  Clear all messages for an agent.

  Removes from both ETS and durable storage.
  """
  @spec clear(String.t()) :: :ok
  def clear(agent_id) when is_binary(agent_id) do
    match_spec = [{{{agent_id, :_}, :_}, [], [true]}]
    :ets.select_delete(@ets_table, match_spec)
    DurableStore.delete_by_prefix("chat_history", agent_id)
    Logger.debug("Cleared chat history for #{agent_id}")
    :ok
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    ensure_ets_table()
    load_all_messages_from_postgres()
    {:ok, %{}}
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp ensure_ets_table do
    if :ets.whereis(@ets_table) == :undefined do
      :ets.new(@ets_table, [:named_table, :public, :set])
    end
  rescue
    ArgumentError -> :ok
  end

  defp persist_message_async(agent_id, msg) do
    key = "#{agent_id}:#{msg.id}"

    msg_map =
      msg
      |> Map.update(:timestamp, nil, &maybe_to_iso8601/1)

    DurableStore.persist_async("chat_history", key, msg_map)
  end

  defp load_messages_from_postgres(agent_id) do
    if DurableStore.available?() do
      case DurableStore.load_by_prefix("chat_history", agent_id) do
        {:ok, pairs} ->
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
          |> Enum.sort(fn a, b ->
            case {a[:timestamp], b[:timestamp]} do
              {%DateTime{} = ta, %DateTime{} = tb} -> DateTime.compare(ta, tb) != :gt
              _ -> true
            end
          end)

        _ ->
          []
      end
    else
      []
    end
  end

  defp load_all_messages_from_postgres do
    if DurableStore.available?() do
      case DurableStore.load_all("chat_history") do
        {:ok, pairs} ->
          Enum.each(pairs, fn {key, msg_map} ->
            case String.split(key, ":", parts: 2) do
              [agent_id, msg_id] ->
                msg = restore_timestamps(msg_map)
                :ets.insert(@ets_table, {{agent_id, msg_id}, msg})

              _ ->
                Logger.warning("ChatHistory: invalid key format from Postgres: #{key}")
            end
          end)

          Logger.info("ChatHistory: loaded #{length(pairs)} messages from Postgres")

        _ ->
          :ok
      end
    end
  rescue
    e ->
      Logger.warning("ChatHistory: failed to load from Postgres: #{inspect(e)}")
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
        DurableStore.delete("chat_history", "#{aid}:#{mid}")
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
