defmodule Arbor.Signals.Store.CheckpointIO do
  @moduledoc false

  # Owner-bound coordinator + linked killable worker for privacy checkpoint I/O.
  #
  # BEAM monitor ownership is not transferable. A monitor ref created in the
  # coordinator delivers :DOWN only to the coordinator. The Store therefore:
  #   1. Owns coord_mon from spawn_monitor(coordinator)
  #   2. Receives owner_ready with worker PID only (never a foreign mon ref)
  #   3. Calls Process.monitor(worker) itself and retains that Store-owned ref
  #   4. ACKs {op_ref, :store_ready}; only then may coordinator release the gate
  #
  # Coordinator separately retains its own link+monitor on the worker for local
  # cleanup. Store dual-kill/drain awaits only Store-owned coord_mon and worker_mon.
  #
  # After a worker result, Store hard-kills the coordinator and awaits both
  # Store-owned DOWNs. Incomplete DOWN proofs never promote a worker success.

  @checkpoint_id "signal_store"

  @type op ::
          {:save_and_load, module(), term(), map()}
          | {:load, module(), term()}

  # Store-side bookkeeping — both monitor refs are created by the Store process.
  @type ready :: %{
          coordinator: pid(),
          coord_mon: reference(),
          worker: pid(),
          worker_mon: reference()
        }

  @spec run(op(), integer()) ::
          {:ok, term()}
          | {:error,
             :timeout
             | :failed
             | :malformed
             | :exit
             | :exception
             | :owner_lost
             | :dispatch_failed}
  def run(op, deadline_mono) when is_integer(deadline_mono) do
    case remaining_ms(deadline_mono) do
      {:error, :timeout} ->
        {:error, :timeout}

      {:ok, _ms} ->
        store_pid = self()
        op_ref = make_ref()
        start_gate = make_ref()

        # Store-owned coordinator monitor.
        {coord, coord_mon} =
          spawn_monitor(fn ->
            coordinate(store_pid, op_ref, start_gate, op, deadline_mono)
          end)

        await_owner_ready_and_arm(op_ref, coord, coord_mon, deadline_mono)
    end
  end

  defp coordinate(store_pid, op_ref, start_gate, op, deadline_mono) do
    Process.flag(:trap_exit, true)
    _store_mon = Process.monitor(store_pid)

    parent = self()

    # Coordinator-local link+monitor — not shared with Store.
    {worker, coord_worker_mon} =
      spawn_opt(
        fn ->
          receive do
            {^start_gate, :start} ->
              result = execute_op(op)
              send(parent, {:worker_result, self(), result})
          end
        end,
        [:link, :monitor]
      )

    # owner_ready: worker PID only. Never send coordinator's monitor ref.
    send(store_pid, {
      op_ref,
      :owner_ready,
      %{
        coordinator: self(),
        worker: worker
      }
    })

    case await_store_ready(store_pid, op_ref, worker, coord_worker_mon, deadline_mono) do
      :ready ->
        send(worker, {start_gate, :start})
        await_worker_and_owner(store_pid, op_ref, worker, coord_worker_mon, deadline_mono)

      :abort ->
        :ok
    end
  end

  defp await_store_ready(store_pid, op_ref, worker, coord_worker_mon, deadline_mono) do
    timeout = remaining_timeout_ms(deadline_mono)

    receive do
      {^op_ref, :store_ready} ->
        :ready

      {:DOWN, _mon, :process, ^store_pid, _reason} ->
        kill_and_drain_worker(worker, coord_worker_mon)
        :abort
    after
      timeout ->
        kill_and_drain_worker(worker, coord_worker_mon)

        if Process.alive?(store_pid) do
          send(store_pid, {op_ref, :result, {:error, :timeout}})
        end

        :abort
    end
  end

  defp execute_op({:save_and_load, module, store, snapshot}) do
    try do
      case module.save(@checkpoint_id, snapshot, store) do
        :ok ->
          case module.load(@checkpoint_id, store) do
            {:ok, loaded} when is_map(loaded) ->
              {:ok, {:loaded, loaded}}

            {:ok, _other} ->
              {:error, :malformed}

            {:error, _} ->
              {:error, :failed}

            _other ->
              {:error, :malformed}
          end

        {:error, _} ->
          {:error, :failed}

        _other ->
          {:error, :malformed}
      end
    rescue
      _ -> {:error, :exception}
    catch
      :exit, _ -> {:error, :exit}
      _, _ -> {:error, :exception}
    end
  end

  defp execute_op({:load, module, store}) do
    try do
      case module.load(@checkpoint_id, store) do
        {:ok, loaded} when is_map(loaded) ->
          {:ok, {:loaded, loaded}}

        {:ok, _other} ->
          {:error, :malformed}

        {:error, _} ->
          {:error, :failed}

        _other ->
          {:error, :malformed}
      end
    rescue
      _ -> {:error, :exception}
    catch
      :exit, _ -> {:error, :exit}
      _, _ -> {:error, :exception}
    end
  end

  # Coordinator-local await using coordinator-owned worker mon.
  defp await_worker_and_owner(store_pid, op_ref, worker, coord_worker_mon, deadline_mono) do
    timeout = remaining_timeout_ms(deadline_mono)

    receive do
      {:worker_result, ^worker, result} ->
        demonitor_flush(coord_worker_mon)
        drain_worker_exit(worker)
        send_result(store_pid, op_ref, normalize_worker_result(result))

      {:DOWN, ^coord_worker_mon, :process, ^worker, reason} ->
        case receive_worker_result_now(worker) do
          {:ok, result} ->
            drain_worker_exit(worker)
            send_result(store_pid, op_ref, normalize_worker_result(result))

          :none ->
            drain_worker_exit(worker)
            send_result(store_pid, op_ref, classify_worker_down(reason))
        end

      {:EXIT, ^worker, reason} ->
        demonitor_flush(coord_worker_mon)

        case receive_worker_result_now(worker) do
          {:ok, result} ->
            send_result(store_pid, op_ref, normalize_worker_result(result))

          :none ->
            send_result(store_pid, op_ref, classify_worker_down(reason))
        end

      {:DOWN, _mon, :process, ^store_pid, _reason} ->
        kill_and_drain_worker(worker, coord_worker_mon)
        :ok
    after
      timeout ->
        kill_and_drain_worker(worker, coord_worker_mon)
        send_result(store_pid, op_ref, {:error, :timeout})
    end
  end

  defp receive_worker_result_now(worker) do
    receive do
      {:worker_result, ^worker, result} -> {:ok, result}
    after
      0 -> :none
    end
  end

  defp drain_worker_exit(worker) do
    receive do
      {:EXIT, ^worker, _} -> :ok
    after
      0 -> :ok
    end
  end

  defp normalize_worker_result({:ok, _} = ok), do: ok

  defp normalize_worker_result({:error, reason})
       when reason in [:failed, :malformed, :exit, :exception],
       do: {:error, reason}

  defp normalize_worker_result(_), do: {:error, :malformed}

  defp classify_worker_down(:normal), do: {:error, :malformed}
  defp classify_worker_down(:kill), do: {:error, :exit}
  defp classify_worker_down(_), do: {:error, :exit}

  # Store path: owner_ready → Process.monitor(worker) → :store_ready → await result.
  defp await_owner_ready_and_arm(op_ref, coord, coord_mon, deadline_mono) do
    timeout = remaining_timeout_ms(deadline_mono)

    receive do
      {^op_ref, :owner_ready, %{worker: worker}} when is_pid(worker) ->
        # Store-owned worker monitor — never reuse coordinator's mon ref.
        worker_mon = Process.monitor(worker)

        ready = %{
          coordinator: coord,
          coord_mon: coord_mon,
          worker: worker,
          worker_mon: worker_mon
        }

        send(coord, {op_ref, :store_ready})
        await_result(op_ref, ready, deadline_mono)

      {^op_ref, :result, result} ->
        # Timeout/failure before arm completed — hard-kill coordinator, prove DOWN.
        case hard_kill_coord_only(coord, coord_mon) do
          :ok ->
            normalize_final(result)

          {:error, _} ->
            {:error, :exit}
        end

      {:DOWN, ^coord_mon, :process, ^coord, _reason} ->
        {:error, :dispatch_failed}
    after
      timeout ->
        _ = hard_kill_coord_only(coord, coord_mon)
        {:error, :timeout}
    end
  end

  defp await_result(op_ref, ready, deadline_mono) do
    %{
      coordinator: coord,
      coord_mon: coord_mon,
      worker: worker,
      worker_mon: worker_mon
    } = ready

    timeout = remaining_timeout_ms(deadline_mono)

    receive do
      {^op_ref, :result, result} ->
        settle_after_result(result, coord, coord_mon, worker, worker_mon)

      {:DOWN, ^coord_mon, :process, ^coord, _reason} ->
        case receive_result_now(op_ref) do
          {:ok, result} ->
            settle_after_result(result, coord, coord_mon, worker, worker_mon)

          :none ->
            _ = dual_kill_and_drain(coord, coord_mon, worker, worker_mon)
            {:error, :exit}
        end

      {:DOWN, ^worker_mon, :process, ^worker, _reason} ->
        await_after_worker_down(op_ref, ready, deadline_mono)
    after
      timeout ->
        _ = dual_kill_and_drain(coord, coord_mon, worker, worker_mon)
        {:error, :timeout}
    end
  end

  defp await_after_worker_down(op_ref, ready, deadline_mono) do
    %{coordinator: coord, coord_mon: coord_mon, worker: worker, worker_mon: worker_mon} = ready
    timeout = remaining_timeout_ms(deadline_mono)

    receive do
      {^op_ref, :result, result} ->
        settle_after_result(result, coord, coord_mon, worker, worker_mon)

      {:DOWN, ^coord_mon, :process, ^coord, _reason} ->
        case receive_result_now(op_ref) do
          {:ok, result} ->
            settle_after_result(result, coord, coord_mon, worker, worker_mon)

          :none ->
            _ = dual_kill_and_drain(coord, coord_mon, worker, worker_mon)
            {:error, :exit}
        end
    after
      timeout ->
        _ = dual_kill_and_drain(coord, coord_mon, worker, worker_mon)
        {:error, :timeout}
    end
  end

  # Never promote a worker success if Store-owned DOWN proofs fail.
  defp settle_after_result(result, coord, coord_mon, worker, worker_mon) do
    case ensure_pair_down(coord, coord_mon, worker, worker_mon) do
      :ok ->
        normalize_final(result)

      {:error, _down_proof_failed} ->
        {:error, :exit}
    end
  end

  defp receive_result_now(op_ref) do
    receive do
      {^op_ref, :result, result} -> {:ok, result}
    after
      0 -> :none
    end
  end

  defp normalize_final({:ok, value}), do: {:ok, value}
  defp normalize_final({:error, reason}), do: {:error, reason}
  defp normalize_final(_), do: {:error, :malformed}

  @doc false
  @spec dual_kill_and_drain(pid(), reference(), pid(), reference()) ::
          :ok | {:error, :worker_down_timeout | :coord_down_timeout}
  def dual_kill_and_drain(coord, coord_mon, worker, worker_mon)
      when is_pid(coord) and is_reference(coord_mon) and is_pid(worker) and
             is_reference(worker_mon) do
    if Process.alive?(worker), do: Process.exit(worker, :kill)
    if Process.alive?(coord), do: Process.exit(coord, :kill)

    # Both mon refs must be owned by the calling (Store) process.
    worker_ok = await_down(worker_mon, worker)
    coord_ok = await_down(coord_mon, coord)
    drain_op_messages()

    cond do
      not worker_ok -> {:error, :worker_down_timeout}
      not coord_ok -> {:error, :coord_down_timeout}
      true -> :ok
    end
  end

  # Prefer hard-kill of coordinator after its result, then await both own mons.
  defp ensure_pair_down(coord, coord_mon, worker, worker_mon) do
    if Process.alive?(worker), do: Process.exit(worker, :kill)
    if Process.alive?(coord), do: Process.exit(coord, :kill)

    worker_ok = await_down(worker_mon, worker)
    coord_ok = await_down(coord_mon, coord)
    drain_op_messages()

    cond do
      not worker_ok -> {:error, :worker_down_timeout}
      not coord_ok -> {:error, :coord_down_timeout}
      true -> :ok
    end
  end

  defp hard_kill_coord_only(coord, coord_mon) do
    if Process.alive?(coord), do: Process.exit(coord, :kill)

    if await_down(coord_mon, coord) do
      drain_op_messages()
      :ok
    else
      drain_op_messages()
      {:error, :coord_down_timeout}
    end
  end

  # Coordinator-local: mon is coordinator-owned.
  defp kill_and_drain_worker(worker, coord_worker_mon) do
    if Process.alive?(worker), do: Process.exit(worker, :kill)
    _ = await_down(coord_worker_mon, worker)
  end

  # Returns true only if this process receives the exact mon's :DOWN.
  # A foreign (coordinator-created) mon never delivers here → false after timeout.
  # Do not treat process-death alone as success; that would mask wrong mon ownership.
  defp await_down(mon, pid) when is_reference(mon) and is_pid(pid) do
    receive do
      {:DOWN, ^mon, :process, ^pid, _reason} -> true
    after
      1_000 ->
        demonitor_flush(mon)
        false
    end
  end

  defp demonitor_flush(mon) do
    Process.demonitor(mon, [:flush])
  rescue
    _ -> :ok
  end

  defp send_result(store_pid, op_ref, result) do
    if Process.alive?(store_pid) do
      send(store_pid, {op_ref, :result, result})
    end

    :ok
  end

  defp drain_op_messages do
    receive do
      {_ref, :owner_ready, _} -> drain_op_messages()
      {_ref, :store_ready} -> drain_op_messages()
      {_ref, :ownership_armed} -> drain_op_messages()
      {_ref, :result, _} -> drain_op_messages()
      {:worker_result, _, _} -> drain_op_messages()
    after
      0 -> :ok
    end
  end

  @spec remaining_ms(integer()) :: {:ok, non_neg_integer()} | {:error, :timeout}
  def remaining_ms(deadline_mono) when is_integer(deadline_mono) do
    remaining = deadline_mono - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :timeout}
    else
      {:ok, remaining}
    end
  end

  defp remaining_timeout_ms(deadline_mono) do
    case remaining_ms(deadline_mono) do
      {:ok, ms} -> ms
      {:error, :timeout} -> 0
    end
  end
end
