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
  def handle_call(:device_status, _from, state) do
    status =
      cond do
        state.operation == nil and Fence.current() == nil -> :idle
        state.operation == nil -> :cleanup_pending
        state.operation.core.cancelled or state.operation.from == nil -> :cleanup_pending
        true -> :busy
      end

    {:reply, status, state}
  end

  def handle_call({:run, request, %Redacted{} = spec, deadline}, from, state),
    do: handle_call({:run, request, spec, deadline, Redacted.new(nil)}, from, state)

  def handle_call(
        {:run, request, %Redacted{value: spec}, deadline, %Redacted{value: controller}},
        {caller, _} = from,
        state
      ) do
    cond do
      state.operation != nil or Fence.current() != nil ->
        {:reply, {:error, :device_busy}, state}

      not is_integer(deadline) or deadline <= now_ms() or not Process.alive?(caller) ->
        {:reply, {:error, :timeout}, state}

      controller != nil and not valid_controller?(controller) ->
        {:reply, {:error, :invalid_options}, state}

      controller != nil and not Driver.manual_finish_supported?(state.driver) ->
        {:reply, {:error, :finish_unavailable}, state}

      true ->
        admit(state, request, spec, deadline, from, controller)
    end
  end

  def handle_call(
        {:finish_capture, %Redacted{value: control}},
        {controller, _},
        %{operation: %{controller: controller, control: control} = op} = state
      )
      when is_binary(control) and byte_size(control) == 32 do
    cond do
      op.core.cancelled or op.from == nil or not Process.alive?(controller) ->
        {:reply, {:error, :finish_unavailable}, state}

      now_ms() >= op.deadline ->
        {:reply, {:error, :finish_unavailable}, expire(state)}

      true ->
        {core, effects} = OperationCore.finish(op.core)
        {:reply, :ok, perform(%{state | operation: %{op | core: core}}, effects)}
    end
  end

  def handle_call({:finish_capture, _}, _, state),
    do: {:reply, {:error, :invalid_control}, state}

  def handle_call(_, _from, state), do: {:reply, {:error, :invalid_options}, state}

  @impl true
  def handle_info(
        {:driver_custody_register, token, worker, fence_id, session, secret},
        %{operation: %{token: token, worker: worker, fence_id: fence_id, custody: nil} = op} =
          state
      )
      when is_pid(session) and is_binary(secret) and byte_size(secret) == 32 do
    send(self(), {:ack_native_custody, token, worker, fence_id, session, secret})
    {:noreply, %{state | operation: %{op | custody: {session, secret}}}}
  end

  def handle_info(
        {:ack_native_custody, token, worker, fence_id, session, secret},
        %{
          operation: %{
            token: token,
            worker: worker,
            fence_id: fence_id,
            custody: {session, secret}
          }
        } = state
      ) do
    send(session, {:native_custody_ack, secret, self(), worker, fence_id})
    {:noreply, state}
  end

  def handle_info(
        {:driver_custody_closed, token, worker, fence_id, session, secret},
        %{
          operation: %{
            token: token,
            worker: worker,
            fence_id: fence_id,
            custody: {session, secret}
          }
        } = state
      ),
      do: apply_event(state, {:closed, :ok})

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

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{operation: %{controller_ref: ref}} = state
      )
      when is_reference(ref),
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

  defp admit(state, request, spec, deadline, from, controller) do
    fence_id = System.unique_integer([:positive, :monotonic])
    token = make_ref()
    revoked = :atomics.new(1, [])
    permit = %{revoked: revoked, deadline: deadline, owner: self(), caller: elem(from, 0)}

    with :ok <- Fence.acquire(fence_id) do
      start_worker(state, request, spec, deadline, from, token, fence_id, permit, controller)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp start_worker(state, request, spec, deadline, from, token, fence_id, permit, controller) do
    case DynamicSupervisor.start_child(
           Arbor.Multimedia.DriverSupervisor,
           {DriverWorker, Redacted.new({state.driver, self(), token, fence_id, permit})}
         ) do
      {:ok, worker} ->
        {controller_pid, controller_ref, control} = capture_controller(controller)

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
          custody: nil,
          controller: controller_pid,
          controller_ref: controller_ref,
          controller_correlation: if(controller, do: elem(controller, 1)),
          control: control,
          capture_started: false,
          core: OperationCore.new(spec),
          deadline: deadline,
          timer: Process.send_after(self(), {:deadline, token}, max(0, deadline - now_ms()))
        }

        send(worker, {:open, token, Redacted.new(spec)})

        if controller do
          {pid, correlation} = controller
          send(pid, {:multimedia_capture_control, correlation, control})
        end

        {:noreply, %{state | operation: op}}

      {:error, _} ->
        # DriverWorker.init performs no native work, so failure before its open
        # handoff has no resource to exhaust.
        Fence.release(fence_id)
        {:reply, {:error, :device_unavailable}, state}
    end
  end

  defp valid_controller?({pid, correlation}),
    do: is_pid(pid) and node(pid) == node() and Process.alive?(pid) and is_reference(correlation)

  defp valid_controller?(_), do: false

  defp capture_controller(nil), do: {nil, nil, nil}

  defp capture_controller({pid, _}),
    do: {pid, Process.monitor(pid), :crypto.strong_rand_bytes(32)}

  defp apply_event(%{operation: op} = state, event) do
    {core, effects} = OperationCore.event(op.core, event, DateTime.utc_now())
    op = announce_capture_started(op, core, event)
    {:noreply, perform(%{state | operation: %{op | core: core}}, effects)}
  end

  defp announce_capture_started(
         %{
           capture_started: false,
           controller: controller,
           controller_correlation: correlation,
           control: control,
           core: %{spec: %{kind: :capture}, bytes: previous, cancelled: false, completed: false}
         } = op,
         %{bytes: bytes, cancelled: false},
         {:pcm, _pcm}
       )
       when is_pid(controller) and bytes > previous do
    if Driver.admitted?(op.permit) and Process.alive?(controller) do
      send(controller, {:multimedia_capture_started, correlation, control})
      %{op | capture_started: true}
    else
      op
    end
  end

  defp announce_capture_started(op, _core, _event), do: op

  defp perform(state, []), do: state

  defp perform(%{operation: op} = state, [:finish | effects]) do
    send(op.worker, {:finish, op.token})
    perform(state, effects)
  end

  defp perform(%{operation: op} = state, [:close | effects]) do
    :atomics.put(op.permit.revoked, 1, 1)
    send(op.worker, {:close, op.token})
    perform(state, effects)
  end

  defp perform(%{operation: op} = state, [:settle | _]) do
    Process.cancel_timer(op.timer)
    Process.demonitor(op.caller_ref, [:flush])
    Process.demonitor(op.worker_ref, [:flush])
    if op.controller_ref, do: Process.demonitor(op.controller_ref, [:flush])
    Fence.release(op.fence_id)
    if op.from, do: GenServer.reply(op.from, op.core.result)
    %{state | operation: nil}
  end

  defp expire(state), do: state |> cancel(:timeout) |> reply_pending()

  defp cancel(%{operation: op} = state, reason) do
    :atomics.put(op.permit.revoked, 1, 1)
    {core, effects} = OperationCore.cancel(op.core, reason)
    perform(%{state | operation: %{op | core: core}}, effects)
  end

  defp reply_pending(%{operation: op} = state) do
    if op.from, do: GenServer.reply(op.from, {:error, :cleanup_pending})
    %{state | operation: %{op | from: nil}}
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
