defmodule Arbor.Demo.Faults.ProcessLeak do
  @moduledoc """
  Fault that leaks processes.

  Spawns a controller process that continuously creates child processes
  that never terminate, causing the BEAM process count to grow.
  Detected by the monitor's `:beam` skill via process_count_ratio.
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

    child_spec = %{
      id: __MODULE__,
      start:
        {GenServer, :start_link,
         [__MODULE__, %{interval: interval, batch_size: batch_size, leaked: []}, []]},
      restart: :temporary
    }

    case Arbor.Demo.Supervisor.start_child(supervisor, child_spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Arbor.Demo.Fault
  def clear(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      # Get leaked PIDs and stop them before stopping the controller
      try do
        leaked = GenServer.call(pid, :get_leaked, 5_000)

        Enum.each(leaked, fn leaked_pid ->
          if Process.alive?(leaked_pid), do: send(leaked_pid, :stop)
        end)
      catch
        :exit, _ -> :ok
      end

      GenServer.stop(pid, :normal)
    end

    :ok
  end

  def clear(_), do: :ok

  @impl GenServer
  def init(state) do
    schedule_leak(state.interval)
    {:ok, state}
  end

  @impl GenServer
  def handle_call(:get_leaked, _from, state) do
    {:reply, state.leaked, state}
  end

  @impl GenServer
  def handle_info(:leak, state) do
    new_pids =
      for _ <- 1..state.batch_size do
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)
      end

    schedule_leak(state.interval)
    {:noreply, %{state | leaked: new_pids ++ state.leaked}}
  end

  @impl GenServer
  def terminate(_reason, state) do
    Enum.each(state.leaked, fn pid ->
      if Process.alive?(pid), do: send(pid, :stop)
    end)

    :ok
  end

  defp schedule_leak(interval) do
    Process.send_after(self(), :leak, interval)
  end
end
