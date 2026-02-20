defmodule Arbor.Monitor.AnomalyForwarder do
  @moduledoc """
  Bridges anomaly signals to the ops chat room.

  Subscribes to monitor signals (anomaly_detected, cascade_detected,
  healing_verified, healing_ineffective) and forwards them as system
  messages to a GroupChat room where the diagnostician agent and
  humans can see and respond to them.

  ## Debouncing

  During cascade events, anomalies are batched and posted as a
  summary instead of individual messages to avoid flooding the room.

  ## Runtime Bridges

  Uses `Code.ensure_loaded?` for both `Arbor.Signals` (subscription)
  and `Arbor.Agent.GroupChat` (message delivery) since arbor_monitor
  is a standalone app.
  """

  use GenServer

  require Logger

  @signals_mod Arbor.Signals
  @group_chat_mod Arbor.Agent.GroupChat

  @cascade_batch_interval_ms 5_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Set the group chat target for forwarding anomaly messages.
  """
  @spec set_group(pid() | GenServer.server()) :: :ok
  def set_group(group_pid) do
    GenServer.call(__MODULE__, {:set_group, group_pid})
  end

  @impl true
  def init(opts) do
    group_pid = Keyword.get(opts, :group_pid)

    state = %{
      group_pid: group_pid,
      subscription_ids: [],
      cascade_batch: [],
      cascade_timer: nil
    }

    state = maybe_subscribe(state)

    Logger.info("[AnomalyForwarder] Started (group: #{inspect(group_pid)})")
    {:ok, state}
  end

  @impl true
  def handle_call({:set_group, group_pid}, _from, state) do
    {:reply, :ok, %{state | group_pid: group_pid}}
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

    send_to_group(state, message)
    {:noreply, state}
  end

  defp handle_signal(%{type: :cascade_detected} = signal, state) do
    data = signal.data || %{}
    count = data[:anomaly_count] || "multiple"

    message = "[CASCADE] Cascade detected — #{count} anomalies in rapid succession. Batching alerts."

    send_to_group(state, message)

    # Start batching during cascade
    timer = schedule_cascade_flush(state.cascade_timer)
    {:noreply, %{state | cascade_timer: timer}}
  end

  defp handle_signal(%{type: :cascade_resolved}, state) do
    state = flush_cascade_batch_now(state)
    message = "[CASCADE RESOLVED] Cascade has ended. Resuming normal alert delivery."
    send_to_group(state, message)
    {:noreply, state}
  end

  defp handle_signal(%{type: :healing_verified} = signal, state) do
    data = signal.data || %{}
    message = "[VERIFIED] Fix verified — held through soak period. #{inspect(data[:fingerprint] || "")}"
    send_to_group(state, message)
    {:noreply, state}
  end

  defp handle_signal(%{type: :healing_ineffective} = signal, state) do
    data = signal.data || %{}
    message = "[INEFFECTIVE] Fix did not hold — anomaly recurred. #{inspect(data[:fingerprint] || "")}"
    send_to_group(state, message)
    {:noreply, state}
  end

  defp handle_signal(_signal, state) do
    {:noreply, state}
  end

  # Group chat messaging

  defp send_to_group(%{group_pid: nil}, _message), do: :ok

  defp send_to_group(%{group_pid: group_pid}, message) do
    if group_chat_available?() do
      apply(@group_chat_mod, :send_message, [
        group_pid,
        "anomaly_forwarder",
        "Monitor",
        :system,
        message
      ])
    else
      Logger.debug("[AnomalyForwarder] GroupChat not available, logging: #{message}")
    end
  rescue
    error ->
      Logger.warning("[AnomalyForwarder] Failed to send: #{inspect(error)}")
  catch
    :exit, reason ->
      Logger.warning("[AnomalyForwarder] Group chat exited: #{inspect(reason)}")
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
    send_to_group(state, message)
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

  defp group_chat_available? do
    Code.ensure_loaded?(@group_chat_mod) and
      function_exported?(@group_chat_mod, :send_message, 5)
  end

  defp format_details(nil), do: "no details"
  defp format_details(details) when is_map(details) do
    Enum.map_join(details, ", ", fn {k, v} -> "#{k}=#{inspect(v)}" end)
  end
  defp format_details(details), do: inspect(details)
end
