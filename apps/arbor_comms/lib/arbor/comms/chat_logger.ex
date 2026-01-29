defmodule Arbor.Comms.ChatLogger do
  @moduledoc """
  Logs messages to channel-specific chat log files.

  Each channel gets its own log file at the configured path
  (default: `/tmp/arbor/<channel>_chat.log`).
  """

  alias Arbor.Comms.Config
  alias Arbor.Contracts.Comms.Message

  @doc """
  Log a message to the appropriate channel's chat log.
  """
  @spec log_message(Message.t()) :: :ok
  def log_message(%Message{} = msg) do
    path = Config.log_path(msg.channel)
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
  Read recent lines from a channel's chat log.
  """
  @spec recent(atom(), pos_integer()) :: {:ok, [String.t()]} | {:error, term()}
  def recent(channel, count \\ 50) do
    path = Config.log_path(channel)

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

  defp ensure_log_dir(path) do
    path |> Path.dirname() |> File.mkdir_p()
  end
end
