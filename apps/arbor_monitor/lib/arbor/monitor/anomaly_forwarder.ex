defmodule Arbor.Monitor.AnomalyForwarder do
  @moduledoc """
  Bridges anomaly signals to the ops chat channel.

  Subscribes to monitor signals (anomaly_detected, cascade_detected,
  healing_verified, healing_ineffective) and forwards them as system
  messages to a channel where the diagnostician agent and humans can
  see and respond to them.

  ## Debouncing

  During cascade events, anomalies are batched and posted as a
  summary instead of individual messages to avoid flooding the channel.

  ## Runtime Bridges

  Uses `Code.ensure_loaded?` for both `Arbor.Signals` (subscription)
  and `Arbor.Comms` (message delivery) since arbor_monitor
  is a standalone app.
  """

  use GenServer

  require Logger

  @signals_mod Arbor.Signals
  @comms_mod Arbor.Comms

  @cascade_batch_interval_ms 5_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Set the channel target for forwarding anomaly messages.
  """
  @spec set_channel(String.t()) :: :ok
  def set_channel(channel_id) do
    GenServer.call(__MODULE__, {:set_channel, channel_id})
  end

  @impl true
  def init(opts) do
    channel_id = Keyword.get(opts, :channel_id)

    state = %{
      channel_id: channel_id,
      subscription_ids: [],
      cascade_batch: [],
      cascade_timer: nil
    }

    state = maybe_subscribe(state)

    Logger.info("[AnomalyForwarder] Started (channel: #{inspect(channel_id)})")
    {:ok, state}
  end

  @impl true
  def handle_call({:set_channel, channel_id}, _from, state) do
    {:reply, :ok, %{state | channel_id: channel_id}}
  end

  @impl true
  def handle_info({:signal, signal}, state) do
    handle_signal(signal, state)
  end

  def handle_info(:flush_cascade_batch, state) do
    flush_cascade_batch(state)
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Signal handlers

  defp handle_signal(%{type: :anomaly_detected} = signal, state) do
    data = signal.data || %{}
    skill = data[:skill] || "unknown"
    severity = data[:severity] || "unknown"
    details = format_details(data[:details])

    message =
      "[ANOMALY] #{severity} in #{skill}: #{details}"

    send_to_channel(state, message)
    {:noreply, state}
  end

  defp handle_signal(%{type: :cascade_detected} = signal, state) do
    data = signal.data || %{}
    count = data[:anomaly_count] || "multiple"

    message = "[CASCADE] Cascade detected — #{count} anomalies in rapid succession. Batching alerts."

    send_to_channel(state, message)

    # Start batching during cascade
    timer = schedule_cascade_flush(state.cascade_timer)
    {:noreply, %{state | cascade_timer: timer}}
  end

  defp handle_signal(%{type: :cascade_resolved}, state) do
    state = flush_cascade_batch_now(state)
    message = "[CASCADE RESOLVED] Cascade has ended. Resuming normal alert delivery."
    send_to_channel(state, message)
    {:noreply, state}
  end

  defp handle_signal(%{type: :healing_verified} = signal, state) do
    data = signal.data || %{}
    message = "[VERIFIED] Fix verified — held through soak period. #{inspect(data[:fingerprint] || "")}"
    send_to_channel(state, message)
    {:noreply, state}
  end

  defp handle_signal(%{type: :healing_ineffective} = signal, state) do
    data = signal.data || %{}
    message = "[INEFFECTIVE] Fix did not hold — anomaly recurred. #{inspect(data[:fingerprint] || "")}"
    send_to_channel(state, message)
    {:noreply, state}
  end

  defp handle_signal(_signal, state) do
    {:noreply, state}
  end

  # Channel messaging

  defp send_to_channel(%{channel_id: nil}, _message), do: :ok

  defp send_to_channel(%{channel_id: channel_id}, message) do
    if comms_available?() do
      apply(@comms_mod, :send_to_channel, [
        channel_id,
        "anomaly_forwarder",
        "Monitor",
        :system,
        message
      ])
    else
      Logger.debug("[AnomalyForwarder] Comms not available, logging: #{message}")
    end
  rescue
    error ->
      Logger.warning("[AnomalyForwarder] Failed to send: #{inspect(error)}")
  catch
    :exit, reason ->
      Logger.warning("[AnomalyForwarder] Channel exited: #{inspect(reason)}")
  end

  # Cascade batching

  defp schedule_cascade_flush(existing_timer) do
    if existing_timer, do: Process.cancel_timer(existing_timer)
    Process.send_after(self(), :flush_cascade_batch, @cascade_batch_interval_ms)
  end

  defp flush_cascade_batch(state) do
    state = flush_cascade_batch_now(state)
    {:noreply, state}
  end

  defp flush_cascade_batch_now(%{cascade_batch: []} = state), do: state

  defp flush_cascade_batch_now(%{cascade_batch: batch} = state) do
    count = length(batch)
    message = "[BATCH] #{count} anomalies during cascade period"
    send_to_channel(state, message)
    %{state | cascade_batch: [], cascade_timer: nil}
  end

  # Signal subscription

  defp maybe_subscribe(state) do
    if signals_available?() do
      topics = [
        "monitor.anomaly_detected",
        "monitor.cascade_detected",
        "monitor.cascade_resolved",
        "monitor.healing_verified",
        "monitor.healing_ineffective"
      ]

      ids =
        Enum.flat_map(topics, fn topic ->
          handler = fn signal -> send(self(), {:signal, signal}) end

          try do
            case apply(@signals_mod, :subscribe, [topic, handler]) do
              {:ok, id} -> [id]
              _ -> []
            end
          rescue
            _ -> []
          catch
            :exit, _ -> []
          end
        end)

      if ids == [] do
        Logger.debug("[AnomalyForwarder] Signal bus not running, operating without subscriptions")
      else
        Logger.info("[AnomalyForwarder] Subscribed to #{length(ids)} signal topics")
      end

      %{state | subscription_ids: ids}
    else
      Logger.debug("[AnomalyForwarder] Signals not available, running without subscriptions")
      state
    end
  end

  defp signals_available? do
    Code.ensure_loaded?(@signals_mod) and
      function_exported?(@signals_mod, :subscribe, 2)
  end

  defp comms_available? do
    Code.ensure_loaded?(@comms_mod) and
      function_exported?(@comms_mod, :send_to_channel, 5)
  end

  defp format_details(nil), do: "no details"
  defp format_details(details) when is_map(details) do
    Enum.map_join(details, ", ", fn {k, v} -> "#{k}=#{inspect(v)}" end)
  end
  defp format_details(details), do: inspect(details)
end
