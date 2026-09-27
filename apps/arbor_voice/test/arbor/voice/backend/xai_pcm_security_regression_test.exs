defmodule Arbor.Voice.Backend.XaiPcmSecurityRegressionTest do
  use ExUnit.Case, async: true

  alias Arbor.Voice.Backend.XaiRealtime
  alias Arbor.Voice.Backend.XaiRealtime.Transport
  alias Arbor.Voice.PcmFormat
  alias Arbor.Voice.Test.XaiRealtimeFakeTransport, as: FakeTransport

  @moduletag :fast

  defmodule AmbiguousTransport do
    def connect(opts),
      do: {:ok, %{observer: Keyword.fetch!(opts, :observer), generation: 1, frames: []}}

    def send_frame(state, %{"type" => "session.update", "session" => config}, _deadline),
      do: {:ok, %{state | frames: [%{"type" => "session.updated", "session" => config}]}}

    def send_frame(state, _frame, _deadline),
      do: {:error, %Mint.TransportError{reason: :timeout}, %{state | generation: 2}}

    def close(state), do: send(state.observer, {:closed_handle, state})

    def recv_frame(%{frames: [frame | rest]} = state, _timeout),
      do: {:ok, %{state | frames: rest}, frame}
  end

  defp open(opts \\ []) do
    with {:ok, session} <- raw_open(opts), do: XaiRealtime.configure(session, %{})
  end

  defp raw_open(opts) do
    XaiRealtime.open(
      Keyword.merge(
        [
          transport: FakeTransport,
          effect_authorizer: fn _, _ -> :allow end,
          oauth_resolver: fn :xai -> {:ok, "fixture-token"} end
        ],
        opts
      )
    )
  end

  defp confirmed_session do
    %{
      "audio" => %{
        "input" => %{
          "format" => %{"type" => "audio/pcm", "rate" => 16_000},
          "transport" => "json"
        },
        "output" => %{
          "format" => %{"type" => "audio/pcm", "rate" => 24_000},
          "transport" => "json"
        }
      }
    }
  end

  test "documented default-created then configured-updated sequence admits exact PCM only after acknowledgement" do
    defaults = put_in(confirmed_session(), ["audio", "input", "format", "rate"], 24_000)

    frames = [
      %{"type" => "session.created", "session" => defaults},
      %{"type" => "conversation.created", "conversation" => %{"id" => "fixture"}},
      %{"type" => "session.updated", "session" => confirmed_session()},
      %{"type" => "response.output_audio.delta", "delta" => "AAA="}
    ]

    {:ok, session} = raw_open(transport_opts: [auto_ack: false, frames: frames])
    assert %{input_format: nil, output_format: nil} = XaiRealtime.meta(session)
    assert {:error, :audio_not_configured} = XaiRealtime.send_audio(session, <<0, 0>>)
    assert {:ok, session} = XaiRealtime.configure(session, %{})

    assert %{input_format: %{sample_rate: 16_000}, output_format: %{sample_rate: 24_000}} =
             XaiRealtime.meta(session)

    [update] = session.transport_state.sent
    assert update["session"]["audio"]["input"]["format"]["rate"] == 16_000
    assert update["session"]["audio"]["output"]["transport"] == "json"
    assert {:ok, _, {:output_audio, <<0, 0>>}} = XaiRealtime.recv(session, 1_000)
  end

  test "missing mismatched or binary-transport acknowledgement never admits PCM and closes latest" do
    for frames <- [
          [],
          [%{"type" => "session.updated", "session" => %{}}],
          [
            %{
              "type" => "session.updated",
              "session" =>
                put_in(confirmed_session(), ["audio", "input", "format", "rate"], 24_000)
            }
          ],
          [
            %{
              "type" => "session.updated",
              "session" => put_in(confirmed_session(), ["audio", "output", "transport"], "binary")
            }
          ],
          [%{"type" => "response.output_audio.delta", "delta" => "AAA="}]
        ] do
      parent = self()

      {:ok, session} =
        raw_open(
          transport_opts: [
            auto_ack: false,
            frames: frames,
            on_close: fn latest -> send(parent, {:closed_handle, latest}) end
          ]
        )

      assert {:error, _, latest} = XaiRealtime.configure(session, %{})
      assert %{input_format: nil, output_format: nil} = XaiRealtime.meta(latest)
      closed = latest.transport_state
      assert_receive {:closed_handle, ^closed}
    end
  end

  test "startup control events do not renew the configuration acknowledgement deadline" do
    key = {__MODULE__, make_ref()}
    Process.put(key, 0)

    frames = [
      %{"type" => "session.created", "session" => %{}},
      %{"type" => "conversation.created"},
      %{"type" => "session.updated", "session" => confirmed_session()}
    ]

    {:ok, session} =
      raw_open(
        clock_fun: fn -> Process.get(key) end,
        transport_opts: [
          auto_ack: false,
          frames: frames,
          on_recv: fn -> Process.put(key, Process.get(key) + 11_000) end
        ]
      )

    assert {:error, :timeout, latest} = XaiRealtime.configure(session, %{})
    assert %{input_format: nil, output_format: nil} = XaiRealtime.meta(latest)
  end

  @tag :security_regression
  test "security regression: malformed wire PCM never becomes an empty or playable audio event" do
    invalid = [nil, "", "%%%", "AQ==", Base.encode64(:binary.copy(<<0, 0>>, 32_769)), 12]

    for delta <- invalid do
      frame = %{"type" => "response.output_audio.delta", "delta" => delta}
      {:ok, session} = open(transport_opts: [frames: [frame]])
      assert {:error, :xai_audio_protocol_error} = XaiRealtime.recv(session, 1_000)
    end

    {:ok, session} = open(transport_opts: [frames: [%{"type" => "response.output_audio.delta"}]])
    assert {:error, :xai_audio_protocol_error} = XaiRealtime.recv(session, 1_000)
  end

  @tag :security_regression
  test "security regression: input PCM validation rejects empty odd oversized and nonbinary before effects" do
    parent = self()

    {:ok, session} =
      open(
        transport_opts: [
          on_send: fn frame ->
            if frame["type"] != "session.update", do: send(parent, :physical_send)
          end
        ]
      )

    for pcm <- [<<>>, <<1>>, :binary.copy(<<0, 0>>, 1_048_577), :not_pcm] do
      assert {:error, :invalid_audio} = XaiRealtime.send_audio(session, pcm)
    end

    refute_receive :physical_send
  end

  @tag :security_regression
  test "security regression: conflicting declared output format fails before returning PCM" do
    for format <- [
          %{"type" => "audio/pcm", "rate" => 16_000},
          %{"type" => "audio/opus", "rate" => 24_000},
          %{"type" => "audio/pcm", "rate" => 24_000, "channels" => 2},
          nil,
          "pcm16"
        ] do
      frame = %{"type" => "response.output_audio.delta", "delta" => "AAA=", "format" => format}
      {:ok, session} = open(transport_opts: [frames: [frame]])
      assert {:error, :xai_audio_protocol_error} = XaiRealtime.recv(session, 1_000)
    end

    frame = %{"type" => "response.output_audio.delta", "delta" => "AAA=", "channels" => 2}
    {:ok, session} = open(transport_opts: [frames: [frame]])
    assert {:error, :xai_audio_protocol_error} = XaiRealtime.recv(session, 1_000)
  end

  test "session format declarations must agree with source-owned input and output" do
    for {direction, wrong_rate} <- [{"input", 24_000}, {"output", 16_000}] do
      frame = %{
        "type" => "session.updated",
        "session" => %{
          "audio" => %{direction => %{"format" => %{"type" => "audio/pcm", "rate" => wrong_rate}}}
        }
      }

      {:ok, session} = open(transport_opts: [frames: [frame]])
      assert {:error, :xai_audio_protocol_error} = XaiRealtime.recv(session, 1_000)
    end
  end

  @tag :security_regression
  test "security regression: alternate session format fields cannot silently override PCM authority" do
    for session_payload <- [
          %{"output_audio_format" => "g711_ulaw"},
          %{"input_audio_format" => "pcm16"},
          %{"audio" => %{"channels" => 2}},
          %{"audio" => %{"output" => %{"sample_rate" => 16_000}}},
          %{
            "audio" => %{
              "output" => %{
                "format" => %{"type" => "audio/pcm", "rate" => 24_000},
                "channels" => 2
              }
            }
          }
        ] do
      frames = [
        %{"type" => "session.updated", "session" => session_payload},
        %{"type" => "response.output_audio.delta", "delta" => "AAA="}
      ]

      {:ok, session} = open(transport_opts: [frames: frames])
      assert {:error, :xai_audio_protocol_error} = XaiRealtime.recv(session, 1_000)
    end
  end

  test "valid PCM limit and matching optional wire format decode without rewriting bytes" do
    pcm = :binary.copy(<<0, 128>>, 32_768)
    format = %{"type" => "audio/pcm", "rate" => 24_000}

    frame = %{
      "type" => "response.output_audio.delta",
      "delta" => Base.encode64(pcm),
      "format" => format
    }

    {:ok, session} = open(transport_opts: [frames: [frame]])
    assert {:ok, _, {:output_audio, ^pcm}} = XaiRealtime.recv(session, 1_000)
  end

  test "invalid audio closes the exact advanced receive handle before returning an error" do
    parent = self()
    invalid = %{"type" => "response.output_audio.delta", "delta" => "%%%"}
    trailing = %{"type" => "response.output_text.delta", "delta" => "must not publish"}

    {:ok, session} =
      open(
        transport_opts: [
          frames: [invalid, trailing],
          on_close: fn latest -> send(parent, {:closed_handle, latest}) end
        ]
      )

    assert {:error, :xai_audio_protocol_error} = XaiRealtime.recv(session, 1_000)
    assert_receive {:closed_handle, %{frames: [^trailing]}}
    refute_receive {:closed_handle, %{frames: [^invalid, ^trailing]}}
  end

  test "requested text mode cannot replace fixed provider metadata and audio config must match" do
    {:ok, session} = open()
    {:ok, session} = XaiRealtime.configure(session, %{})

    assert XaiRealtime.meta(session) == %{
             backend: :xai_realtime,
             mode: :cloud,
             input_format: PcmFormat.mono_s16le(16_000),
             output_format: PcmFormat.mono_s16le(24_000)
           }

    assert {:error, :audio_format_mismatch} = XaiRealtime.configure(session, %{audio: nil})

    assert {:error, :audio_format_mismatch} =
             XaiRealtime.configure(session, %{
               audio: %{
                 input_format: PcmFormat.mono_s16le(24_000),
                 output_format: PcmFormat.mono_s16le(24_000)
               }
             })

    assert {:ok, _} =
             XaiRealtime.configure(session, %{
               audio: %{
                 input_format: PcmFormat.mono_s16le(16_000),
                 output_format: PcmFormat.mono_s16le(24_000)
               }
             })
  end

  test "one finite deadline spans audio framing and all physical frames; ambiguous timeout closes latest" do
    parent = self()
    key = {__MODULE__, make_ref()}
    Process.put(key, 0)

    {:ok, session} =
      open(
        clock_fun: fn -> Process.get(key) end,
        transport_opts: [
          on_send: fn frame ->
            if frame["type"] != "session.update" do
              send(parent, {:sent, frame["type"]})
              Process.put(key, Process.get(key) + 15_000)
            end
          end,
          on_deadline: fn deadline -> send(parent, {:deadline, deadline}) end,
          on_close: fn latest -> send(parent, {:closed_handle, latest}) end
        ]
      )

    assert_receive {:deadline, 30_000}
    assert {:error, :timeout, latest} = XaiRealtime.send_audio(session, <<0, 0>>)

    assert Enum.map(latest.transport_state.sent, & &1["type"]) == [
             "session.update",
             "input_audio_buffer.append",
             "input_audio_buffer.commit"
           ]

    assert_receive {:deadline, 30_000}
    assert_receive {:sent, "input_audio_buffer.append"}
    assert_receive {:deadline, 30_000}
    assert_receive {:sent, "input_audio_buffer.commit"}
    latest_transport = latest.transport_state
    assert_receive {:closed_handle, ^latest_transport}
    refute_receive {:sent, "response.create"}
  end

  test "first-frame ambiguous error closes and returns the latest transport handle" do
    {:ok, session} = open(transport: AmbiguousTransport, transport_opts: [observer: self()])
    assert {:error, :xai_transport_failed, latest} = XaiRealtime.send_audio(session, <<0, 0>>)
    assert latest.transport_state.generation == 2
    latest_transport = latest.transport_state
    assert_receive {:closed_handle, ^latest_transport}
    refute_receive {:closed_handle, %{generation: 1}}
  end

  test "deadline exhausted during authorization cannot begin a physical write" do
    parent = self()
    key = {__MODULE__, make_ref()}
    Process.put(key, 0)

    {:ok, session} =
      open(
        clock_fun: fn -> Process.get(key) end,
        effect_authorizer: fn
          :connect, _ ->
            :allow

          :configure, _ ->
            :allow

          _, _ ->
            Process.put(key, 30_001)
            :allow
        end,
        transport_opts: [
          on_send: fn frame ->
            if frame["type"] != "session.update", do: send(parent, :physical_send)
          end,
          on_close: fn -> send(parent, :closed) end
        ]
      )

    assert {:error, :timeout} = XaiRealtime.send_audio(session, <<0, 0>>)
    assert_receive :closed
    refute_receive :physical_send
  end

  test "transport rejects infinity and includes JSON encoding in its finite deadline" do
    key = {__MODULE__, make_ref()}
    Process.put(key, [0, 31_000])

    clock = fn ->
      [now | rest] = Process.get(key)
      Process.put(key, rest)
      now
    end

    state = %{clock_fun: clock, conn: nil, ws: nil, ref: nil}
    assert {:error, :invalid_timeout} = Transport.send_frame(state, %{}, :infinity)
    # No socket or WebSocket object exists: exhaustion after JSON framing must
    # return before either is touched, instead of starting another timeout.
    assert {:error, :timeout} = Transport.send_frame(state, %{"audio" => "AAA="}, 30_000)
    assert Process.get(key) == []
  end
end
