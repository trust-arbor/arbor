defmodule Arbor.AI.OwnedOperation do
  @moduledoc false

  @cleanup_grace_ms 250

  @spec run((-> term()), keyword(), term()) :: term()
  def run(fun, opts, timeout_error \\ :timeout)

  def run(fun, opts, timeout_error) when is_function(fun, 0) and is_list(opts) do
    with {:ok, _opts, remaining} <- Arbor.AI.Timeout.remaining(opts),
         true <- is_integer(remaining) or {:error, :finite_deadline_required},
         {:ok, deadline} <- Arbor.AI.Timeout.deadline(opts) do
      run_until(fun, deadline, remaining, timeout_error)
    end
  end

  def run(_fun, _opts, _timeout_error), do: {:error, :invalid_owned_operation}

  defp run_until(fun, deadline, remaining, timeout_error)
       when is_integer(deadline) and is_integer(remaining) and remaining > 0 do
    caller = self()
    reply_alias = :erlang.alias()
    operation_ref = make_ref()

    {worker, monitor} =
      spawn_monitor(fn ->
        result = safely_apply(fun)
        completed_at = System.monotonic_time(:millisecond)
        send(reply_alias, {operation_ref, result, completed_at, self()})

        receive do
          {^operation_ref, :ack, ^caller} -> :ok
        after
          @cleanup_grace_ms -> :ok
        end
      end)

    kill_timer = arm_deadline_kill(worker, deadline)

    await_result(
      worker,
      monitor,
      kill_timer,
      reply_alias,
      operation_ref,
      deadline,
      remaining,
      timeout_error
    )
  end

  defp await_result(
         worker,
         monitor,
         kill_timer,
         reply_alias,
         operation_ref,
         deadline,
         remaining,
         timeout_error
       ) do
    receive do
      {^operation_ref, result, completed_at, ^worker} ->
        cancel_deadline_kill(kill_timer)
        :erlang.unalias(reply_alias)
        send(worker, {operation_ref, :ack, self()})
        await_down(worker, monitor)

        if Arbor.AI.Timeout.completed_before_deadline?(completed_at, deadline),
          do: unwrap(result),
          else: {:error, timeout_error}

      {:DOWN, ^monitor, :process, ^worker, reason} ->
        cancel_deadline_kill(kill_timer)
        :erlang.unalias(reply_alias)

        if System.monotonic_time(:millisecond) >= deadline do
          {:error, timeout_error}
        else
          {:error, {:owned_operation_exit, Arbor.LLM.sanitize_external_reason(reason)}}
        end
    after
      remaining ->
        :erlang.unalias(reply_alias)
        terminate_and_await(worker, monitor)
        cancel_deadline_kill(kill_timer)
        {:error, timeout_error}
    end
  end

  defp arm_deadline_kill(worker, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    case :timer.kill_after(remaining, worker) do
      {:ok, timer} -> timer
      {:error, _reason} -> nil
    end
  end

  defp cancel_deadline_kill(nil), do: :ok

  defp cancel_deadline_kill(timer) do
    _ = :timer.cancel(timer)
    :ok
  end

  defp terminate_and_await(worker, monitor) do
    if Process.alive?(worker), do: Process.exit(worker, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^worker, _reason} -> :ok
    after
      @cleanup_grace_ms -> Process.demonitor(monitor, [:flush])
    end
  end

  defp await_down(worker, monitor) do
    receive do
      {:DOWN, ^monitor, :process, ^worker, _reason} -> :ok
    after
      @cleanup_grace_ms ->
        if Process.alive?(worker), do: Process.exit(worker, :kill)
        Process.demonitor(monitor, [:flush])
    end
  end

  defp safely_apply(fun) do
    {:ok, fun.()}
  rescue
    exception -> {:raised, :error, Arbor.LLM.external_exception_message(exception)}
  catch
    kind, reason -> {:raised, kind, Arbor.LLM.sanitize_external_reason(reason)}
  end

  defp unwrap({:ok, result}), do: result
  defp unwrap({:raised, kind, reason}), do: {:error, {:operation_failed, kind, reason}}
end
