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
  # D_work is computed once at run/2 entry (cleanup reserve inside D_outer) and
  # threaded unchanged. Results are admissible only after both Store-owned DOWN
  # receipts converge. Pre-arm results are never admitted.

  alias Arbor.Signals.Store.CheckpointIO.ReceiptCore

  @checkpoint_id "signal_store"

  @type op ::
          {:save_and_load, module(), term(), map()}
          | {:load, module(), term()}

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
  def run(op, d_outer) when is_integer(d_outer) do
    now = System.monotonic_time(:millisecond)

    case ReceiptCore.split_deadlines(d_outer, now) do
      {:error, :timeout} ->
        {:error, :timeout}

      {:ok, d_work, d_outer} ->
        store_pid = self()
        op_ref = make_ref()
        start_gate = make_ref()

        {coord, coord_mon} =
          spawn_monitor(fn ->
            coordinate(store_pid, op_ref, start_gate, op, d_work, d_outer)
          end)

        receipt = ReceiptCore.new(op_ref, d_work, d_outer, coord, coord_mon)
        store_loop(receipt)
    end
  end

  # ---------------------------------------------------------------------------
  # Coordinator (helper process)
  # ---------------------------------------------------------------------------

  defp coordinate(store_pid, op_ref, start_gate, op, d_work, d_outer) do
    Process.flag(:trap_exit, true)
    # Coordinator-owned Store monitor — must be pinned in every Store-death receive.
    store_mon = Process.monitor(store_pid)

    parent = self()

    {worker, coord_worker_mon} =
      :erlang.spawn_opt(
        fn ->
          receive do
            {^start_gate, :start} ->
              result = execute_op(op)
              send(parent, {:worker_result, self(), result})
          end
        end,
        [:link, :monitor]
      )

    send(store_pid, {
      op_ref,
      :owner_ready,
      %{
        coordinator: self(),
        worker: worker
      }
    })

    case await_store_ready(
           store_pid,
           store_mon,
           op_ref,
           worker,
           coord_worker_mon,
           d_work,
           d_outer
         ) do
      :ready ->
        send(worker, {start_gate, :start})

        await_worker_and_owner(
          store_pid,
          store_mon,
          op_ref,
          worker,
          coord_worker_mon,
          d_work,
          d_outer
        )

      :abort ->
        :ok
    end
  end

  defp await_store_ready(
         store_pid,
         store_mon,
         op_ref,
         worker,
         coord_worker_mon,
         d_work,
         d_outer
       ) do
    timeout = remaining_timeout_ms(d_work)

    receive do
      {^op_ref, :store_ready} ->
        :ready

      {:DOWN, ^store_mon, :process, ^store_pid, _reason} ->
        kill_and_drain_worker(worker, coord_worker_mon, d_outer)
        :abort
    after
      timeout ->
        kill_and_drain_worker(worker, coord_worker_mon, d_outer)

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

  defp await_worker_and_owner(
         store_pid,
         store_mon,
         op_ref,
         worker,
         coord_worker_mon,
         d_work,
         d_outer
       ) do
    timeout = remaining_timeout_ms(d_work)

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

      {:DOWN, ^store_mon, :process, ^store_pid, _reason} ->
        kill_and_drain_worker(worker, coord_worker_mon, d_outer)
        :ok
    after
      timeout ->
        kill_and_drain_worker(worker, coord_worker_mon, d_outer)
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

  # ---------------------------------------------------------------------------
  # Store-side receipt shell
  # ---------------------------------------------------------------------------

  defp store_loop(receipt) do
    case receipt.phase do
      :closed ->
        extract_outcome(receipt)

      :settling ->
        settle_loop(receipt)

      phase when phase in [:arming, :running] ->
        work_loop(receipt)
    end
  end

  defp work_loop(receipt) do
    %{
      op_ref: op_ref,
      d_work: d_work,
      coordinator: coord,
      coord_mon: coord_mon,
      worker: worker,
      worker_mon: worker_mon
    } = receipt

    timeout = remaining_timeout_ms(d_work)

    receive do
      {^op_ref, :owner_ready, %{worker: w}} when is_pid(w) ->
        handle_decision(ReceiptCore.apply_event(receipt, {:owner_ready, w}))

      {^op_ref, :result, result} ->
        handle_decision(ReceiptCore.apply_event(receipt, {:result, result}))

      {:DOWN, ^coord_mon, :process, ^coord, _reason} ->
        # Coord DOWN may race a result already in the mailbox — peek first.
        receipt =
          case receive_result_now(op_ref) do
            {:ok, result} ->
              {receipt, _dec} = ReceiptCore.apply_event(receipt, {:result, result})
              receipt

            :none ->
              receipt
          end

        handle_decision(ReceiptCore.apply_event(receipt, {:coord_down, coord_mon}))

      {:DOWN, mon, :process, pid, _reason}
      when is_reference(worker_mon) and mon == worker_mon and is_pid(worker) and pid == worker ->
        handle_decision(ReceiptCore.apply_event(receipt, {:worker_down, worker_mon}))
    after
      timeout ->
        handle_decision(ReceiptCore.apply_event(receipt, :work_timeout))
    end
  end

  defp receive_result_now(op_ref) do
    receive do
      {^op_ref, :result, result} -> {:ok, result}
    after
      0 -> :none
    end
  end

  defp handle_decision({receipt, decision}) do
    case decision do
      {:done, outcome} ->
        flush_unseen_mons(receipt)
        drain_op_messages(receipt.op_ref)
        outcome

      {:arm_worker, worker} ->
        worker_mon = Process.monitor(worker)
        receipt = ReceiptCore.arm_worker(receipt, worker, worker_mon)
        send(receipt.coordinator, {receipt.op_ref, :store_ready})
        store_loop(receipt)

      {:reject_pre_arm_result, :dispatch_failed} ->
        reject_pre_arm(receipt)

      :settle_kill_both ->
        settle_loop(receipt)

      {:fail_closed_no_result, :exit} ->
        fail_closed_no_result(receipt)

      :timeout_teardown ->
        timeout_teardown(receipt)

      :continue ->
        store_loop(receipt)

      :ignore ->
        store_loop(receipt)
    end
  end

  defp reject_pre_arm(receipt) do
    # Never admit pre-arm result. Kill coord; optional orphan cleanup if owner_ready
    # is already queued; return closed dispatch/exit only.
    %{coordinator: coord, coord_mon: coord_mon, op_ref: op_ref, d_outer: d_outer} = receipt

    if Process.alive?(coord), do: Process.exit(coord, :kill)

    receipt =
      case await_exact_down(coord_mon, coord, d_outer) do
        true ->
          %{receipt | coord_down: true}

        false ->
          demonitor_flush(coord_mon)
          receipt
      end

    # Op-scoped drain may reveal a late owner_ready — kill that worker for no orphan.
    receipt = maybe_cleanup_stray_worker(receipt)

    reason = if receipt.coord_down, do: :dispatch_failed, else: :exit
    {receipt, {:done, outcome}} = ReceiptCore.complete_pre_arm_reject(receipt, reason)
    flush_unseen_mons(receipt)
    drain_op_messages(op_ref)
    outcome
  end

  defp maybe_cleanup_stray_worker(receipt) do
    %{op_ref: op_ref, d_outer: d_outer} = receipt

    receive do
      {^op_ref, :owner_ready, %{worker: worker}} when is_pid(worker) ->
        mon = Process.monitor(worker)
        if Process.alive?(worker), do: Process.exit(worker, :kill)
        _ = await_exact_down(mon, worker, d_outer)
        demonitor_flush(mon)
        receipt
    after
      0 ->
        receipt
    end
  end

  defp fail_closed_no_result(receipt) do
    receipt = hard_kill_helpers(receipt)
    receipt = await_unseen_downs(receipt)

    {receipt, {:done, outcome}} = ReceiptCore.complete_fail_closed(receipt, :exit)
    flush_unseen_mons(receipt)
    drain_op_messages(receipt.op_ref)
    outcome
  end

  defp timeout_teardown(receipt) do
    receipt = hard_kill_helpers(receipt)
    receipt = await_unseen_downs(receipt)
    {receipt, {:done, outcome}} = ReceiptCore.apply_event(receipt, :timeout_teardown_complete)
    flush_unseen_mons(receipt)
    drain_op_messages(receipt.op_ref)
    outcome
  end

  defp settle_loop(receipt) do
    receipt = hard_kill_helpers(receipt)

    if ReceiptCore.both_down?(receipt) and match?({:some, _}, receipt.result) do
      {:some, term} = receipt.result
      flush_unseen_mons(receipt)
      drain_op_messages(receipt.op_ref)
      ReceiptCore.normalize_final(term)
    else
      case await_unseen_downs_step(receipt) do
        {:done, receipt} ->
          if ReceiptCore.both_down?(receipt) and match?({:some, _}, receipt.result) do
            {:some, term} = receipt.result
            flush_unseen_mons(receipt)
            drain_op_messages(receipt.op_ref)
            ReceiptCore.normalize_final(term)
          else
            {receipt, {:done, outcome}} =
              ReceiptCore.apply_event(receipt, :quiescence_failed)

            flush_unseen_mons(receipt)
            drain_op_messages(receipt.op_ref)
            outcome
          end

        {:continue, receipt} ->
          # Still waiting — loop with residual outer budget
          settle_loop_wait(receipt)
      end
    end
  end

  defp settle_loop_wait(receipt) do
    %{
      op_ref: op_ref,
      d_outer: d_outer,
      coordinator: coord,
      coord_mon: coord_mon,
      worker: worker,
      worker_mon: worker_mon
    } = receipt

    timeout = remaining_timeout_ms(d_outer)

    receive do
      {:DOWN, ^coord_mon, :process, ^coord, _reason} ->
        receipt = %{receipt | coord_down: true}
        settle_loop(receipt)

      {:DOWN, mon, :process, pid, _reason}
      when is_reference(worker_mon) and mon == worker_mon and is_pid(worker) and pid == worker ->
        receipt = %{receipt | worker_down: true}
        settle_loop(receipt)

      {^op_ref, :result, _} ->
        # Already holding result; drain only.
        settle_loop(receipt)

      {^op_ref, :owner_ready, _} ->
        settle_loop(receipt)
    after
      timeout ->
        {receipt, {:done, outcome}} = ReceiptCore.apply_event(receipt, :quiescence_failed)
        flush_unseen_mons(receipt)
        drain_op_messages(op_ref)
        outcome
    end
  end

  defp hard_kill_helpers(receipt) do
    %{coordinator: coord, worker: worker} = receipt

    if is_pid(worker) and Process.alive?(worker), do: Process.exit(worker, :kill)
    if is_pid(coord) and Process.alive?(coord), do: Process.exit(coord, :kill)

    receipt
  end

  defp await_unseen_downs(receipt) do
    case await_unseen_downs_step(receipt) do
      {:done, receipt} -> receipt
      {:continue, receipt} -> await_unseen_downs_wait(receipt)
    end
  end

  defp await_unseen_downs_step(receipt) do
    # Non-blocking drain of already-queued exact DOWNs.
    receipt = drain_exact_downs_now(receipt)

    if unseen_complete?(receipt) do
      {:done, receipt}
    else
      {:continue, receipt}
    end
  end

  defp await_unseen_downs_wait(receipt) do
    %{
      d_outer: d_outer,
      coordinator: coord,
      coord_mon: coord_mon,
      worker: worker,
      worker_mon: worker_mon,
      op_ref: op_ref
    } = receipt

    timeout = remaining_timeout_ms(d_outer)

    receive do
      {:DOWN, ^coord_mon, :process, ^coord, _reason} ->
        await_unseen_downs(%{receipt | coord_down: true})

      {:DOWN, mon, :process, pid, _reason}
      when is_reference(worker_mon) and mon == worker_mon and is_pid(worker) and pid == worker ->
        await_unseen_downs(%{receipt | worker_down: true})

      {^op_ref, :result, _} ->
        await_unseen_downs(receipt)

      {^op_ref, :owner_ready, _} ->
        await_unseen_downs(receipt)
    after
      timeout ->
        receipt
    end
  end

  defp drain_exact_downs_now(receipt) do
    %{
      coordinator: coord,
      coord_mon: coord_mon,
      worker: worker,
      worker_mon: worker_mon
    } = receipt

    receipt =
      if ReceiptCore.needs_coord_down?(receipt) do
        receive do
          {:DOWN, ^coord_mon, :process, ^coord, _} -> %{receipt | coord_down: true}
        after
          0 -> receipt
        end
      else
        receipt
      end

    if ReceiptCore.needs_worker_down?(receipt) and is_pid(worker) do
      receive do
        {:DOWN, ^worker_mon, :process, ^worker, _} -> %{receipt | worker_down: true}
      after
        0 -> receipt
      end
    else
      receipt
    end
  end

  defp unseen_complete?(receipt) do
    coord_ok = not ReceiptCore.needs_coord_down?(receipt)
    worker_ok = not ReceiptCore.needs_worker_down?(receipt)
    coord_ok and worker_ok
  end

  defp await_exact_down(mon, pid, deadline) when is_reference(mon) and is_pid(pid) do
    timeout = remaining_timeout_ms(deadline)

    receive do
      {:DOWN, ^mon, :process, ^pid, _reason} -> true
    after
      timeout ->
        false
    end
  end

  defp flush_unseen_mons(receipt) do
    if ReceiptCore.needs_coord_down?(receipt), do: demonitor_flush(receipt.coord_mon)

    if ReceiptCore.needs_worker_down?(receipt), do: demonitor_flush(receipt.worker_mon)

    :ok
  end

  defp extract_outcome(%{outcome: {:done, outcome}}), do: outcome
  defp extract_outcome(_), do: {:error, :exit}

  defp send_result(store_pid, op_ref, result) do
    if Process.alive?(store_pid) do
      send(store_pid, {op_ref, :result, result})
    end

    :ok
  end

  # Coordinator-local: mon is coordinator-owned; deadline is absolute.
  defp kill_and_drain_worker(worker, coord_worker_mon, deadline) do
    if Process.alive?(worker), do: Process.exit(worker, :kill)

    if await_exact_down(coord_worker_mon, worker, deadline) do
      :ok
    else
      demonitor_flush(coord_worker_mon)
      :ok
    end
  end

  defp demonitor_flush(mon) when is_reference(mon) do
    Process.demonitor(mon, [:flush])
  rescue
    _ -> :ok
  end

  defp demonitor_flush(_), do: :ok

  # Op-scoped only — never wildcard other refs.
  defp drain_op_messages(op_ref) when is_reference(op_ref) do
    receive do
      {^op_ref, :owner_ready, _} -> drain_op_messages(op_ref)
      {^op_ref, :store_ready} -> drain_op_messages(op_ref)
      {^op_ref, :result, _} -> drain_op_messages(op_ref)
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
