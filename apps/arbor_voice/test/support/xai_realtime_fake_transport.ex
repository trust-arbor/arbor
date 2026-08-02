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
    :on_recv,
    sent: [],
    frames: []
  ]

  def connect(opts) do
    case Keyword.get(opts, :connect_mode) do
      {:error_echo, _reason} ->
        {:error, {:connect_failed, opts}}

      {:raise_echo, token} ->
        raise "connect failed for token=#{token}"

      _other ->
        {:ok,
         %__MODULE__{
           captured_token: Keyword.fetch!(opts, :token),
           captured_host: Keyword.fetch!(opts, :host),
           captured_port: Keyword.fetch!(opts, :port),
           captured_path: Keyword.fetch!(opts, :path),
           frames: Keyword.get(opts, :frames, []),
           on_recv: Keyword.get(opts, :on_recv, fn -> :ok end)
         }}
    end
  end

  def send_frame(%__MODULE__{} = state, frame) do
    {:ok, %{state | sent: state.sent ++ [frame]}}
  end

  def recv_frame(%__MODULE__{frames: [frame | rest]} = state, _timeout) do
    state.on_recv.()
    {:ok, %{state | frames: rest}, frame}
  end

  def recv_frame(%__MODULE__{frames: []}, _timeout) do
    {:error, :fake_transport_exhausted}
  end

  def close(%__MODULE__{}), do: :ok
end
