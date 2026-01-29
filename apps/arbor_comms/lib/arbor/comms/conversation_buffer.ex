defmodule Arbor.Comms.ConversationBuffer do
  @moduledoc """
  Reads conversation history from chat logs for context building.

  Parses the dated chat log files back into conversation turns
  (`{:user | :assistant, content}`) for use as LLM context.
  Reads from today's log and yesterday's if needed to fill
  the configured window size.
  """

  alias Arbor.Comms.ChatLogger
  alias Arbor.Comms.Config

  @type turn :: {:user | :assistant, String.t()}

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
    path = ChatLogger.log_path_for_date(channel, date)

    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.filter(&line_matches_contact?(&1, contact))
        |> Enum.map(&parse_turn/1)
        |> Enum.reject(&is_nil/1)

      {:error, _} ->
        []
    end
  end

  # Check if a log line involves this contact
  defp line_matches_contact?(line, contact) do
    String.contains?(line, "[#{contact}]")
  end

  # Parse a log line into a {role, content} turn
  # Format: "2026-01-29 15:00:00 <<< [+15551234567] Hello"
  #         "2026-01-29 15:00:01 >>> [+15551234567] Hi there"
  defp parse_turn(line) do
    cond do
      String.contains?(line, "<<<") ->
        case extract_content(line, "<<<") do
          nil -> nil
          content -> {:user, content}
        end

      String.contains?(line, ">>>") ->
        case extract_content(line, ">>>") do
          nil -> nil
          content -> {:assistant, content}
        end

      true ->
        nil
    end
  end

  # Extract message content from a log line
  # Input: "2026-01-29 15:00:00 <<< [+15551234567] Hello world"
  # Output: "Hello world"
  defp extract_content(line, direction_marker) do
    case String.split(line, direction_marker, parts: 2) do
      [_timestamp, rest] ->
        rest = String.trim(rest)

        # Strip the [contact] prefix
        case Regex.run(~r/^\[.+?\]\s*(.*)$/, rest) do
          [_, content] -> String.replace(content, "\\n", "\n")
          _ -> nil
        end

      _ ->
        nil
    end
  end
end
