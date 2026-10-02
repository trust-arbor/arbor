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
  alias Arbor.Multimedia.{DeviceOwner, Fence, PcmCore, Redacted}

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

  @spec play_pcm(audio(), keyword()) :: :ok | {:error, atom()}
  def play_pcm(audio, opts \\ []) do
    with {:ok, spec} <- PcmCore.playback(audio, opts), do: run(spec)
  end

  defp run(spec) do
    request = make_ref()
    grace = Application.get_env(:arbor_multimedia, :operation_grace_ms, 2_000)
    # Internal configuration may shorten test deadlines, never public opts.
    grace = if is_integer(grace) and grace in 1..5_000, do: grace, else: 2_000
    timeout = spec.duration_ms + grace
    deadline = System.monotonic_time(:millisecond) + timeout

    try do
      GenServer.call(DeviceOwner, {:run, request, Redacted.new(spec), deadline}, timeout + 100)
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
