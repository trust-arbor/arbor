defmodule Arbor.Persistence.EventLog.BoundedWorker do
  @moduledoc false

  @active_key {__MODULE__, :active}
  @owner_identity_tag :event_log_bounded_worker_owner
  @owner_check_tag {__MODULE__, :owner_check}
  @owner_check_reply_tag {__MODULE__, :owner_check_reply}

  @opaque owner_identity ::
            {:event_log_bounded_worker_owner, pid(), pid(), pid(), reference(), integer()}

  @spec active?() :: boolean()
  def active?, do: match?({@owner_identity_tag, _, _, _, _, _}, Process.get(@active_key))

  @spec owner_identity() :: {:ok, owner_identity()} | {:error, :owner_inactive}
  def owner_identity do
    case Process.get(@active_key) do
      {@owner_identity_tag, coordinator, worker, owner, token, deadline_mono} = identity
      when is_pid(coordinator) and is_pid(worker) and is_pid(owner) and is_reference(token) and
             is_integer(deadline_mono) ->
        {:ok, identity}

      _inactive ->
        {:error, :owner_inactive}
    end
  end

  @spec owner_active?(owner_identity(), integer()) :: boolean()
  def owner_active?(
        {@owner_identity_tag, coordinator, worker, owner, token, identity_deadline},
        deadline_mono
      )
      when is_pid(coordinator) and is_pid(worker) and is_pid(owner) and is_reference(token) and
             is_integer(identity_deadline) and is_integer(deadline_mono) do
    identity_deadline == deadline_mono and
      System.monotonic_time(:millisecond) < deadline_mono and
      Process.alive?(owner) and Process.alive?(coordinator) and Process.alive?(worker)
  end

  def owner_active?(_identity, _deadline_mono), do: false

  @spec validate_owner(owner_identity(), integer()) :: :ok | {:error, :owner_inactive}
  def validate_owner(
        {@owner_identity_tag, coordinator, worker, owner, token, identity_deadline} = identity,
        deadline_mono
      ) do
    if owner_active?(identity, deadline_mono) do
      validate_owner_with_coordinator(
        coordinator,
        worker,
        owner,
        token,
        identity_deadline
      )
    else
      {:error, :owner_inactive}
    end
  end

  def validate_owner(_identity, _deadline_mono), do: {:error, :owner_inactive}

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
      owner_token = make_ref()
      worker_start_ref = make_ref()
      worker_result_ref = make_ref()

      {worker, worker_ref} =
        :erlang.spawn_opt(
          fn ->
            run_worker(
              coordinator,
              owner,
              owner_token,
              worker_start_ref,
              worker_result_ref,
              fun,
              deadline_mono
            )
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
        owner_token,
        worker_start_ref,
        worker_result_ref,
        deadline_mono
      )
    else
      Process.demonitor(owner_ref, [:flush])
      :ok
    end
  end

  defp run_worker(
         coordinator,
         owner,
         owner_token,
         start_ref,
         result_ref,
         fun,
         deadline_mono
       ) do
    receive do
      {^start_ref, :start} ->
        case remaining_timeout(deadline_mono) do
          {:ok, _remaining_ms} ->
            Process.put(
              @active_key,
              {@owner_identity_tag, coordinator, self(), owner, owner_token, deadline_mono}
            )

            try do
              send(coordinator, {result_ref, {:callback_result, fun.()}})
            after
              Process.delete(@active_key)
            end

          {:error, :operation_timeout} ->
            send(coordinator, {result_ref, :deadline_expired})
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
         owner_token,
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
              owner_token,
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
              owner_token,
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
         owner_token,
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
          owner_token,
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
         owner_token,
         result_ref,
         deadline_mono,
         result_state
       ) do
    case remaining_timeout(deadline_mono) do
      {:ok, remaining_ms} ->
        receive do
          {:DOWN, ^owner_ref, :process, ^owner, _reason} ->
            terminate(worker, worker_ref, result_ref)

          {@owner_check_tag, ^owner_token, ^worker, ^owner, reply_alias}
          when is_reference(reply_alias) ->
            reply_owner_check(reply_alias, owner_token, owner, worker, deadline_mono)

            coordinate_worker(
              owner,
              owner_ref,
              response_ref,
              worker,
              worker_ref,
              owner_token,
              result_ref,
              deadline_mono,
              result_state
            )

          {^result_ref, result} when result_state == :pending ->
            coordinate_worker(
              owner,
              owner_ref,
              response_ref,
              worker,
              worker_ref,
              owner_token,
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
              owner_token,
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
              owner_token,
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
        {:normal, {:ready, :deadline_expired}, _deadline_state} ->
          {:error, :operation_timeout}

        {:normal, {:ready, {:callback_result, result}}, {:ok, _remaining_ms}} ->
          {:ok, result}

        {:normal, {:ready, {:callback_result, _result}}, {:error, :operation_timeout}} ->
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

  defp validate_owner_with_coordinator(
         coordinator,
         worker,
         owner,
         token,
         deadline_mono
       ) do
    case remaining_timeout(deadline_mono) do
      {:ok, remaining_ms} ->
        coordinator_ref = Process.monitor(coordinator)
        reply_alias = Process.alias()
        send(coordinator, {@owner_check_tag, token, worker, owner, reply_alias})

        receive do
          {@owner_check_reply_tag, ^token, :active} ->
            Process.unalias(reply_alias)
            Process.demonitor(coordinator_ref, [:flush])

            identity =
              {@owner_identity_tag, coordinator, worker, owner, token, deadline_mono}

            if owner_active?(identity, deadline_mono),
              do: :ok,
              else: {:error, :owner_inactive}

          {@owner_check_reply_tag, ^token, :inactive} ->
            Process.unalias(reply_alias)
            Process.demonitor(coordinator_ref, [:flush])
            {:error, :owner_inactive}

          {:DOWN, ^coordinator_ref, :process, ^coordinator, _reason} ->
            Process.unalias(reply_alias)
            drain_owner_check_reply(token)
            {:error, :owner_inactive}
        after
          remaining_ms ->
            Process.unalias(reply_alias)
            Process.demonitor(coordinator_ref, [:flush])
            drain_owner_check_reply(token)
            {:error, :owner_inactive}
        end

      {:error, :operation_timeout} ->
        {:error, :owner_inactive}
    end
  end

  defp reply_owner_check(reply_alias, token, owner, worker, deadline_mono) do
    status =
      if Process.alive?(owner) and Process.alive?(worker) and
           match?({:ok, _remaining_ms}, remaining_timeout(deadline_mono)),
         do: :active,
         else: :inactive

    send(reply_alias, {@owner_check_reply_tag, token, status})
  end

  defp drain_owner_check_reply(token) do
    receive do
      {@owner_check_reply_tag, ^token, _status} -> drain_owner_check_reply(token)
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
