defmodule Arbor.Multimedia.DeviceOwner do
  @moduledoc false
  use GenServer
  alias Arbor.Multimedia.{Driver, DriverWorker, Fence, OperationCore, Redacted}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Fence.init()

    {:ok,
     %{
       operation: nil,
       driver: Application.get_env(:arbor_multimedia, :driver, Driver.Unavailable)
     }}
  end

  @impl true
  def handle_call({:run, request, %Redacted{value: spec}, deadline}, {caller, _} = from, state) do
    cond do
      state.operation != nil or Fence.current() != nil ->
        {:reply, {:error, :device_busy}, state}

      not is_integer(deadline) or deadline <= now_ms() or not Process.alive?(caller) ->
        {:reply, {:error, :timeout}, state}

      true ->
        admit(state, request, spec, deadline, from)
    end
  end

  def handle_call(_, _from, state), do: {:reply, {:error, :invalid_options}, state}

  @impl true
  def handle_info(
        {:driver, token, %Redacted{value: event}},
        %{operation: %{token: token} = op} = state
      ) do
    if now_ms() >= op.deadline and op.from != nil do
      state = expire(state)
      apply_event(state, event)
    else
      apply_event(state, event)
    end
  end

  def handle_info({:deadline, token}, %{operation: %{token: token}} = state),
    do: {:noreply, expire(state)}

  def handle_info(
        {:cancel, request, caller},
        %{operation: %{request: request, caller: caller}} = state
      ),
      do: {:noreply, expire(state)}

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{operation: %{caller_ref: ref}} = state
      ),
      do: {:noreply, cancel(state, :caller_down)}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{operation: %{worker_ref: ref}} = state) do
    # Death is not positive close. The persistent fence survives even if this
    # coordinating process is later restarted; never create a replacement stream.
    {:noreply, state |> cancel(:driver_failed) |> reply_pending()}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def format_status(status) do
    status
    |> Map.put(:state, :redacted)
    |> Map.put(:message, :redacted)
    |> Map.put(:reason, :redacted)
    |> Map.put(:log, [])
  end

  defp admit(state, request, spec, deadline, from) do
    fence_id = System.unique_integer([:positive, :monotonic])
    token = make_ref()
    active = :atomics.new(1, [])
    :atomics.put(active, 1, 1)
    permit = %{active: active, deadline: deadline, owner: self(), caller: elem(from, 0)}

    with :ok <- Fence.acquire(fence_id) do
      start_worker(state, request, spec, deadline, from, token, fence_id, permit)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp start_worker(state, request, spec, deadline, from, token, fence_id, permit) do
    case DynamicSupervisor.start_child(
           Arbor.Multimedia.DriverSupervisor,
           {DriverWorker, Redacted.new({state.driver, self(), token, fence_id, permit})}
         ) do
      {:ok, worker} ->
        op = %{
          token: token,
          fence_id: fence_id,
          permit: permit,
          request: request,
          from: from,
          caller: elem(from, 0),
          caller_ref: Process.monitor(elem(from, 0)),
          worker: worker,
          worker_ref: Process.monitor(worker),
          core: OperationCore.new(spec),
          deadline: deadline,
          timer: Process.send_after(self(), {:deadline, token}, max(0, deadline - now_ms()))
        }

        send(worker, {:open, token, Redacted.new(spec)})
        {:noreply, %{state | operation: op}}

      {:error, _} ->
        # DriverWorker.init performs no native work, so failure before its open
        # handoff has no resource to exhaust.
        Fence.release(fence_id)
        {:reply, {:error, :device_unavailable}, state}
    end
  end

  defp apply_event(%{operation: op} = state, event) do
    {core, effects} = OperationCore.event(op.core, event, DateTime.utc_now())
    {:noreply, perform(%{state | operation: %{op | core: core}}, effects)}
  end

  defp perform(state, []), do: state

  defp perform(%{operation: op} = state, [:close | effects]) do
    :atomics.put(op.permit.active, 1, 0)
    send(op.worker, {:close, op.token})
    perform(state, effects)
  end

  defp perform(%{operation: op} = state, [:settle | _]) do
    Process.cancel_timer(op.timer)
    Process.demonitor(op.caller_ref, [:flush])
    Process.demonitor(op.worker_ref, [:flush])
    Fence.release(op.fence_id)
    if op.from, do: GenServer.reply(op.from, op.core.result)
    %{state | operation: nil}
  end

  defp expire(state), do: state |> cancel(:timeout) |> reply_pending()

  defp cancel(%{operation: op} = state, reason) do
    :atomics.put(op.permit.active, 1, 0)
    {core, effects} = OperationCore.cancel(op.core, reason)
    perform(%{state | operation: %{op | core: core}}, effects)
  end

  defp reply_pending(%{operation: op} = state) do
    if op.from, do: GenServer.reply(op.from, {:error, :cleanup_pending})
    %{state | operation: %{op | from: nil}}
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
