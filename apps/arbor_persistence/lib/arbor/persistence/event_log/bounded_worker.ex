defmodule Arbor.Persistence.EventLog.BoundedWorker do
  @moduledoc false

  @active_key {__MODULE__, :active}

  @spec active?() :: boolean()
  def active?, do: Process.get(@active_key) == true

  @spec run((-> result), integer()) ::
          {:ok, result} | {:error, :operation_timeout | :worker_exit}
        when result: term()
  def run(fun, deadline_mono) when is_function(fun, 0) and is_integer(deadline_mono) do
    case remaining_timeout(deadline_mono) do
      {:ok, _remaining_ms} ->
        owner = self()
        response_ref = make_ref()

        {coordinator, monitor_ref} =
          spawn_monitor(fn -> coordinate(owner, response_ref, fun, deadline_mono) end)

        await_coordinator(coordinator, monitor_ref, response_ref, deadline_mono)

      {:error, :operation_timeout} = error ->
        error
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

      {:EXIT, ^worker, _reason} ->
        await_down(worker, monitor_ref, result_ref)

      {:DOWN, ^monitor_ref, :process, ^worker, _reason} ->
        drain_result(result_ref)
    end
  end

  defp coordinate(owner, response_ref, fun, deadline_mono) do
    Process.flag(:trap_exit, true)
    owner_ref = Process.monitor(owner)

    if Process.alive?(owner) do
      coordinator = self()
      worker_result_ref = make_ref()

      {worker, worker_ref} =
        :erlang.spawn_opt(
          fn -> run_worker(coordinator, worker_result_ref, fun) end,
          [:link, :monitor]
        )

      coordinate_worker(
        owner,
        owner_ref,
        response_ref,
        worker,
        worker_ref,
        worker_result_ref,
        deadline_mono,
        :pending
      )
    else
      Process.demonitor(owner_ref, [:flush])
      :ok
    end
  end

  defp run_worker(coordinator, result_ref, fun) do
    Process.put(@active_key, true)

    try do
      send(coordinator, {result_ref, fun.()})
    after
      Process.delete(@active_key)
    end
  end

  defp coordinate_worker(
         owner,
         owner_ref,
         response_ref,
         worker,
         worker_ref,
         result_ref,
         deadline_mono,
         result_state
       ) do
    case remaining_timeout(deadline_mono) do
      {:ok, remaining_ms} ->
        receive do
          {:DOWN, ^owner_ref, :process, ^owner, _reason} ->
            terminate(worker, worker_ref, result_ref)

          {^result_ref, result} when result_state == :pending ->
            coordinate_worker(
              owner,
              owner_ref,
              response_ref,
              worker,
              worker_ref,
              result_ref,
              deadline_mono,
              {:ready, result}
            )

          {^result_ref, _duplicate} ->
            coordinate_worker(
              owner,
              owner_ref,
              response_ref,
              worker,
              worker_ref,
              result_ref,
              deadline_mono,
              result_state
            )

          {:EXIT, ^worker, _reason} ->
            coordinate_worker(
              owner,
              owner_ref,
              response_ref,
              worker,
              worker_ref,
              result_ref,
              deadline_mono,
              result_state
            )

          {:DOWN, ^worker_ref, :process, ^worker, reason} ->
            finish_worker(
              owner,
              owner_ref,
              response_ref,
              result_ref,
              reason,
              result_state,
              deadline_mono
            )
        after
          remaining_ms ->
            terminate(worker, worker_ref, result_ref)
            reply(owner, owner_ref, response_ref, {:error, :operation_timeout})
        end

      {:error, :operation_timeout} ->
        terminate(worker, worker_ref, result_ref)
        reply(owner, owner_ref, response_ref, {:error, :operation_timeout})
    end
  end

  defp finish_worker(
         owner,
         owner_ref,
         response_ref,
         result_ref,
         reason,
         result_state,
         deadline_mono
       ) do
    result_state = take_crossing_result(result_ref, result_state)

    response =
      case {reason, result_state, remaining_timeout(deadline_mono)} do
        {:normal, {:ready, result}, {:ok, _remaining_ms}} ->
          {:ok, result}

        {:normal, {:ready, _result}, {:error, :operation_timeout}} ->
          {:error, :operation_timeout}

        _worker_failed_or_malformed ->
          {:error, :worker_exit}
      end

    reply(owner, owner_ref, response_ref, response)
  end

  defp take_crossing_result(_result_ref, {:ready, _result} = result_state), do: result_state

  defp take_crossing_result(result_ref, :pending) do
    receive do
      {^result_ref, result} -> {:ready, result}
    after
      0 -> :pending
    end
  end

  defp reply(owner, owner_ref, response_ref, response) do
    Process.demonitor(owner_ref, [:flush])
    send(owner, {response_ref, response})
    :ok
  end

  defp await_coordinator(coordinator, monitor_ref, response_ref, deadline_mono) do
    case remaining_timeout(deadline_mono) do
      {:ok, remaining_ms} ->
        receive do
          {^response_ref, response} ->
            settle_coordinator(coordinator, monitor_ref, response_ref, response, deadline_mono)

          {:DOWN, ^monitor_ref, :process, ^coordinator, _reason} ->
            drain_result(response_ref)
            {:error, :worker_exit}
        after
          remaining_ms ->
            terminate(coordinator, monitor_ref, response_ref)
            {:error, :operation_timeout}
        end

      {:error, :operation_timeout} ->
        terminate(coordinator, monitor_ref, response_ref)
        {:error, :operation_timeout}
    end
  end

  defp settle_coordinator(coordinator, monitor_ref, response_ref, response, deadline_mono) do
    case remaining_timeout(deadline_mono) do
      {:ok, remaining_ms} ->
        receive do
          {:DOWN, ^monitor_ref, :process, ^coordinator, _reason} ->
            drain_result(response_ref)
            response
        after
          remaining_ms ->
            terminate(coordinator, monitor_ref, response_ref)
            {:error, :operation_timeout}
        end

      {:error, :operation_timeout} ->
        terminate(coordinator, monitor_ref, response_ref)
        {:error, :operation_timeout}
    end
  end

  defp remaining_timeout(deadline_mono) do
    remaining_ms = deadline_mono - System.monotonic_time(:millisecond)

    if remaining_ms > 0,
      do: {:ok, remaining_ms},
      else: {:error, :operation_timeout}
  end
end
