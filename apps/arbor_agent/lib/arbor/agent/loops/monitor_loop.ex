defmodule Arbor.Agent.Loops.MonitorLoop do
  @moduledoc """
  Continuous monitoring loop for the Monitor Agent.

  Unlike the bounded ReasoningLoop used by DebugAgent, the MonitorLoop runs
  continuously. It subscribes to monitor anomaly signals and processes them,
  escalating to DebugAgent when investigation is warranted.

  ## Escalation Criteria

  The loop escalates to DebugAgent when:
  - A critical severity anomaly is detected
  - Multiple correlated anomalies suggest a systemic issue
  - A warning-level anomaly persists across 3+ observations

  ## Usage

      {:ok, pid} = MonitorLoop.start_link(profile: agent_profile)
      MonitorLoop.stop(agent_profile.id)
  """

  use GenServer

  require Logger

  @buffer_size 20
  @escalation_cooldown_ms 60_000

  defstruct [
    :profile,
    :subscription_ids,
    :anomaly_buffer,
    :escalation_cooldown,
    :last_escalation
  ]

  @type t :: %__MODULE__{
          profile: map(),
          subscription_ids: [String.t()],
          anomaly_buffer: [map()],
          escalation_cooldown: non_neg_integer(),
          last_escalation: integer()
        }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Starts the monitor loop for the given agent profile.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    profile = Keyword.fetch!(opts, :profile)
    GenServer.start_link(__MODULE__, profile, name: via_tuple(profile.id))
  end

  @doc """
  Stops the monitor loop for the given agent ID.
  """
  @spec stop(String.t()) :: :ok
  def stop(agent_id) do
    GenServer.stop(via_tuple(agent_id))
  end

  @doc """
  Returns the current anomaly buffer for inspection.
  """
  @spec get_buffer(String.t()) :: {:ok, [map()]} | {:error, :not_found}
  def get_buffer(agent_id) do
    GenServer.call(via_tuple(agent_id), :get_buffer)
  catch
    :exit, {:noproc, _} -> {:error, :not_found}
  end

  @doc """
  Manually triggers an escalation (for testing/demo purposes).
  """
  @spec force_escalate(String.t(), map()) :: :ok | {:error, :not_found}
  def force_escalate(agent_id, context) do
    GenServer.call(via_tuple(agent_id), {:force_escalate, context})
  catch
    :exit, {:noproc, _} -> {:error, :not_found}
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl GenServer
  def init(profile) do
    state = %__MODULE__{
      profile: profile,
      subscription_ids: [],
      anomaly_buffer: [],
      escalation_cooldown: @escalation_cooldown_ms,
      last_escalation: 0
    }

    {:ok, state, {:continue, :subscribe}}
  end

  @impl GenServer
  def handle_continue(:subscribe, state) do
    sub_ids = subscribe_to_signals()
    {:noreply, %{state | subscription_ids: sub_ids}}
  end

  @impl GenServer
  def handle_call(:get_buffer, _from, state) do
    {:reply, {:ok, state.anomaly_buffer}, state}
  end

  def handle_call({:force_escalate, context}, _from, state) do
    anomaly = %{
      metric: context[:metric] || :forced,
      value: context[:value] || 0,
      baseline: context[:baseline] || 0,
      deviation: context[:deviation] || 0,
      severity: context[:severity] || :critical,
      timestamp: System.system_time(:millisecond)
    }

    state = do_escalate(anomaly, state.anomaly_buffer, :forced, state)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info({:signal_received, signal}, state) do
    state = process_signal(signal, state)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    Enum.each(state.subscription_ids, &safe_unsubscribe/1)
    :ok
  end

  # ============================================================================
  # Signal Processing
  # ============================================================================

  defp subscribe_to_signals do
    pid = self()
    callback = fn signal -> send(pid, {:signal_received, signal}) end

    ["monitor.anomaly_detected"]
    |> Enum.map(fn pattern ->
      case safe_subscribe(pattern, callback) do
        {:ok, id} -> id
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp process_signal(signal, state) do
    anomaly = extract_anomaly(signal)
    buffer = add_to_buffer(anomaly, state.anomaly_buffer)
    state = %{state | anomaly_buffer: buffer}

    case should_escalate?(anomaly, buffer, state) do
      {:escalate, reason} ->
        do_escalate(anomaly, buffer, reason, state)

      :monitor ->
        emit_status_signal(anomaly)
        state
    end
  end

  defp extract_anomaly(signal) do
    data = get_signal_data(signal)

    %{
      metric: data[:metric],
      value: data[:value],
      baseline: data[:baseline],
      deviation: data[:deviation] || 0.0,
      severity: data[:severity] || :info,
      timestamp: data[:timestamp] || System.system_time(:millisecond)
    }
  end

  defp get_signal_data(%{data: data}) when is_map(data), do: data
  defp get_signal_data(signal) when is_map(signal), do: signal
  defp get_signal_data(_), do: %{}

  defp add_to_buffer(anomaly, buffer) do
    [anomaly | buffer] |> Enum.take(@buffer_size)
  end

  defp should_escalate?(anomaly, buffer, state) do
    now = System.monotonic_time(:millisecond)
    cooldown_passed = now - state.last_escalation > state.escalation_cooldown

    cond do
      not cooldown_passed ->
        :monitor

      anomaly.severity == :critical ->
        {:escalate, :critical_severity}

      anomaly.severity == :emergency ->
        {:escalate, :emergency_severity}

      correlated_anomalies?(buffer) ->
        {:escalate, :correlated_anomalies}

      sustained_warning?(anomaly.metric, buffer) ->
        {:escalate, :sustained_warning}

      true ->
        :monitor
    end
  end

  defp correlated_anomalies?(buffer) do
    # Multiple different metrics anomalous in short window suggests systemic issue
    recent = Enum.take(buffer, 5)
    unique_metrics = recent |> Enum.map(& &1.metric) |> Enum.uniq() |> length()
    unique_metrics >= 3
  end

  defp sustained_warning?(metric, buffer) do
    # Same metric warning 3+ times in buffer
    buffer
    |> Enum.filter(&(&1.metric == metric and &1.severity in [:warning, :critical, :emergency]))
    |> length() >= 3
  end

  defp do_escalate(anomaly, buffer, reason, state) do
    Logger.info("[MonitorLoop] Escalating: #{anomaly.metric} (reason: #{reason})")

    context = %{
      trigger_anomaly: anomaly,
      related_anomalies: Enum.take(buffer, 5),
      escalation_reason: reason
    }

    emit_escalation_signal(context)

    %{state | last_escalation: System.monotonic_time(:millisecond)}
  end

  defp emit_status_signal(anomaly) do
    safe_emit(:monitor, :anomaly_reported, %{
      type: :anomaly_reported,
      category: :monitor,
      anomaly: anomaly,
      action: :monitoring
    })
  end

  defp emit_escalation_signal(context) do
    safe_emit(:monitor, :escalation_requested, %{
      type: :escalation_requested,
      category: :monitor,
      context: context
    })
  end

  # ============================================================================
  # Safe Wrappers
  # ============================================================================

  defp safe_subscribe(pattern, callback) do
    Arbor.Signals.subscribe(pattern, callback)
  rescue
    _ -> {:error, :subscribe_failed}
  catch
    :exit, _ -> {:error, :subscribe_failed}
  end

  defp safe_unsubscribe(id) do
    Arbor.Signals.unsubscribe(id)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp safe_emit(category, type, data) do
    Arbor.Signals.emit(category, type, data)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp via_tuple(id), do: {:via, Registry, {Arbor.Agent.MonitorLoopRegistry, id}}
end
