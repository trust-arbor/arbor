defmodule Arbor.Persistence.EventLog.BoundedWorker do
  @moduledoc false

  @active_key {__MODULE__, :active}

  @spec active?() :: boolean()
  def active?, do: Process.get(@active_key) == true

  @spec run((-> result), integer()) ::
          {:ok, result} | {:error, :operation_timeout | :worker_exit}
        when result: term()
  def run(fun, deadline_mono) when is_function(fun, 0) and is_integer(deadline_mono) do
    remaining_ms = deadline_mono - System.monotonic_time(:millisecond)

    if remaining_ms > 0 do
      parent = self()
      result_ref = make_ref()

      {worker, monitor_ref} =
        spawn_monitor(fn ->
          Process.put(@active_key, true)

          try do
            send(parent, {result_ref, fun.()})
          after
            Process.delete(@active_key)
          end
        end)

      receive do
        {^result_ref, result} ->
          Process.demonitor(monitor_ref, [:flush])
          {:ok, result}

        {:DOWN, ^monitor_ref, :process, ^worker, _reason} ->
          drain_result(result_ref)
          {:error, :worker_exit}
      after
        remaining_ms ->
          terminate(worker, monitor_ref, result_ref)
          {:error, :operation_timeout}
      end
    else
      {:error, :operation_timeout}
    end
  end

  def run(_fun, _deadline_mono), do: {:error, :operation_timeout}

  @spec terminate(pid(), reference(), reference()) :: :ok
  def terminate(worker, monitor_ref, result_ref)
      when is_pid(worker) and is_reference(monitor_ref) and is_reference(result_ref) do
    Process.exit(worker, :kill)
    await_down(worker, monitor_ref, result_ref)
  end

  @spec drain_result(reference()) :: :ok
  def drain_result(result_ref) when is_reference(result_ref) do
    receive do
      {^result_ref, _completion} -> drain_result(result_ref)
    after
      0 -> :ok
    end
  end

  defp await_down(worker, monitor_ref, result_ref) do
    receive do
      {^result_ref, _completion} ->
        await_down(worker, monitor_ref, result_ref)

      {:DOWN, ^monitor_ref, :process, ^worker, _reason} ->
        drain_result(result_ref)
    end
  end
end
