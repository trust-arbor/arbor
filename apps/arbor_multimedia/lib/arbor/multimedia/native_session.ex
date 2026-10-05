defmodule Arbor.Multimedia.NativeSession do
  @moduledoc false
  use GenServer, restart: :temporary
  alias Arbor.Multimedia.{Driver, NativePipeline, PcmCore, Redacted}
  alias Membrane.PortAudio.SyncExecutor

  def start_link(%Redacted{} = bootstrap), do: GenServer.start_link(__MODULE__, bootstrap)

  @impl true
  def init(%Redacted{value: {worker, token, phase, permit}}) do
    Process.flag(:sensitive, true)
    {owner, operation, fence_id, ^worker} = permit.custody
    send(owner, {:driver_custody_register, operation, worker, fence_id, self(), token})

    {:ok,
     %{
       worker: worker,
       worker_ref: Process.monitor(worker),
       token: token,
       phase: phase,
       bootstrap_permit: permit,
       registered: false,
       pending_activation: nil,
       permit: nil,
       spec: nil,
       identity: nil,
       executor_ref: nil,
       pipeline: nil,
       supervisor: nil,
       pipeline_ref: nil,
       supervisor_ref: nil,
       children: %{},
       startup: make_ref(),
       stream: :crypto.strong_rand_bytes(32),
       closing: false,
       admitted: false,
       finish_requested: false,
       finish_sent: false,
       cleanup: nil,
       cleanup_ref: nil,
       cleanup_unknown: false,
       close_ack: nil,
       enum: nil
     }}
  end

  @impl true
  def handle_info(
        {:activate, token, %Redacted{value: {spec, permit}}},
        %{token: token, permit: nil} = state
      ) do
    if permit == state.bootstrap_permit do
      activate_pending(%{state | pending_activation: {spec, permit}})
    else
      {:noreply, state}
    end
  end

  def handle_info(
        {:native_custody_ack, token, owner, worker, fence_id},
        %{token: token, worker: worker} = state
      ) do
    case state.bootstrap_permit.custody do
      {^owner, _, ^fence_id, ^worker} -> activate_pending(%{state | registered: true})
      _ -> {:noreply, state}
    end
  end

  def handle_info({:bootstrap, token}, %{token: token, closing: false} = state) do
    if admitted?(state) do
      case SyncExecutor.identity() do
        {:ok, {executor, _} = identity} ->
          state = %{state | identity: identity, executor_ref: Process.monitor(executor)}
          if state.spec.kind == :devices, do: start_enumerator(state), else: start_pipeline(state)

        _ ->
          fail(state, :device_unavailable)
      end
    else
      fail(state, :timeout)
    end
  end

  def handle_info({:configure, token}, %{token: token, closing: false} = state) do
    if admitted?(state) do
      config =
        state.spec
        |> Map.delete(:pcm)
        |> Map.merge(%{identity: state.identity, startup: state.startup, stream: state.stream})

      send(state.pipeline, {:configure, token, Redacted.new(config)})
      {:noreply, state}
    else
      fail(state, :timeout)
    end
  end

  def handle_info(
        {:native_pipeline, token, pipeline, name, %Redacted{value: event}},
        %{token: token, pipeline: pipeline} = state
      ) do
    child_event(state, name, event)
  end

  def handle_info(
        {:admit_children, token},
        %{token: token, closing: false, admitted: false} = state
      ) do
    names = if state.spec.kind == :capture, do: [:device, :collector], else: [:device, :feeder]

    if Enum.all?(names, &Map.has_key?(state.children, &1)) and admitted?(state) do
      device = state.children.device.pid

      case SyncExecutor.bind_lease(state.identity, device, lease(state), 5_000) do
        :ok ->
          admit_bound_children(state, names, token)

        _ ->
          fail(state, :driver_failed)
      end
    else
      {:noreply, state}
    end
  end

  def handle_info({:start_enum, token}, %{token: token, closing: false} = state) do
    case SyncExecutor.bind_lease(state.identity, state.enum, lease(state), 5_000) do
      :ok ->
        if admitted?(state), do: send(state.enum, {:enumerate, token})
        {:noreply, state}

      _ ->
        fail(state, :driver_failed)
    end
  end

  def handle_info(
        {:enum_result, token, pid, %Redacted{value: result}},
        %{token: token, enum: pid, closing: false} = state
      ) do
    case result do
      {:ok, devices} ->
        case normalize_devices(devices) do
          {:ok, devices} ->
            Driver.notify(state.permit, {:devices, devices})
            {:noreply, state}

          _ ->
            fail(state, :invalid_devices)
        end

      {:error, reason} ->
        fail(state, reason)

      _ ->
        fail(state, :driver_failed)
    end
  end

  def handle_info({:finish_capture, token}, %{token: token, closing: false} = state),
    do: {:noreply, maybe_finish_capture(%{state | finish_requested: true})}

  def handle_info({:close, token}, %{token: token} = state), do: begin_close(state)
  def handle_info({:retry_cleanup, token}, %{token: token} = state), do: begin_close(state)

  def handle_info({:cleanup_result, token, task, result}, %{token: token, cleanup: task} = state) do
    Process.demonitor(state.cleanup_ref, [:flush])
    state = %{state | cleanup: nil, cleanup_ref: nil}

    case result do
      :closed ->
        {:stop, :normal, state}

      :pending ->
        Process.send_after(self(), {:retry_cleanup, token}, 100)
        {:noreply, state}

      :unknown ->
        {:noreply, %{state | cleanup_unknown: true}}
    end
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{worker_ref: ref} = state),
    do: begin_close(state)

  def handle_info({:DOWN, ref, :process, _, _}, %{cleanup_ref: ref} = state) when not is_nil(ref),
    do: {:noreply, %{state | cleanup: nil, cleanup_ref: nil, cleanup_unknown: true}}

  def handle_info({:DOWN, ref, :process, pid, _}, state) do
    known =
      ref in [state.executor_ref, state.pipeline_ref, state.supervisor_ref] or
        Enum.any?(state.children, fn {_, child} -> child.ref == ref end)

    cond do
      not known ->
        {:noreply, state}

      state.closing ->
        if state.cleanup, do: send(state.cleanup, {:owner_down, state.token, pid})
        {:noreply, state}

      true ->
        fail(state, :driver_failed)
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def format_status(status),
    do:
      status
      |> Map.put(:state, :redacted)
      |> Map.put(:message, :redacted)
      |> Map.put(:reason, :redacted)
      |> Map.put(:log, [])

  defp admit_bound_children(state, names, token) do
    if admitted?(state) do
      other = List.last(names)
      control(state, other, {:admit, token})
      control(state, :device, {:portaudio_admit, state.startup})

      if state.spec.kind == :playback,
        do: control(state, :feeder, {:payload, token, Redacted.new(state.spec.pcm)})

      {:noreply,
       maybe_finish_capture(%{state | admitted: true, spec: Map.delete(state.spec, :pcm)})}
    else
      fail(state, :timeout)
    end
  end

  defp maybe_finish_capture(
         %{
           admitted: true,
           finish_requested: true,
           finish_sent: false,
           spec: %{kind: :capture},
           closing: false
         } = state
       ) do
    if admitted?(state) do
      control(state, :device, {:portaudio_finish_capture, state.startup})
      %{state | finish_sent: true}
    else
      state
    end
  end

  defp maybe_finish_capture(state), do: state

  defp activate_pending(
         %{registered: true, pending_activation: {spec, permit}, permit: nil} = state
       ) do
    if Process.alive?(state.worker) and Driver.admitted?(permit) and
         :atomics.compare_exchange(state.phase, 1, 0, 1) == :ok do
      # Publish the complete activation record before pipeline construction.
      send(self(), {:bootstrap, state.token})
      permit = Map.put(permit, :native_custodian, {self(), state.token})
      {:noreply, %{state | permit: permit, spec: spec, pending_activation: nil}}
    else
      {:stop, :normal, dormant_close(state)}
    end
  end

  defp activate_pending(state), do: {:noreply, state}

  defp start_pipeline(state) do
    case Membrane.Pipeline.start(NativePipeline, Redacted.new({self(), state.token})) do
      {:ok, supervisor, pipeline} ->
        send(self(), {:configure, state.token})

        {:noreply,
         %{
           state
           | supervisor: supervisor,
             pipeline: pipeline,
             supervisor_ref: Process.monitor(supervisor),
             pipeline_ref: Process.monitor(pipeline)
         }}

      _ ->
        fail(state, :driver_failed)
    end
  end

  defp start_enumerator(state) do
    parent = self()
    token = state.token
    identity = state.identity

    {:ok, pid} =
      Task.Supervisor.start_child(Arbor.Multimedia.NativeTaskSupervisor, fn ->
        Process.flag(:sensitive, true)
        parent_ref = Process.monitor(parent)

        receive do
          {:enumerate, ^token} ->
            result = apply(SyncExecutor, :enumerate_devices, [identity, 86_400_000])
            send(parent, {:enum_result, token, self(), Redacted.new(result)})

            receive do
              {:retire, ^token} -> :ok
              {:DOWN, ^parent_ref, :process, ^parent, _} -> :ok
            end

          {:retire, ^token} ->
            :ok

          {:DOWN, ^parent_ref, :process, ^parent, _} ->
            :ok
        end
      end)

    ref = Process.monitor(pid)
    send(self(), {:start_enum, token})
    {:noreply, %{state | enum: pid, children: %{enumerator: %{pid: pid, ref: ref}}}}
  end

  defp child_event(state, :device, {:portaudio_owner_ready, startup, pid})
       when startup == state.startup,
       do: record_child(state, :device, pid)

  defp child_event(state, name, {:arbor_media_ready, token, pid})
       when token == state.token and name in [:collector, :feeder],
       do: record_child(state, name, pid)

  defp child_event(%{closing: false} = state, :collector, {:arbor_pcm, token, pid, pcm})
       when token == state.token do
    if known_child?(state, :collector, pid), do: Driver.notify(state.permit, {:pcm, pcm})
    {:noreply, state}
  end

  defp child_event(%{closing: false} = state, name, {:arbor_invalid, token, pid})
       when token == state.token do
    if known_child?(state, name, pid), do: fail(state, :invalid_media), else: {:noreply, state}
  end

  defp child_event(%{closing: false} = state, :device, {kind, stream, disposition, frames})
       when stream == state.stream and
              kind in [:portaudio_capture_finished, :portaudio_playback_finished] do
    expected =
      if state.spec.kind == :capture,
        do: :portaudio_capture_finished,
        else: :portaudio_playback_finished

    cond do
      kind == expected and disposition == :complete and frames == state.spec.frames ->
        Driver.notify(state.permit, {:complete, frames})
        {:noreply, state}

      kind == :portaudio_capture_finished and state.spec.kind == :capture and
        disposition == :partial and state.finish_sent and is_integer(frames) and
        frames >= 0 and frames <= state.spec.frames ->
        Driver.notify(state.permit, {:partial, frames})
        {:noreply, state}

      true ->
        fail(state, :invalid_media)
    end
  end

  defp child_event(
         %{closing: false} = state,
         :device,
         {:portaudio_capture_finish_failed, startup, _reason}
       )
       when startup == state.startup,
       do: fail(state, :finish_unavailable)

  defp child_event(state, :device, {:portaudio_closed, startup, result})
       when startup == state.startup do
    if result == {:error, :stop_failed_closed}, do: mark_failure(state, :driver_failed)
    if state.cleanup, do: send(state.cleanup, {:close_ack, state.token, result})
    {:noreply, %{state | close_ack: result}}
  end

  defp child_event(%{closing: false} = state, :device, {kind, stream, reason, _})
       when stream == state.stream and
              kind in [:portaudio_open_failed, :portaudio_start_failed, :portaudio_write_failed],
       do: fail(state, reason)

  defp child_event(
         %{closing: false} = state,
         :device,
         {:portaudio_admission_failed, startup, reason}
       )
       when startup == state.startup,
       do: fail(state, reason)

  defp child_event(state, _, _), do: {:noreply, state}

  defp record_child(state, name, pid) do
    cond do
      not is_pid(pid) or node(pid) != node() ->
        fail(state, :driver_failed)

      Map.has_key?(state.children, name) ->
        if known_child?(state, name, pid),
          do: {:noreply, state},
          else: fail(state, :driver_failed)

      true ->
        children = Map.put(state.children, name, %{pid: pid, ref: Process.monitor(pid)})
        if not state.closing, do: send(self(), {:admit_children, state.token})
        {:noreply, %{state | children: children}}
    end
  end

  defp known_child?(state, name, pid), do: match?(%{pid: ^pid}, state.children[name])

  defp admitted?(state),
    do: not state.closing and Process.alive?(state.worker) and Driver.admitted?(state.permit)

  defp lease(state),
    do: %{
      deadline: state.permit.deadline,
      revoked: state.permit.revoked,
      custodian: self(),
      caller: state.permit.caller,
      operation: state.startup
    }

  defp control(state, name, event),
    do: send(state.pipeline, {:control, state.token, name, Redacted.new(event)})

  defp fail(state, reason) do
    mark_failure(state, PcmCore.error(reason))
    begin_close(state)
  end

  defp mark_failure(state, reason) do
    :atomics.put(state.phase, 2, 1)
    if state.permit, do: Driver.notify(state.permit, {:error, reason})
  end

  defp dormant_close(state) do
    _ = :atomics.compare_exchange(state.phase, 1, 0, 3)

    if :atomics.get(state.phase, 1) == 3 and not Process.alive?(state.worker),
      do:
        Driver.confirm_custody_closed(
          Map.put(state.bootstrap_permit, :native_custodian, {self(), state.token})
        )

    state
  end

  defp begin_close(%{permit: nil} = state), do: {:stop, :normal, dormant_close(state)}
  defp begin_close(%{cleanup: task} = state) when is_pid(task), do: {:noreply, state}
  defp begin_close(%{cleanup_unknown: true} = state), do: {:noreply, state}

  defp begin_close(state) do
    :atomics.put(state.permit.revoked, 1, 1)
    :atomics.put(state.phase, 1, 2)

    if state.pipeline && state.children[:device],
      do: control(state, :device, {:portaudio_close, state.startup})

    parent = self()

    plan =
      Map.take(state, [
        :identity,
        :children,
        :pipeline,
        :supervisor,
        :phase,
        :permit,
        :token,
        :enum,
        :close_ack
      ])

    {:ok, task} =
      Task.Supervisor.start_child(Arbor.Multimedia.NativeTaskSupervisor, fn ->
        Process.flag(:sensitive, true)
        result = cleanup(plan)
        send(parent, {:cleanup_result, plan.token, self(), result})
      end)

    {:noreply,
     %{
       state
       | closing: true,
         spec: Map.delete(state.spec || %{}, :pcm),
         cleanup: task,
         cleanup_ref: Process.monitor(task)
     }}
  end

  defp cleanup(plan) do
    # One retained helper owns the blocking barrier. It does not use short call
    # timeouts which would leave queued barriers while retries accumulate.
    media_ack = await_close_ack(plan)
    owners = for {name, child} <- plan.children, name in [:device, :enumerator], do: child.pid
    results = Enum.map(owners, &SyncExecutor.close_owner(plan.identity, &1, 86_400_000))

    if Enum.all?(results, &(&1 == :ok)) do
      # The executor barrier attests resource closure only. In particular it
      # normalizes stop_failed_closed to :ok; an earlier pending element ACK
      # must not let that cleanup fact upgrade media success.
      if media_ack != :ok, do: :atomics.put(plan.phase, 2, 1)

      if terminate_tree(plan) do
        :atomics.put(plan.phase, 1, 3)

        if not Process.alive?(plan.permit.receiver),
          do: Driver.confirm_custody_closed(plan.permit)

        :closed
      else
        :pending
      end
    else
      if Enum.any?(
           results,
           &(&1 in [{:error, :executor_changed}, {:error, :executor_unavailable}])
         ) do
        terminate_tree(plan)
        :unknown
      else
        :pending
      end
    end
  rescue
    _ -> :unknown
  catch
    _, _ -> :unknown
  end

  defp await_close_ack(%{children: %{device: %{pid: pid}}} = plan) do
    cond do
      plan.close_ack != nil ->
        plan.close_ack

      not Process.alive?(pid) ->
        :unknown

      true ->
        receive do
          {:close_ack, token, result} when token == plan.token -> result
          {:owner_down, token, ^pid} when token == plan.token -> :unknown
        after
          1_000 -> :unknown
        end
    end
  end

  defp await_close_ack(_), do: :ok

  defp terminate_tree(plan) do
    if plan.enum, do: send(plan.enum, {:retire, plan.token})

    pids =
      [plan.supervisor, plan.pipeline, plan.enum] ++
        Enum.map(plan.children, fn {_, child} -> child.pid end)

    monitors =
      for pid <- Enum.uniq(pids),
          is_pid(pid),
          Process.alive?(pid),
          do: {pid, Process.monitor(pid)}

    if is_pid(plan.pipeline) and Process.alive?(plan.pipeline),
      do: Membrane.Pipeline.terminate(plan.pipeline, timeout: 1_000, force?: true)

    Enum.all?(monitors, fn {pid, ref} ->
      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> true
      after
        2_000 ->
          Process.demonitor(ref, [:flush])
          false
      end
    end)
  end

  defp normalize_devices(devices) when is_list(devices) do
    keys = [:id, :name, :max_input_channels, :max_output_channels, :default_sample_rate]

    if Enum.all?(devices, &is_map/1),
      do: PcmCore.devices(Enum.map(devices, &Map.take(&1, keys))),
      else: {:error, :invalid_devices}
  end

  defp normalize_devices(_), do: {:error, :invalid_devices}
end
