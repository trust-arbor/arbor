defmodule Arbor.Comms.Channels.Limitless do
  @moduledoc """
  Limitless pendant channel — inbound only.

  Polls the Limitless API for new pendant transcripts and routes them
  through the message handler. Responses go to Signal since the
  pendant is receive-only.

  ## Configuration

  Set in `config/config.exs` and `config/runtime.exs`:

      config :arbor_comms, :limitless,
        enabled: true,
        api_key: "...",              # from LIMITLESS_API_KEY env var
        poll_interval_ms: 60_000,
        checkpoint_file: "/tmp/arbor/limitless_checkpoint",
        response_recipient: "..."    # from SIGNAL_TO env var
  """

  @behaviour Arbor.Contracts.Comms.Channel

  require Logger

  alias Arbor.Comms.Channels.Signal
  alias Arbor.Comms.Dispatcher
  alias Arbor.Comms.Limitless.Client
  alias Arbor.Contracts.Comms.Message

  @impl true
  def channel_info do
    %{
      name: :limitless,
      max_message_length: :unlimited,
      supports_media: false,
      supports_threads: false,
      supports_outbound: false,
      latency: :polling
    }
  end

  @impl true
  def poll do
    since = read_checkpoint()

    case Client.get_lifelogs(since: since, limit: 20) do
      {:ok, []} ->
        {:ok, []}

      {:ok, lifelogs} ->
        messages =
          lifelogs
          |> Enum.map(fn log ->
            content = Client.extract_content(log)
            {log, content}
          end)
          |> Enum.reject(fn {_log, content} -> is_nil(content) end)
          |> Enum.map(fn {log, content} ->
            Message.new(
              channel: :limitless,
              from: "pendant",
              content: content,
              received_at: log.start_time || DateTime.utc_now(),
              metadata: %{
                lifelog_id: log.id,
                title: log.title,
                response_recipient: config(:response_recipient),
                response_channel: :signal
              }
            )
          end)

        # Update checkpoint to the latest lifelog time
        update_checkpoint(lifelogs)

        {:ok, messages}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def send_message(_recipient, _message, _opts \\ []) do
    {:error, :not_supported}
  end

  @impl true
  def send_response(%Message{} = message, response) do
    # Route responses to Signal — the pendant is receive-only
    recipient = message.metadata[:response_recipient] || config(:response_recipient)

    if recipient do
      Dispatcher.send(:signal, recipient, response)
    else
      Logger.warning("No response_recipient configured for Limitless channel")
      {:error, :no_response_recipient}
    end
  end

  @impl true
  def format_response(response) do
    # Delegate to Signal's format since responses go there
    Signal.format_response(response)
  end

  # ============================================================================
  # Checkpoint Management
  # ============================================================================

  defp read_checkpoint do
    path = checkpoint_file()

    case File.read(path) do
      {:ok, content} ->
        content = String.trim(content)

        case DateTime.from_iso8601(content) do
          {:ok, dt, _offset} -> dt
          {:error, _} -> default_checkpoint()
        end

      {:error, _} ->
        default_checkpoint()
    end
  end

  defp update_checkpoint([]), do: :ok

  defp update_checkpoint(lifelogs) do
    latest =
      lifelogs
      |> Enum.map(fn log -> log.end_time || log.start_time end)
      |> Enum.reject(&is_nil/1)
      |> Enum.max(DateTime, fn -> DateTime.utc_now() end)

    path = checkpoint_file()
    dir = Path.dirname(path)
    File.mkdir_p!(dir)
    File.write!(path, DateTime.to_iso8601(latest))
  end

  defp default_checkpoint do
    DateTime.utc_now() |> DateTime.add(-3600, :second)
  end

  defp checkpoint_file do
    config(:checkpoint_file) || "/tmp/arbor/limitless_checkpoint"
  end

  defp config(key) do
    Application.get_env(:arbor_comms, :limitless, [])
    |> Keyword.get(key)
  end
end
