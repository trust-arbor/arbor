defmodule Arbor.Comms.Channels.Signal.Poller do
  @moduledoc """
  GenServer that polls Signal for new messages at a configurable interval.

  Polls signal-cli for inbound messages and routes them through the
  Router for processing. Logs all messages via ChatLogger.
  """

  use GenServer

  require Logger

  alias Arbor.Comms.Channels.Signal
  alias Arbor.Comms.ChatLogger
  alias Arbor.Comms.Config
  alias Arbor.Comms.Router
  alias Arbor.Signals

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    interval = Config.poll_interval(:signal)
    schedule_poll(interval)
    Logger.info("Signal poller started, polling every #{interval}ms")
    emit_poller_started(:signal)
    {:ok, %{interval: interval, last_poll: nil, message_count: 0}}
  end

  @impl true
  def handle_info(:poll, state) do
    state = do_poll(state)
    schedule_poll(state.interval)
    {:noreply, state}
  end

  defp do_poll(state) do
    case Signal.poll() do
      {:ok, []} ->
        Logger.debug("Signal poll: no new messages")
        %{state | last_poll: DateTime.utc_now()}

      {:ok, messages} ->
        Logger.info("Signal poller received #{length(messages)} message(s)")

        Enum.each(messages, fn msg ->
          ChatLogger.log_message(msg)
          Router.handle_inbound(msg)
        end)

        emit_poll_cycle_completed(:signal, length(messages))

        %{
          state
          | last_poll: DateTime.utc_now(),
            message_count: state.message_count + length(messages)
        }

      {:error, reason} ->
        Logger.warning("Signal poll failed: #{inspect(reason)}")
        emit_poller_error(:signal, reason)
        %{state | last_poll: DateTime.utc_now()}
    end
  end

  defp schedule_poll(interval) do
    Process.send_after(self(), :poll, interval)
  end

  # Signal emission helpers

  defp emit_poller_started(channel) do
    Signals.emit(:comms, :poller_started, %{channel: channel})
  end

  defp emit_poll_cycle_completed(channel, message_count) do
    Signals.emit(:comms, :poll_cycle_completed, %{
      channel: channel,
      message_count: message_count
    })
  end

  defp emit_poller_error(channel, reason) do
    Signals.emit(:comms, :poller_error, %{
      channel: channel,
      reason: truncate_reason(reason)
    })
  end

  defp truncate_reason(reason) do
    inspected = inspect(reason)

    if String.length(inspected) > 200 do
      String.slice(inspected, 0, 197) <> "..."
    else
      inspected
    end
  end
end
