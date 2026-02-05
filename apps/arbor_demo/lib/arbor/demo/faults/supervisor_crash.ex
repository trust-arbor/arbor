defmodule Arbor.Demo.Faults.SupervisorCrash do
  @moduledoc """
  Fault that creates a supervisor with a repeatedly crashing worker.

  The CrashWorker crashes on a timer, triggering supervisor restarts.
  High `max_restarts` keeps the supervisor alive during the demo.
  Detected by the monitor's `:supervisor` skill via restart intensity.
  """
  @behaviour Arbor.Demo.Fault

  @default_crash_interval_ms 2_000
  @max_restarts 1_000
  @max_seconds 60

  @impl Arbor.Demo.Fault
  def name, do: :supervisor_crash

  @impl Arbor.Demo.Fault
  def description, do: "Creates a supervisor with a repeatedly crashing child"

  @impl Arbor.Demo.Fault
  def detectable_by, do: [:supervisor]

  @impl Arbor.Demo.Fault
  def inject(opts \\ []) do
    crash_interval = Keyword.get(opts, :crash_interval_ms, @default_crash_interval_ms)
    supervisor_mod = Keyword.get(opts, :supervisor, Arbor.Demo.Supervisor)

    child_spec = %{
      id: __MODULE__,
      start: {__MODULE__, :start_crash_supervisor, [crash_interval]},
      restart: :temporary,
      type: :supervisor
    }

    case Arbor.Demo.Supervisor.start_child(supervisor_mod, child_spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Arbor.Demo.Fault
  def clear(pid) when is_pid(pid) do
    if Process.alive?(pid), do: Supervisor.stop(pid, :normal)
    :ok
  end

  def clear(_), do: :ok

  @doc false
  def start_crash_supervisor(crash_interval) do
    children = [
      %{
        id: CrashWorker,
        start: {__MODULE__, :start_crash_worker, [crash_interval]},
        restart: :permanent
      }
    ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      max_restarts: @max_restarts,
      max_seconds: @max_seconds
    )
  end

  @doc false
  def start_crash_worker(crash_interval) do
    Task.start_link(fn ->
      Process.sleep(crash_interval)
      raise "intentional crash for demo"
    end)
  end
end
