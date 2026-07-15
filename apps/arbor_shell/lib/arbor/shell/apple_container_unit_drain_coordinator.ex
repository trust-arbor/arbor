defmodule Arbor.Shell.AppleContainerUnitDrainCoordinator do
  @moduledoc false

  # Permanent rest_for_one sibling placed after AppleContainerUnitSupervisor.
  #
  # OTP turns a supervised GenServer's parent EXIT into terminate/2; unit
  # workers therefore cannot coordinate cleanup from handle_info({:EXIT,...}).
  # This coordinator is shut down first under reverse rest_for_one order and
  # uses each worker's explicit request_drain protocol while UnitSupervisor and
  # PortSessionSupervisor are still alive. It blocks without a finite cleanup
  # budget until every snapshotted live worker yields an exact positive-absence
  # receipt.
  #
  # Production unit starts also linearize through this process: a successful
  # GenServer start reply completes before supervised terminate/2 begins, so
  # every admitted worker is present in the unit supervisor before the drain
  # snapshot. Calls arriving once terminate starts are not serviced and cannot
  # create a late worker.
  #
  # Handshake attempts are bounded, but a timeout/error/exit never settles or
  # drops a worker: the coordinator retries acceptance until :ok, then waits
  # for the exact drain receipt. Worker DOWN before receipt is never success.
  #
  # Carries no caller authority and no configurable module callback. Does not
  # terminate UnitSupervisor or PortSessionSupervisor.

  use GenServer

  alias Arbor.Shell.AppleContainerUnitWorker, as: Worker

  @name __MODULE__
  @unit_supervisor Arbor.Shell.AppleContainerUnitSupervisor
  # Handshake only — acceptance of request_drain, not absence proof.
  @drain_handshake_timeout_ms 5_000
  @max_execution_id_bytes 256
  # Bounded production start admission call (not absence proof).
  @start_unit_timeout_ms 5_000

  @doc false
  @spec start_link(term()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc false
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_opts) do
    %{
      id: @name,
      start: {__MODULE__, :start_link, [[]]},
      type: :worker,
      restart: :permanent,
      shutdown: :infinity
    }
  end

  @doc false
  @spec start_unit(map(), term(), String.t(), reference()) ::
          {:ok, pid()} | {:error, term()}
  def start_unit(spec, executable, execution_id, start_ref)
      when is_map(spec) and is_binary(execution_id) and is_reference(start_ref) do
    GenServer.call(
      @name,
      {:start_unit, spec, executable, execution_id, start_ref},
      @start_unit_timeout_ms
    )
  catch
    :exit, _reason ->
      {:error, :unit_start_unavailable}
  end

  def start_unit(_spec, _executable, _execution_id, _start_ref),
    do: {:error, :invalid_unit_start}

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    {:ok, %{}}
  end

  @impl true
  def handle_call(
        {:start_unit, spec, executable, execution_id, start_ref},
        {controller_pid, _tag},
        state
      )
      when is_pid(controller_pid) and is_map(spec) and is_binary(execution_id) and
             is_reference(start_ref) do
    # Derive original controller only from the GenServer from tuple.
    reply =
      Worker.start_under_coordinator(
        spec,
        executable,
        execution_id,
        start_ref,
        controller_pid
      )

    {:reply, reply, state}
  end

  def handle_call({:start_unit, _spec, _executable, _execution_id, _start_ref}, _from, state) do
    {:reply, {:error, :invalid_unit_start}, state}
  end

  def handle_call(_request, _from, state) do
    {:reply, {:error, :unsupported_call}, state}
  end

  @impl true
  def terminate(_reason, _state) do
    drain_live_workers()
    :ok
  end

  @impl true
  def format_status(status) when is_map(status) do
    status
    |> Map.put(:message, :redacted)
    |> Map.put(:reason, :redacted)
    |> Map.put(:log, :redacted)
    |> Map.put(:state, :redacted)
  end

  def format_status(status), do: status

  # ---------------------------------------------------------------------------
  # Drain
  # ---------------------------------------------------------------------------

  defp drain_live_workers do
    case snapshot_live_workers() do
      [] ->
        :ok

      workers ->
        pending =
          Map.new(workers, fn worker ->
            _ = Process.monitor(worker)

            {worker,
             %{
               receipt_ref: make_ref(),
               accepted: false
             }}
          end)

        drain_until_resolved(pending)
    end
  end

  defp snapshot_live_workers do
    case Process.whereis(@unit_supervisor) do
      pid when is_pid(pid) ->
        @unit_supervisor
        |> DynamicSupervisor.which_children()
        |> Enum.flat_map(fn
          {_id, child, _type, _modules} when is_pid(child) ->
            if Process.alive?(child), do: [child], else: []

          _other ->
            []
        end)

      _missing ->
        []
    end
  end

  # Every snapshotted worker stays unresolved until its exact drain receipt.
  # Bounded handshakes may fail; failures never settle or drop the worker.
  defp drain_until_resolved(pending) when map_size(pending) == 0, do: :ok

  defp drain_until_resolved(pending) do
    pending = attempt_handshakes(pending)

    if map_size(pending) == 0 do
      :ok
    else
      # While any handshake is outstanding, re-enter promptly after each
      # bounded attempt. Once every worker has accepted, wait indefinitely
      # for exact receipts (no teardown deadline).
      wait_ms = if any_unaccepted?(pending), do: 0, else: :infinity

      receive do
        {:apple_container_unit_drained, worker_pid, execution_id, receipt_ref}
        when is_pid(worker_pid) and is_reference(receipt_ref) ->
          drain_until_resolved(settle_if_exact(pending, worker_pid, execution_id, receipt_ref))

        {:DOWN, _ref, :process, _pid, _reason} ->
          # Worker death without an exact drain receipt is NOT success.
          drain_until_resolved(pending)

        _unrelated ->
          drain_until_resolved(pending)
      after
        wait_ms ->
          drain_until_resolved(pending)
      end
    end
  end

  defp attempt_handshakes(pending) do
    Enum.reduce(pending, %{}, fn {worker, meta}, acc ->
      if meta.accepted do
        Map.put(acc, worker, meta)
      else
        case request_drain_handshake(worker, meta.receipt_ref) do
          :ok ->
            Map.put(acc, worker, %{meta | accepted: true})

          _other ->
            # Timeout, exit, noproc, or error — keep unresolved and retry.
            # Brief yield only avoids a tight noproc spin; it is not a teardown
            # deadline and never settles the worker.
            Process.sleep(50)
            Map.put(acc, worker, meta)
        end
      end
    end)
  end

  defp any_unaccepted?(pending) do
    Enum.any?(pending, fn {_worker, meta} -> meta.accepted == false end)
  end

  defp request_drain_handshake(worker, receipt_ref) do
    Worker.request_drain(worker, receipt_ref, @drain_handshake_timeout_ms)
  catch
    :exit, _reason ->
      {:error, :drain_handshake_failed}
  end

  defp settle_if_exact(pending, worker_pid, execution_id, receipt_ref) do
    case Map.get(pending, worker_pid) do
      %{receipt_ref: ^receipt_ref} ->
        # Exact worker + receipt_ref. A timed-out :ok reply may have been
        # discarded while the worker still accepted and later emitted this
        # receipt — settle only on valid execution_id proof.
        if valid_execution_id?(execution_id) do
          Map.delete(pending, worker_pid)
        else
          pending
        end

      _mismatch ->
        # Unknown/stale ref, wrong worker, or already settled.
        pending
    end
  end

  defp valid_execution_id?(id)
       when is_binary(id) and byte_size(id) > 0 and byte_size(id) <= @max_execution_id_bytes do
    String.valid?(id)
  end

  defp valid_execution_id?(_), do: false
end
