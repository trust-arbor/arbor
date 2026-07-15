defmodule Arbor.Shell.AppleContainerUnitDrainCoordinator do
  @moduledoc false

  # Permanent rest_for_one sibling placed after AppleContainerUnitSupervisor.
  #
  # OTP turns a supervised GenServer's parent EXIT into terminate/2; unit
  # workers therefore cannot coordinate cleanup from handle_info({:EXIT,...}).
  # This coordinator is shut down first under reverse rest_for_one order and
  # uses each worker's explicit request_drain protocol while UnitSupervisor and
  # PortSessionSupervisor are still alive. It blocks without a finite cleanup
  # budget until every accepted drain yields an exact positive-absence receipt.
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

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    {:ok, %{}}
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
    workers = snapshot_live_workers()

    if workers == [] do
      :ok
    else
      pending =
        Enum.reduce(workers, %{}, fn worker, acc ->
          receipt_ref = make_ref()
          _ = Process.monitor(worker)

          case request_drain_handshake(worker, receipt_ref) do
            :ok ->
              Map.put(acc, receipt_ref, worker)

            _other ->
              # Only :ok handshakes are pending exact absence receipts.
              acc
          end
        end)

      await_drain_receipts(pending)
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

  defp request_drain_handshake(worker, receipt_ref) do
    Worker.request_drain(worker, receipt_ref, @drain_handshake_timeout_ms)
  catch
    :exit, _reason ->
      {:error, :drain_handshake_failed}
  end

  defp await_drain_receipts(pending) when map_size(pending) == 0, do: :ok

  defp await_drain_receipts(pending) do
    receive do
      {:apple_container_unit_drained, worker_pid, execution_id, receipt_ref}
      when is_pid(worker_pid) and is_reference(receipt_ref) ->
        case Map.fetch(pending, receipt_ref) do
          {:ok, ^worker_pid} ->
            if valid_execution_id?(execution_id) do
              await_drain_receipts(Map.delete(pending, receipt_ref))
            else
              # Nonempty bounded execution_id required — ignore malformed.
              await_drain_receipts(pending)
            end

          _mismatch ->
            # Wrong worker, unknown/stale ref, or already settled.
            await_drain_receipts(pending)
        end

      {:DOWN, _ref, :process, _pid, _reason} ->
        # Worker death without an exact drain receipt is NOT success. Keep
        # waiting so supervised shutdown cannot proceed past incomplete drain.
        await_drain_receipts(pending)

      _unrelated ->
        await_drain_receipts(pending)
    end
  end

  defp valid_execution_id?(id)
       when is_binary(id) and byte_size(id) > 0 and byte_size(id) <= @max_execution_id_bytes do
    String.valid?(id)
  end

  defp valid_execution_id?(_), do: false
end
