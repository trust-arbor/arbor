defmodule Arbor.Comms.ConversationBuffer do
  @moduledoc """
  Reads conversation history from chat logs for context building.

  Parses the dated chat log files back into conversation turns
  (`{:user | :assistant, content}`) for use as LLM context.

  ## Cross-Channel Merging

  Conversations span multiple channels (Signal, Limitless, Email).
  `recent_turns_cross_channel/2` reads from all configured channels,
  matches on contact aliases (e.g. `+15551234567` and `"pendant"`
  are the same person), and merges by timestamp into a single
  unified conversation.
  """

  alias Arbor.Comms.ChatLogger
  alias Arbor.Comms.Config

  @type turn :: {:user | :assistant, String.t()}
  @type timed_turn :: {:user | :assistant, String.t(), NaiveDateTime.t()}

  @doc """
  Get recent conversation turns across all channels for a contact.

  Reads from all configured channels, resolves contact aliases,
  and merges turns by timestamp into a single conversation stream.
  Returns the last `window` turns.
  """
  @spec recent_turns_cross_channel(String.t(), pos_integer() | nil) :: [turn()]
  def recent_turns_cross_channel(contact, window \\ nil) do
    window = window || Config.handler_config(:conversation_window, 20)
    channels = Config.configured_channels()
    aliases = contact_aliases(contact)

    today = Date.utc_today()
    yesterday = Date.add(today, -1)

    turns =
      for channel <- channels,
          date <- [yesterday, today],
          turn <- read_timed_turns(channel, aliases, date) do
        turn
      end

    turns
    |> Enum.sort_by(fn {_role, _content, timestamp} -> timestamp end, NaiveDateTime)
    |> Enum.take(-window)
    |> Enum.map(fn {role, content, _timestamp} -> {role, content} end)
  end

  @doc """
  Get recent conversation turns for a contact on a given channel.

  Returns the last `window` turns involving `contact`, reading
  from today's and yesterday's chat logs as needed.
  """
  @spec recent_turns(atom(), String.t(), pos_integer()) :: [turn()]
  def recent_turns(channel, contact, window \\ nil) do
    window = window || Config.handler_config(:conversation_window, 20)

    today = Date.utc_today()
    yesterday = Date.add(today, -1)

    # Read today's log first, fall back to yesterday if we need more
    today_turns = read_turns(channel, contact, today)

    if length(today_turns) >= window do
      Enum.take(today_turns, -window)
    else
      yesterday_turns = read_turns(channel, contact, yesterday)
      combined = yesterday_turns ++ today_turns
      Enum.take(combined, -window)
    end
  end

  @doc """
  Read and parse turns for a contact from a specific date's log.
  """
  @spec read_turns(atom(), String.t(), Date.t()) :: [turn()]
  def read_turns(channel, contact, date) do
    channel
    |> read_timed_turns([contact], date)
    |> Enum.map(fn {role, content, _ts} -> {role, content} end)
  end

  @doc """
  Returns all known aliases for a contact.

  Looks up the configured `contact_aliases` map. If the contact
  appears as a key, returns all its aliases plus itself. If it
  appears as a value, returns the key's alias set. Falls back
  to just `[contact]`.
  """
  @spec contact_aliases(String.t()) :: [String.t()]
  def contact_aliases(contact) do
    aliases_map = Config.handler_config(:contact_aliases, %{})

    cond do
      # Contact is a primary key
      Map.has_key?(aliases_map, contact) ->
        [contact | Map.get(aliases_map, contact, [])] |> Enum.uniq()

      # Contact is one of the alias values
      true ->
        case Enum.find(aliases_map, fn {_k, v} -> contact in v end) do
          {primary, aliases} -> [primary | aliases] |> Enum.uniq()
          nil -> [contact]
        end
    end
  end

  # ============================================================================
  # Internal
  # ============================================================================

  # Read turns with timestamps from a log file, matching any of the given contacts
  @spec read_timed_turns(atom(), [String.t()], Date.t()) :: [timed_turn()]
  defp read_timed_turns(channel, contacts, date) do
    path = ChatLogger.log_path_for_date(channel, date)

    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.filter(&line_matches_any_contact?(&1, contacts))
        |> Enum.map(&parse_timed_turn/1)
        |> Enum.reject(&is_nil/1)

      {:error, _} ->
        []
    end
  end

  # Check if a log line involves any of the given contacts
  defp line_matches_any_contact?(line, contacts) do
    Enum.any?(contacts, fn contact ->
      String.contains?(line, "[#{contact}]")
    end)
  end

  # Parse a log line into a {role, content, timestamp} turn
  # Format: "2026-01-29 15:00:00 <<< [+15551234567] Hello"
  #         "2026-01-29 15:00:01 >>> [+15551234567] Hi there"
  defp parse_timed_turn(line) do
    cond do
      String.contains?(line, "<<<") ->
        case extract_content_with_timestamp(line, "<<<") do
          {content, ts} -> {:user, content, ts}
          nil -> nil
        end

      String.contains?(line, ">>>") ->
        case extract_content_with_timestamp(line, ">>>") do
          {content, ts} -> {:assistant, content, ts}
          nil -> nil
        end

      true ->
        nil
    end
  end

  # Extract message content and timestamp from a log line
  # Input: "2026-01-29 15:00:00 <<< [+15551234567] Hello world"
  # Output: {"Hello world", ~N[2026-01-29 15:00:00]}
  defp extract_content_with_timestamp(line, direction_marker) do
    case String.split(line, direction_marker, parts: 2) do
      [timestamp_str, rest] ->
        rest = String.trim(rest)

        # Strip the [contact] prefix
        content =
          case Regex.run(~r/^\[.+?\]\s*(.*)$/, rest) do
            [_, content] -> String.replace(content, "\\n", "\n")
            _ -> nil
          end

        timestamp = parse_timestamp(String.trim(timestamp_str))

        if content, do: {content, timestamp}, else: nil

      _ ->
        nil
    end
  end

  # Parse "2026-01-29 15:00:00" into NaiveDateTime
  defp parse_timestamp(str) do
    case NaiveDateTime.from_iso8601(String.replace(str, " ", "T")) do
      {:ok, ndt} -> ndt
      {:error, _} -> ~N[2000-01-01 00:00:00]
    end
  end
end
