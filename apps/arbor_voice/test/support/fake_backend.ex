defmodule Arbor.VoiceTest.Support.FakeBackend do
  @moduledoc """
  Minimal Arbor.Voice.RealtimeBackend implementation used only to prove
  behaviour conformance (VOICE-5, partial — see realtime_backend_test.exs).
  Not a working backend: recv/2 always reports :turn_done immediately.
  """

  @behaviour Arbor.Voice.RealtimeBackend

  @impl true
  def open(_opts), do: {:ok, %{closed: false}}

  @impl true
  def configure(session, _config), do: {:ok, session}

  @impl true
  def send_text(session, _text), do: {:ok, session}

  @impl true
  def send_audio(session, _chunk), do: {:ok, session}

  @impl true
  def send_tool_result(session, _call_id, _output), do: {:ok, session}

  @impl true
  def recv(session, _timeout), do: {:ok, session, {:turn_done, %{text: ""}}}

  @impl true
  def close(_session), do: :ok

  @impl true
  def meta(_session), do: %{backend: :fake, mode: :local, input_rate: nil, output_rate: nil}
end
