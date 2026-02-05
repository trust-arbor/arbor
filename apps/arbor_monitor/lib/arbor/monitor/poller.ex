defmodule Arbor.Monitor.Poller do
  @moduledoc """
  Periodic polling GenServer.

  Each tick runs enabled skills, stores metrics in MetricsStore,
  runs anomaly checks, and optionally emits signals.
  """

  use GenServer

  require Logger

  alias Arbor.Monitor.{AnomalyDetector, Config, MetricsStore}

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Trigger an immediate poll cycle (useful for testing).
  """
  def poll_now(server \\ __MODULE__) do
    GenServer.call(server, :poll_now, 30_000)
  end

  # Server

  @impl true
  def init(opts) do
    AnomalyDetector.init()

    interval = Keyword.get(opts, :interval, Config.polling_interval())
    skills = Keyword.get(opts, :skills, Config.enabled_skills())

    state = %{
      interval: interval,
      skills: skills,
      poll_count: 0
    }

    schedule_poll(interval)

    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    new_state = do_poll(state)
    schedule_poll(state.interval)
    {:noreply, new_state}
  end

  @impl true
  def handle_call(:poll_now, _from, state) do
    new_state = do_poll(state)
    {:reply, :ok, new_state}
  end

  defp do_poll(state) do
    results = Enum.map(state.skills, &collect_skill/1)

    if state.poll_count == 0 do
      Logger.debug(
        "[Arbor.Monitor] First poll complete: #{inspect(Enum.map(results, &elem(&1, 0)))}"
      )
    end

    %{state | poll_count: state.poll_count + 1}
  end

  defp collect_skill(skill_mod) do
    case skill_mod.collect() do
      {:ok, metrics} ->
        MetricsStore.put(skill_mod.name(), metrics)
        check_anomalies(skill_mod, metrics)
        {skill_mod.name(), :ok}

      {:error, reason} ->
        Logger.warning(
          "[Arbor.Monitor] Skill #{skill_mod.name()} collect failed: #{inspect(reason)}"
        )

        {skill_mod.name(), {:error, reason}}
    end
  rescue
    error ->
      Logger.warning(
        "[Arbor.Monitor] Skill #{skill_mod.name()} crashed: #{Exception.message(error)}"
      )

      {skill_mod.name(), {:error, error}}
  end

  defp check_anomalies(skill_mod, metrics) do
    check_skill_anomaly(skill_mod, metrics)
    check_ewma_anomalies(skill_mod, metrics)
  end

  defp check_skill_anomaly(skill_mod, metrics) do
    case skill_mod.check(metrics) do
      :normal ->
        :ok

      {:anomaly, severity, details} ->
        MetricsStore.put_anomaly(skill_mod.name(), severity, details)
        safe_emit_signal(skill_mod.name(), severity, details)
    end
  end

  defp check_ewma_anomalies(skill_mod, metrics) do
    Enum.each(metrics, fn
      {key, value} when is_number(value) ->
        handle_ewma_result(skill_mod, AnomalyDetector.update(skill_mod.name(), key, value))

      _ ->
        :ok
    end)
  end

  defp handle_ewma_result(_skill_mod, :normal), do: :ok

  defp handle_ewma_result(skill_mod, {:anomaly, severity, details}) do
    MetricsStore.put_anomaly(skill_mod.name(), severity, details)
    safe_emit_signal(skill_mod.name(), severity, details)
  end

  defp safe_emit_signal(skill_name, severity, details) do
    if Config.signal_emission_enabled?() do
      do_emit_signal(skill_name, severity, details)
    end
  end

  defp do_emit_signal(skill_name, severity, details) do
    signal_mod = Application.get_env(:arbor_monitor, :signal_module)

    if signal_mod && function_exported?(signal_mod, :emit, 4) do
      signal_mod.emit(:monitor, :anomaly_detected, %{
        skill: skill_name,
        severity: severity,
        details: details,
        timestamp: DateTime.utc_now()
      })
    end
  rescue
    error ->
      Logger.debug("[Arbor.Monitor] Signal emission failed: #{Exception.message(error)}")
  end

  defp schedule_poll(interval) do
    Process.send_after(self(), :poll, interval)
  end
end
