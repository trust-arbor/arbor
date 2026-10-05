defmodule Arbor.Multimedia do
  @moduledoc """
  Bounded, trusted local PCM device operations.

  A single supervised owner serializes device access. Completion requires exact
  frame accounting and positive native close. `:cleanup_pending` ends the caller's
  wait while supervised cleanup retains exclusive device custody. Process death
  alone never releases custody. PCM is kept in memory and redacted from ordinary
  OTP diagnostics; trusted VM introspection/debugging is outside this boundary.

  The default driver fails closed until the reviewed native prerequisites are
  adopted and qualified. There is no implicit device or permission probe at boot.
  """
  alias Arbor.Multimedia.{DeviceOwner, Driver, Fence, PcmCore, Redacted}

  @type audio :: %{pcm: binary(), sample_rate: pos_integer(), channels: 1, sample_format: :s16le}

  @doc "Observe retained device custody. This never cancels work or releases a fence."
  @spec device_status() :: :idle | :busy | :cleanup_pending | :device_unavailable
  def device_status do
    GenServer.call(DeviceOwner, :device_status, 1_000)
  catch
    :exit, _ -> if Fence.current() == nil, do: :device_unavailable, else: :cleanup_pending
  end

  @doc "Query microphone permission explicitly; never called during application startup."
  @spec microphone_permission() ::
          :authorized | :denied | :restricted | :not_determined | :unavailable
  def microphone_permission, do: permission(:microphone_permission)

  @doc "Explicitly request microphone permission once, then return the current status."
  @spec request_microphone_permission() ::
          :authorized | :denied | :restricted | :not_determined | :unavailable
  def request_microphone_permission, do: permission(:request_microphone_permission)

  defp permission(operation) do
    driver = Application.get_env(:arbor_multimedia, :driver, Arbor.Multimedia.Driver.Unavailable)

    if Code.ensure_loaded?(driver) and function_exported?(driver, operation, 0) do
      case apply(driver, operation, []) do
        status
        when status in [:authorized, :denied, :restricted, :not_determined, :unavailable] ->
          status

        _ ->
          :unavailable
      end
    else
      :unavailable
    end
  rescue
    _ -> :unavailable
  catch
    _, _ -> :unavailable
  end

  @spec devices() :: {:ok, [map()]} | {:error, atom()}
  def devices, do: run(%{kind: :devices, duration_ms: 0})

  @spec capture_pcm(keyword()) ::
          {:ok, %{audio: audio(), utterance_ended_at: DateTime.t()}} | {:error, atom()}
  def capture_pcm(opts) do
    with {:ok, spec} <- PcmCore.capture(opts), do: run(spec)
  end

  @doc "Whether the configured driver supports returning a manually finished capture."
  @spec manual_capture_finish_supported?() :: boolean()
  def manual_capture_finish_supported? do
    driver = Application.get_env(:arbor_multimedia, :driver, Driver.Unavailable)
    Driver.manual_finish_supported?(driver)
  end

  @doc """
  Start bounded capture with a private manual-finish control.

  The local `controller: {pid, correlation_ref}` receives
  `{:multimedia_capture_control, correlation_ref, control}`. Only that controller
  holding the opaque control can request finish. Control delivery does not mean
  capture has started. After the first valid PCM chunk while capture is active,
  the same controller
  receives `{:multimedia_capture_started, correlation_ref, control}` once. This
  confirms sample delivery, not audio quality or capture completion; it carries
  no audio. Early finish remains supported before this receipt.
  `minimum_duration_ms` defaults
  to 100. Short recordings fail after cleanup; no silence is invented.
  The caller still waits for exact captured bytes and positive device closure.
  Controller or caller loss cancels and discards capture.
  """
  @spec capture_pcm(keyword(), keyword()) ::
          {:ok, %{audio: audio(), utterance_ended_at: DateTime.t()}} | {:error, atom()}
  def capture_pcm(opts, control_opts) do
    with {:ok, spec} <- PcmCore.capture(opts),
         {:ok, spec, controller} <- PcmCore.capture_control(spec, control_opts, node()) do
      run(spec, controller)
    end
  end

  @doc "Request early capture completion. Acknowledgement is not audio or cleanup completion."
  @spec finish_capture(binary()) :: :ok | {:error, atom()}
  def finish_capture(control) when is_binary(control) and byte_size(control) == 32 do
    GenServer.call(DeviceOwner, {:finish_capture, Redacted.new(control)}, 1_000)
  catch
    :exit, _ -> {:error, :finish_unavailable}
  end

  def finish_capture(_), do: {:error, :invalid_control}

  @spec play_pcm(audio(), keyword()) :: :ok | {:error, atom()}
  def play_pcm(audio, opts \\ []) do
    with {:ok, spec} <- PcmCore.playback(audio, opts), do: run(spec)
  end

  defp run(spec, controller \\ nil) do
    request = make_ref()
    grace = Application.get_env(:arbor_multimedia, :operation_grace_ms, 2_000)
    # Internal configuration may shorten test deadlines, never public opts.
    grace = if is_integer(grace) and grace in 1..5_000, do: grace, else: 2_000
    timeout = spec.duration_ms + grace
    deadline = System.monotonic_time(:millisecond) + timeout

    try do
      GenServer.call(
        DeviceOwner,
        {:run, request, Redacted.new(spec), deadline, Redacted.new(controller)},
        timeout + 100
      )
    catch
      :exit, {:timeout, _} ->
        if pid = Process.whereis(DeviceOwner), do: send(pid, {:cancel, request, self()})
        {:error, :cleanup_pending}

      :exit, {:noproc, _} ->
        if Fence.current() == nil,
          do: {:error, :device_unavailable},
          else: {:error, :cleanup_pending}

      :exit, _ ->
        {:error, :cleanup_pending}
    end
  end
end
