defmodule Arbor.Persistence.Backup.Scheduler do
  @moduledoc """
  GenServer that runs backups at configured times.

  ## Configuration

      config :arbor_persistence, :backup,
        enabled: true,
        schedule: {3, 0}  # {hour, minute} in local time

  The scheduler runs the backup at the configured time each day. If the server
  starts after the scheduled time, the next backup will run the following day.

  ## Starting

  The scheduler is automatically started by `Arbor.Persistence.Application`
  when `:start_repo` is true and backup is enabled. It can also be started
  manually:

      {:ok, _pid} = Arbor.Persistence.Backup.Scheduler.start_link([])

  ## Manual Trigger

  To trigger a backup immediately:

      Arbor.Persistence.Backup.Scheduler.run_now()
  """

  use GenServer
  require Logger

  alias Arbor.Persistence.Backup

  @default_schedule {3, 0}

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Start the backup scheduler.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Trigger a backup immediately, outside of the schedule.
  """
  @spec run_now() :: {:ok, String.t()} | {:error, term()}
  def run_now do
    GenServer.call(__MODULE__, :run_now, :infinity)
  end

  @doc """
  Get the scheduled time for the next backup.
  """
  @spec next_backup_time() :: DateTime.t()
  def next_backup_time do
    GenServer.call(__MODULE__, :next_backup_time)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    config = Application.get_env(:arbor_persistence, :backup, [])
    enabled = Keyword.get(config, :enabled, false)

    if enabled do
      schedule = Keyword.get(config, :schedule, @default_schedule)
      next_run = calculate_next_run(schedule)
      ms_until_next = ms_until(next_run)

      Logger.info(
        "Backup scheduler started. Next backup at #{format_datetime(next_run)} " <>
          "(in #{format_duration(ms_until_next)})"
      )

      timer_ref = Process.send_after(self(), :run_backup, ms_until_next)

      {:ok,
       %{
         schedule: schedule,
         next_run: next_run,
         timer_ref: timer_ref,
         last_result: nil
       }}
    else
      Logger.info("Backup scheduler disabled")
      {:ok, %{enabled: false}}
    end
  end

  @impl true
  def handle_call(:run_now, _from, state) do
    result = Backup.backup()

    case result do
      {:ok, path} ->
        Logger.info("Manual backup completed: #{path}")

      {:error, reason} ->
        Logger.error("Manual backup failed: #{inspect(reason)}")
    end

    {:reply, result, %{state | last_result: result}}
  end

  def handle_call(:next_backup_time, _from, %{enabled: false} = state) do
    {:reply, nil, state}
  end

  def handle_call(:next_backup_time, _from, state) do
    {:reply, state.next_run, state}
  end

  @impl true
  def handle_info(:run_backup, %{enabled: false} = state) do
    {:noreply, state}
  end

  def handle_info(:run_backup, state) do
    Logger.info("Starting scheduled backup...")

    result = Backup.backup()

    case result do
      {:ok, path} ->
        Logger.info("Scheduled backup completed: #{path}")

      {:error, reason} ->
        Logger.error("Scheduled backup failed: #{inspect(reason)}")
    end

    # Schedule next run
    next_run = calculate_next_run(state.schedule)
    ms_until_next = ms_until(next_run)

    Logger.info(
      "Next backup at #{format_datetime(next_run)} (in #{format_duration(ms_until_next)})"
    )

    timer_ref = Process.send_after(self(), :run_backup, ms_until_next)

    {:noreply, %{state | next_run: next_run, timer_ref: timer_ref, last_result: result}}
  end

  # ============================================================================
  # Time Calculations
  # ============================================================================

  defp calculate_next_run({hour, minute}) do
    now = DateTime.utc_now()

    # Build today's scheduled time
    today_scheduled =
      now
      |> DateTime.to_date()
      |> DateTime.new!(Time.new!(hour, minute, 0))

    # If we're past today's scheduled time, schedule for tomorrow
    if DateTime.compare(now, today_scheduled) == :gt do
      DateTime.add(today_scheduled, 1, :day)
    else
      today_scheduled
    end
  end

  defp ms_until(target) do
    diff = DateTime.diff(target, DateTime.utc_now(), :millisecond)
    max(diff, 1000)
  end

  defp format_datetime(datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")
  end

  defp format_duration(ms) do
    hours = div(ms, 3_600_000)
    remaining = rem(ms, 3_600_000)
    minutes = div(remaining, 60_000)

    cond do
      hours > 0 -> "#{hours}h #{minutes}m"
      minutes > 0 -> "#{minutes}m"
      true -> "#{div(ms, 1000)}s"
    end
  end
end
