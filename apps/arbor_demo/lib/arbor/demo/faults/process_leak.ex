defmodule Arbor.Demo.Faults.ProcessLeak do
  @moduledoc """
  Fault that leaks processes.

  Spawns a controller process that continuously creates child processes
  that never terminate, causing the BEAM process count to grow.
  Detected by the monitor's `:beam` skill via process_count_ratio.

  ## Remediation (for DebugAgent to discover)

  The fix requires identifying the "leak source" (controller process) and
  stopping it. The spawned child processes will remain until explicitly
  terminated. A complete fix would:
  1. Identify the controller via spawn pattern analysis
  2. Stop the controller
  3. Clean up orphaned children

  The DebugAgent must discover this through investigation, not by knowing
  this is a "ProcessLeak" fault.
  """
  @behaviour Arbor.Demo.Fault

  use GenServer

  @default_interval_ms 20
  @default_batch_size 5

  @impl Arbor.Demo.Fault
  def name, do: :process_leak

  @impl Arbor.Demo.Fault
  def description, do: "Leaks processes that never terminate"

  @impl Arbor.Demo.Fault
  def detectable_by, do: [:beam]

  @impl Arbor.Demo.Fault
  def inject(opts \\ []) do
    interval = Keyword.get(opts, :interval_ms, @default_interval_ms)
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    supervisor = Keyword.get(opts, :supervisor, Arbor.Demo.Supervisor)
    correlation_id = generate_correlation_id()

    init_state = %{
      interval: interval,
      batch_size: batch_size,
      leaked: [],
      correlation_id: correlation_id
    }

    child_spec = %{
      id: __MODULE__,
      start: {GenServer, :start_link, [__MODULE__, init_state, []]},
      restart: :temporary
    }

    case Arbor.Demo.Supervisor.start_child(supervisor, child_spec) do
      {:ok, pid} ->
        emit_injection_signal(correlation_id, pid)
        {:ok, pid, correlation_id}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl GenServer
  def init(state) do
    # Store correlation_id in process dictionary for tracing
    Process.put(:arbor_correlation_id, state.correlation_id)
    Process.put(:arbor_fault_type, :process_leak)
    schedule_leak(state.interval)
    {:ok, state}
  end

  @impl GenServer
  def handle_call(:get_leaked, _from, state) do
    {:reply, state.leaked, state}
  end

  @impl GenServer
  def handle_info(:leak, state) do
    correlation_id = state.correlation_id

    new_pids =
      for _ <- 1..state.batch_size do
        spawn(fn ->
          # Mark leaked processes for tracing
          Process.put(:arbor_correlation_id, correlation_id)
          Process.put(:arbor_leaked_by, self())

          receive do
            # These processes wait forever unless explicitly stopped
          end
        end)
      end

    schedule_leak(state.interval)
    {:noreply, %{state | leaked: new_pids ++ state.leaked}}
  end

  defp schedule_leak(interval) do
    Process.send_after(self(), :leak, interval)
  end

  defp generate_correlation_id do
    "fault_plk_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp emit_injection_signal(correlation_id, pid) do
    Arbor.Signals.emit(:demo, :fault_injected, %{
      fault: :process_leak,
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
