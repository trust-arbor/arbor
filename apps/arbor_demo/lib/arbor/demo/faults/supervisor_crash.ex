defmodule Arbor.Demo.Faults.SupervisorCrash do
  @moduledoc """
  Fault that creates a supervisor with a repeatedly crashing worker.

  The CrashWorker crashes on a timer, triggering supervisor restarts.
  High `max_restarts` keeps the supervisor alive during the demo.
  Detected by the monitor's `:supervisor` skill via restart intensity.

  ## Remediation (for DebugAgent to discover)

  The fix requires identifying the supervisor with high restart intensity
  and either:
  1. Stopping the entire supervisor tree
  2. Identifying and fixing the crashing child

  The DebugAgent must discover which supervisor is problematic through
  BEAM inspection, not by knowing this is a "SupervisorCrash" fault.
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
    correlation_id = generate_correlation_id()

    child_spec = %{
      id: __MODULE__,
      start: {__MODULE__, :start_crash_supervisor, [crash_interval, correlation_id]},
      restart: :temporary,
      type: :supervisor
    }

    case Arbor.Demo.Supervisor.start_child(supervisor_mod, child_spec) do
      {:ok, pid} ->
        emit_injection_signal(correlation_id, pid)
        {:ok, pid, correlation_id}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  def start_crash_supervisor(crash_interval, correlation_id) do
    # Store correlation_id in process dictionary for tracing
    Process.put(:arbor_correlation_id, correlation_id)
    Process.put(:arbor_fault_type, :supervisor_crash)

    children = [
      %{
        id: CrashWorker,
        start: {__MODULE__, :start_crash_worker, [crash_interval, correlation_id]},
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
  def start_crash_worker(crash_interval, correlation_id) do
    # Task.start_link is synchronous - returns only after task starts
    Task.start_link(fn ->
      Process.put(:arbor_correlation_id, correlation_id)
      Process.put(:arbor_fault_type, :crash_worker)
      Process.sleep(crash_interval)
      raise "intentional crash for demo"
    end)
  end

  defp generate_correlation_id do
    "fault_svc_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp emit_injection_signal(correlation_id, pid) do
    Arbor.Signals.emit(:demo, :fault_injected, %{
      fault: :supervisor_crash,
      correlation_id: correlation_id,
      pid: inspect(pid),
      injected_at: DateTime.utc_now()
    })
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
