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

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    interval = Config.poll_interval(:signal)
    schedule_poll(interval)
    Logger.info("Signal poller started, polling every #{interval}ms")
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
        %{state | last_poll: DateTime.utc_now()}

      {:ok, messages} ->
        Logger.info("Signal poller received #{length(messages)} message(s)")

        Enum.each(messages, fn msg ->
          ChatLogger.log_message(msg)
          Router.handle_inbound(msg)
        end)

        %{
          state
          | last_poll: DateTime.utc_now(),
            message_count: state.message_count + length(messages)
        }

      {:error, reason} ->
        Logger.warning("Signal poll failed: #{inspect(reason)}")
        %{state | last_poll: DateTime.utc_now()}
    end
  end

  defp schedule_poll(interval) do
    Process.send_after(self(), :poll, interval)
  end
end
