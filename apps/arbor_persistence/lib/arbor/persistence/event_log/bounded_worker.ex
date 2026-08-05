defmodule Arbor.Persistence.EventLog.BoundedWorker do
  @moduledoc false

  @timeout_hook_key {__MODULE__, :timeout_hook}

  @doc false
  @spec with_timeout_hook((pid(), reference(), reference() -> term()), (-> result)) :: result
        when result: term()
  def with_timeout_hook(hook, fun) when is_function(hook, 3) and is_function(fun, 0) do
    previous = Process.put(@timeout_hook_key, hook)

    try do
      fun.()
    after
      restore_timeout_hook(previous)
    end
  end

  @spec terminate(pid(), reference(), reference()) :: :ok
  def terminate(worker, monitor_ref, result_ref)
      when is_pid(worker) and is_reference(monitor_ref) and is_reference(result_ref) do
    run_timeout_hook(worker, monitor_ref, result_ref)
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

  defp run_timeout_hook(worker, monitor_ref, result_ref) do
    case Process.get(@timeout_hook_key) do
      hook when is_function(hook, 3) -> hook.(worker, monitor_ref, result_ref)
      _none -> :ok
    end
  end

  defp restore_timeout_hook(nil), do: Process.delete(@timeout_hook_key)
  defp restore_timeout_hook(previous), do: Process.put(@timeout_hook_key, previous)
end
