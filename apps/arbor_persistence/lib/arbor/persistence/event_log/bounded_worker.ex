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
        startup_ref = make_ref()
        response_ref = make_ref()

        {coordinator, monitor_ref} =
          spawn_monitor(fn ->
            coordinate(owner, startup_ref, response_ref, fun, deadline_mono)
          end)

        await_startup(
          coordinator,
          monitor_ref,
          startup_ref,
          response_ref,
          deadline_mono
        )

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

  defp coordinate(owner, startup_ref, response_ref, fun, deadline_mono) do
    Process.flag(:trap_exit, true)
    owner_ref = Process.monitor(owner)

    if Process.alive?(owner) do
      coordinator = self()
      worker_start_ref = make_ref()
      worker_result_ref = make_ref()

      {worker, worker_ref} =
        :erlang.spawn_opt(
          fn ->
            run_worker(coordinator, worker_start_ref, worker_result_ref, fun)
          end,
          [:link, :monitor]
        )

      send(owner, {startup_ref, coordinator, worker})

      await_owner_ready(
        owner,
        owner_ref,
        startup_ref,
        response_ref,
        worker,
        worker_ref,
        worker_start_ref,
        worker_result_ref,
        deadline_mono
      )
    else
      Process.demonitor(owner_ref, [:flush])
      :ok
    end
  end

  defp run_worker(coordinator, start_ref, result_ref, fun) do
    receive do
      {^start_ref, :start} ->
        Process.put(@active_key, true)

        try do
          send(coordinator, {result_ref, fun.()})
        after
          Process.delete(@active_key)
        end
    end
  end

  defp await_owner_ready(
         owner,
         owner_ref,
         startup_ref,
         response_ref,
         worker,
         worker_ref,
         worker_start_ref,
         result_ref,
         deadline_mono
       ) do
    case remaining_timeout(deadline_mono) do
      {:ok, remaining_ms} ->
        receive do
          {:DOWN, ^owner_ref, :process, ^owner, _reason} ->
            terminate(worker, worker_ref, result_ref)

          {^startup_ref, :ready, ^owner} ->
            start_worker(
              owner,
              owner_ref,
              response_ref,
              worker,
              worker_ref,
              worker_start_ref,
              result_ref,
              deadline_mono
            )

          {:EXIT, ^worker, _reason} ->
            await_owner_ready(
              owner,
              owner_ref,
              startup_ref,
              response_ref,
              worker,
              worker_ref,
              worker_start_ref,
              result_ref,
              deadline_mono
            )

          {:DOWN, ^worker_ref, :process, ^worker, reason} ->
            finish_worker(
              owner,
              owner_ref,
              response_ref,
              result_ref,
              reason,
              :pending,
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

  defp start_worker(
         owner,
         owner_ref,
         response_ref,
         worker,
         worker_ref,
         worker_start_ref,
         result_ref,
         deadline_mono
       ) do
    case remaining_timeout(deadline_mono) do
      {:ok, _remaining_ms} ->
        send(worker, {worker_start_ref, :start})

        coordinate_worker(
          owner,
          owner_ref,
          response_ref,
          worker,
          worker_ref,
          result_ref,
          deadline_mono,
          :pending
        )

      {:error, :operation_timeout} ->
        terminate(worker, worker_ref, result_ref)
        reply(owner, owner_ref, response_ref, {:error, :operation_timeout})
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

  defp await_startup(coordinator, monitor_ref, startup_ref, response_ref, deadline_mono) do
    case remaining_timeout(deadline_mono) do
      {:ok, remaining_ms} ->
        receive do
          {^startup_ref, ^coordinator, worker} when is_pid(worker) ->
            worker_ref = Process.monitor(worker)
            send(coordinator, {startup_ref, :ready, self()})

            await_operation(
              coordinator,
              monitor_ref,
              worker,
              worker_ref,
              startup_ref,
              response_ref,
              deadline_mono,
              :pending,
              :up,
              :up
            )

          {:DOWN, ^monitor_ref, :process, ^coordinator, _reason} ->
            drain_private_protocol(startup_ref, response_ref, nil, monitor_ref)
            {:error, :worker_exit}
        after
          remaining_ms ->
            abort_before_start(
              coordinator,
              monitor_ref,
              startup_ref,
              response_ref,
              {:error, :operation_timeout}
            )
        end

      {:error, :operation_timeout} ->
        abort_before_start(
          coordinator,
          monitor_ref,
          startup_ref,
          response_ref,
          {:error, :operation_timeout}
        )
    end
  end

  defp await_operation(
         coordinator,
         coordinator_ref,
         worker,
         worker_ref,
         startup_ref,
         response_ref,
         deadline_mono,
         response_state,
         worker_state,
         coordinator_state
       ) do
    cond do
      match?({:ready, _response}, response_state) and match?({:down, _reason}, worker_state) and
          match?({:down, _reason}, coordinator_state) ->
        {:ready, response} = response_state
        drain_private_protocol(startup_ref, response_ref, worker_ref, coordinator_ref)
        response

      response_state == :pending and match?({:down, _reason}, coordinator_state) ->
        abort_known(
          coordinator,
          coordinator_ref,
          worker,
          worker_ref,
          startup_ref,
          response_ref,
          worker_state,
          coordinator_state,
          {:error, :worker_exit}
        )

      true ->
        await_operation_message(
          coordinator,
          coordinator_ref,
          worker,
          worker_ref,
          startup_ref,
          response_ref,
          deadline_mono,
          response_state,
          worker_state,
          coordinator_state
        )
    end
  end

  defp await_operation_message(
         coordinator,
         coordinator_ref,
         worker,
         worker_ref,
         startup_ref,
         response_ref,
         deadline_mono,
         response_state,
         worker_state,
         coordinator_state
       ) do
    case remaining_timeout(deadline_mono) do
      {:ok, remaining_ms} ->
        receive do
          {^response_ref, response} when response_state == :pending ->
            await_operation(
              coordinator,
              coordinator_ref,
              worker,
              worker_ref,
              startup_ref,
              response_ref,
              deadline_mono,
              {:ready, response},
              worker_state,
              coordinator_state
            )

          {^response_ref, _duplicate} ->
            await_operation(
              coordinator,
              coordinator_ref,
              worker,
              worker_ref,
              startup_ref,
              response_ref,
              deadline_mono,
              response_state,
              worker_state,
              coordinator_state
            )

          {^startup_ref, ^coordinator, ^worker} ->
            await_operation(
              coordinator,
              coordinator_ref,
              worker,
              worker_ref,
              startup_ref,
              response_ref,
              deadline_mono,
              response_state,
              worker_state,
              coordinator_state
            )

          {:DOWN, ^worker_ref, :process, ^worker, reason} ->
            await_operation(
              coordinator,
              coordinator_ref,
              worker,
              worker_ref,
              startup_ref,
              response_ref,
              deadline_mono,
              response_state,
              {:down, reason},
              coordinator_state
            )

          {:DOWN, ^coordinator_ref, :process, ^coordinator, reason} ->
            await_operation(
              coordinator,
              coordinator_ref,
              worker,
              worker_ref,
              startup_ref,
              response_ref,
              deadline_mono,
              response_state,
              worker_state,
              {:down, reason}
            )
        after
          remaining_ms ->
            abort_known(
              coordinator,
              coordinator_ref,
              worker,
              worker_ref,
              startup_ref,
              response_ref,
              worker_state,
              coordinator_state,
              {:error, :operation_timeout}
            )
        end

      {:error, :operation_timeout} ->
        abort_known(
          coordinator,
          coordinator_ref,
          worker,
          worker_ref,
          startup_ref,
          response_ref,
          worker_state,
          coordinator_state,
          {:error, :operation_timeout}
        )
    end
  end

  defp abort_before_start(coordinator, coordinator_ref, startup_ref, response_ref, result) do
    Process.exit(coordinator, :kill)

    receive do
      {^startup_ref, ^coordinator, worker} when is_pid(worker) ->
        worker_ref = Process.monitor(worker)

        abort_known(
          coordinator,
          coordinator_ref,
          worker,
          worker_ref,
          startup_ref,
          response_ref,
          :up,
          :up,
          result
        )

      {:DOWN, ^coordinator_ref, :process, ^coordinator, _reason} ->
        drain_private_protocol(startup_ref, response_ref, nil, coordinator_ref)
        result

      {^response_ref, _response} ->
        abort_before_start(coordinator, coordinator_ref, startup_ref, response_ref, result)
    end
  end

  defp abort_known(
         coordinator,
         coordinator_ref,
         worker,
         worker_ref,
         startup_ref,
         response_ref,
         worker_state,
         coordinator_state,
         result
       ) do
    {worker_state, coordinator_state} =
      stop_worker(
        worker,
        worker_ref,
        coordinator,
        coordinator_ref,
        startup_ref,
        response_ref,
        worker_state,
        coordinator_state
      )

    _coordinator_state =
      stop_coordinator(
        coordinator,
        coordinator_ref,
        worker,
        worker_ref,
        startup_ref,
        response_ref,
        worker_state,
        coordinator_state
      )

    drain_private_protocol(startup_ref, response_ref, worker_ref, coordinator_ref)
    result
  end

  defp stop_worker(
         _worker,
         _worker_ref,
         _coordinator,
         _coordinator_ref,
         _startup_ref,
         _response_ref,
         {:down, _reason} = worker_state,
         coordinator_state
       ),
       do: {worker_state, coordinator_state}

  defp stop_worker(
         worker,
         worker_ref,
         coordinator,
         coordinator_ref,
         startup_ref,
         response_ref,
         :up,
         coordinator_state
       ) do
    Process.exit(worker, :kill)

    receive do
      {:DOWN, ^worker_ref, :process, ^worker, reason} ->
        {{:down, reason}, coordinator_state}

      {:DOWN, ^coordinator_ref, :process, ^coordinator, reason} ->
        stop_worker(
          worker,
          worker_ref,
          coordinator,
          coordinator_ref,
          startup_ref,
          response_ref,
          :up,
          {:down, reason}
        )

      {^startup_ref, ^coordinator, ^worker} ->
        stop_worker(
          worker,
          worker_ref,
          coordinator,
          coordinator_ref,
          startup_ref,
          response_ref,
          :up,
          coordinator_state
        )

      {^response_ref, _response} ->
        stop_worker(
          worker,
          worker_ref,
          coordinator,
          coordinator_ref,
          startup_ref,
          response_ref,
          :up,
          coordinator_state
        )
    end
  end

  defp stop_coordinator(
         _coordinator,
         _coordinator_ref,
         _worker,
         _worker_ref,
         _startup_ref,
         _response_ref,
         _worker_state,
         {:down, _reason} = coordinator_state
       ),
       do: coordinator_state

  defp stop_coordinator(
         coordinator,
         coordinator_ref,
         worker,
         worker_ref,
         startup_ref,
         response_ref,
         worker_state,
         :up
       ) do
    Process.exit(coordinator, :kill)

    receive do
      {:DOWN, ^coordinator_ref, :process, ^coordinator, reason} ->
        {:down, reason}

      {:DOWN, ^worker_ref, :process, ^worker, _reason} ->
        stop_coordinator(
          coordinator,
          coordinator_ref,
          worker,
          worker_ref,
          startup_ref,
          response_ref,
          worker_state,
          :up
        )

      {^startup_ref, ^coordinator, ^worker} ->
        stop_coordinator(
          coordinator,
          coordinator_ref,
          worker,
          worker_ref,
          startup_ref,
          response_ref,
          worker_state,
          :up
        )

      {^response_ref, _response} ->
        stop_coordinator(
          coordinator,
          coordinator_ref,
          worker,
          worker_ref,
          startup_ref,
          response_ref,
          worker_state,
          :up
        )
    end
  end

  defp drain_private_protocol(startup_ref, response_ref, worker_ref, coordinator_ref) do
    receive do
      {^startup_ref, _coordinator, _worker} ->
        drain_private_protocol(startup_ref, response_ref, worker_ref, coordinator_ref)

      {^response_ref, _response} ->
        drain_private_protocol(startup_ref, response_ref, worker_ref, coordinator_ref)

      {:DOWN, ^worker_ref, :process, _worker, _reason} when is_reference(worker_ref) ->
        drain_private_protocol(startup_ref, response_ref, worker_ref, coordinator_ref)

      {:DOWN, ^coordinator_ref, :process, _coordinator, _reason} ->
        drain_private_protocol(startup_ref, response_ref, worker_ref, coordinator_ref)
    after
      0 -> :ok
    end
  end

  defp remaining_timeout(deadline_mono) do
    remaining_ms = deadline_mono - System.monotonic_time(:millisecond)

    if remaining_ms > 0,
      do: {:ok, remaining_ms},
      else: {:error, :operation_timeout}
  end
end
