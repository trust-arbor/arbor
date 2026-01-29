defmodule Arbor.Comms.Channels.Limitless.Poller do
  @moduledoc """
  GenServer that polls the Limitless API for new pendant transcripts.

  Polls at a configurable interval (default: 5 minutes) and routes
  new lifelogs through the Router for processing.
  """

  use GenServer

  require Logger

  alias Arbor.Comms.Channels.Limitless
  alias Arbor.Comms.ChatLogger
  alias Arbor.Comms.Config
  alias Arbor.Comms.Router

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    interval = Config.poll_interval(:limitless)
    schedule_poll(interval)
    Logger.info("Limitless poller started, polling every #{interval}ms")
    {:ok, %{interval: interval, last_poll: nil, message_count: 0}}
  end

  @impl true
  def handle_info(:poll, state) do
    state = do_poll(state)
    schedule_poll(state.interval)
    {:noreply, state}
  end

  defp do_poll(state) do
    case Limitless.poll() do
      {:ok, []} ->
        %{state | last_poll: DateTime.utc_now()}

      {:ok, messages} ->
        Logger.info("Limitless poller received #{length(messages)} transcript(s)")

        Enum.each(messages, fn msg ->
          ChatLogger.log_message(msg)
          Router.handle_inbound(msg)
        end)

        %{
          state
          | last_poll: DateTime.utc_now(),
            message_count: state.message_count + length(messages)
        }

      {:error, {:rate_limited, retry_after}} ->
        # Back off for the specified time
        delay = retry_after * 1000
        Logger.warning("Limitless rate limited, backing off #{retry_after}s")
        schedule_poll(delay)
        %{state | last_poll: DateTime.utc_now()}

      {:error, reason} ->
        Logger.warning("Limitless poll failed: #{inspect(reason)}")
        %{state | last_poll: DateTime.utc_now()}
    end
  end

  defp schedule_poll(interval) do
    Process.send_after(self(), :poll, interval)
  end
end
