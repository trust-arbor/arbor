defmodule Arbor.Multimedia.Driver.Native do
  @moduledoc false
  @behaviour Arbor.Multimedia.Driver
  alias Arbor.Multimedia.{NativeSession, Redacted}

  def microphone_permission do
    if :os.type() == {:unix, :darwin} and Code.ensure_loaded?(Membrane.PortAudio.OSXPermissions) do
      apply(Membrane.PortAudio.OSXPermissions, :authorization_status, [])
    else
      :unavailable
    end
  end

  def request_microphone_permission do
    if :os.type() == {:unix, :darwin} and Code.ensure_loaded?(Membrane.PortAudio.OSXPermissions) do
      :ok = apply(Membrane.PortAudio.OSXPermissions, :request_mic, [])
      microphone_permission()
    else
      :unavailable
    end
  end

  @impl true
  def open(_spec, permit) do
    phase = :atomics.new(2, [])
    token = :crypto.strong_rand_bytes(32)
    bootstrap = Redacted.new({self(), token, phase, permit})

    case DynamicSupervisor.start_child(
           Arbor.Multimedia.NativeSupervisor,
           {NativeSession, bootstrap}
         ) do
      {:ok, pid} -> {:ok, %{pid: pid, token: token, phase: phase}}
      _ -> {:error, :device_unavailable, :closed}
    end
  end

  @impl true
  def activate(handle, spec, permit) do
    send(handle.pid, {:activate, handle.token, Redacted.new({spec, permit})})
    :ok
  end

  @impl true
  def manual_capture_finish_supported? do
    Code.ensure_loaded?(Membrane.PortAudio.Source) and
      function_exported?(Membrane.PortAudio.Source, :manual_capture_finish_supported?, 0) and
      apply(Membrane.PortAudio.Source, :manual_capture_finish_supported?, []) == true
  end

  @impl true
  def finish(handle) do
    if manual_capture_finish_supported?() do
      send(handle.pid, {:finish_capture, handle.token})
      :ok
    else
      {:error, :finish_unavailable}
    end
  end

  @impl true
  def close(handle) do
    # Dormant phase has never owned a pipeline or issued native work. Atomically
    # close it before sending shutdown; a queued activation can no longer win.
    _ = :atomics.compare_exchange(handle.phase, 1, 0, 3)
    send(handle.pid, {:close, handle.token})

    case {:atomics.get(handle.phase, 1), :atomics.get(handle.phase, 2)} do
      {3, 0} -> :ok
      {3, _} -> {:error, :driver_failed, :closed}
      _ -> {:error, :cleanup_pending}
    end
  end
end
