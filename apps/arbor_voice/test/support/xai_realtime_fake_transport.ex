defmodule Arbor.Voice.Test.XaiRealtimeFakeTransport do
  @moduledoc """
  Scripted `Arbor.Voice.Backend.XaiRealtime.Transport`-shaped test double.
  Not a working transport -- feeds pre-scripted frames and captures
  outbound frames/connect opts for assertions. No network I/O.
  """

  @derive {Inspect, except: [:captured_token]}
  defstruct [
    :captured_token,
    :captured_host,
    :captured_port,
    :captured_path,
    :on_send,
    :on_recv,
    :on_close,
    :on_deadline,
    auto_ack: true,
    sent: [],
    frames: []
  ]

  def connect(opts) do
    on_connect = Keyword.get(opts, :on_connect, fn -> :ok end)

    case Keyword.get(opts, :connect_mode) do
      {:error_echo, _reason} ->
        {:error, {:connect_failed, opts}}

      {:raise_echo, token} ->
        raise "connect failed for token=#{token}"

      _other ->
        on_connect.()

        {:ok,
         %__MODULE__{
           captured_token: Keyword.fetch!(opts, :token),
           captured_host: Keyword.fetch!(opts, :host),
           captured_port: Keyword.fetch!(opts, :port),
           captured_path: Keyword.fetch!(opts, :path),
           frames: Keyword.get(opts, :frames, []),
           on_send: Keyword.get(opts, :on_send, fn _frame -> :ok end),
           on_recv: Keyword.get(opts, :on_recv, fn -> :ok end),
           on_close: Keyword.get(opts, :on_close, fn -> :ok end),
           on_deadline: Keyword.get(opts, :on_deadline, fn _deadline -> :ok end),
           auto_ack: Keyword.get(opts, :auto_ack, true)
         }}
    end
  end

  def send_frame(%__MODULE__{} = state, frame) do
    state.on_send.(frame)

    frames =
      case frame do
        %{"type" => "session.update", "session" => config} when state.auto_ack ->
          [%{"type" => "session.updated", "session" => config} | state.frames]

        _ ->
          state.frames
      end

    {:ok, %{state | sent: state.sent ++ [frame], frames: frames}}
  end

  def send_frame(%__MODULE__{} = state, frame, deadline) do
    state.on_deadline.(deadline)
    send_frame(state, frame)
  end

  def recv_frame(%__MODULE__{frames: [frame | rest]} = state, _timeout) do
    state.on_recv.()
    {:ok, %{state | frames: rest}, frame}
  end

  def recv_frame(%__MODULE__{frames: []}, _timeout) do
    {:error, :fake_transport_exhausted}
  end

  def close(%__MODULE__{on_close: callback} = state) when is_function(callback, 1),
    do: callback.(state)

  def close(%__MODULE__{} = state), do: state.on_close.()
end
