defmodule Arbor.Comms.ChatLogger do
  @moduledoc """
  Logs messages to channel-specific, date-rotated chat log files.

  Each channel gets its own log directory with daily log files:
  `<log_dir>/<date>.log` (e.g., `~/.arbor/logs/signal_chat/2026-01-29.log`).

  Old log files are cleaned up based on the configured retention period.
  """

  alias Arbor.Comms.Config
  alias Arbor.Contracts.Comms.Message

  @doc """
  Log a message to the appropriate channel's dated chat log.
  """
  @spec log_message(Message.t()) :: :ok
  def log_message(%Message{} = msg) do
    path = log_path_for_date(msg.channel, msg.received_at)
    ensure_log_dir(path)

    line = format_log_line(msg)
    File.write(path, line, [:append])
    :ok
  rescue
    error ->
      require Logger
      Logger.warning("ChatLogger failed to write: #{inspect(error)}")
      :ok
  end

  @doc """
  Read recent lines from a channel's chat log (today's file by default).
  """
  @spec recent(atom(), pos_integer()) :: {:ok, [String.t()]} | {:error, term()}
  def recent(channel, count \\ 50) do
    path = log_path_for_date(channel)

    case File.read(path) do
      {:ok, content} ->
        lines =
          content
          |> String.split("\n", trim: true)
          |> Enum.take(-count)

        {:ok, lines}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Remove log files older than the configured retention period.

  Returns the number of files removed.
  """
  @spec cleanup(atom()) :: {:ok, non_neg_integer()}
  def cleanup(channel) do
    dir = Config.log_dir(channel)
    retention = Config.log_retention_days(channel)
    cutoff = Date.utc_today() |> Date.add(-retention)

    case File.ls(dir) do
      {:ok, files} ->
        removed =
          files
          |> Enum.filter(fn file -> log_file?(file) and file_before_date?(file, cutoff) end)
          |> Enum.count(fn file -> File.rm(Path.join(dir, file)) == :ok end)

        {:ok, removed}

      {:error, :enoent} ->
        {:ok, 0}
    end
  end

  @doc """
  Returns the log file path for a given channel and date.
  """
  @spec log_path_for_date(atom(), DateTime.t() | Date.t() | nil) :: String.t()
  def log_path_for_date(channel, datetime \\ nil) do
    dir = Config.log_dir(channel)
    date_str = date_string(datetime)
    Path.join(dir, "#{date_str}.log")
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp format_log_line(%Message{} = msg) do
    timestamp = format_timestamp(msg.received_at)
    direction = if msg.direction == :inbound, do: "<<<", else: ">>>"
    party = if msg.direction == :inbound, do: msg.from, else: msg.to

    "#{timestamp} #{direction} [#{party}] #{String.replace(msg.content, "\n", "\\n")}\n"
  end

  defp format_timestamp(nil), do: format_timestamp(DateTime.utc_now())

  defp format_timestamp(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  end

  defp date_string(nil), do: date_string(DateTime.utc_now())
  defp date_string(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d")
  defp date_string(%Date{} = d), do: Calendar.strftime(d, "%Y-%m-%d")

  defp ensure_log_dir(path) do
    path |> Path.dirname() |> File.mkdir_p()
  end

  defp log_file?(filename) do
    String.match?(filename, ~r/^\d{4}-\d{2}-\d{2}\.log$/)
  end

  defp file_before_date?(filename, %Date{} = cutoff) do
    case Date.from_iso8601(String.trim_trailing(filename, ".log")) do
      {:ok, file_date} -> Date.compare(file_date, cutoff) == :lt
      _ -> false
    end
  end
end
