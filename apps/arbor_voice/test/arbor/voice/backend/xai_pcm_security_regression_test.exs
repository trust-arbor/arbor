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

  test "JSON ping before the created and updated sequence waits for exact PCM acknowledgement" do
    frames = [
      %{"type" => "ping"},
      %{"type" => "session.created", "session" => %{}},
      %{"type" => "session.updated", "session" => confirmed_session()},
      %{"type" => "response.output_audio.delta", "delta" => "AAA="}
    ]

    {:ok, session} = raw_open(transport_opts: [auto_ack: false, frames: frames])
    assert %{input_format: nil, output_format: nil} = XaiRealtime.meta(session)
    assert {:error, :audio_not_configured} = XaiRealtime.send_audio(session, <<0, 0>>)
    assert {:ok, session} = XaiRealtime.configure(session, %{audio_mode: :pcm16})

    assert %{input_format: %{sample_rate: 16_000}, output_format: %{sample_rate: 24_000}} =
             XaiRealtime.meta(session)

    assert [%{"type" => "session.update"}] = session.transport_state.sent
    assert {:ok, _, {:output_audio, <<0, 0>>}} = XaiRealtime.recv(session, 1_000)
    assert {:ok, _} = XaiRealtime.send_audio(session, <<0, 0>>)
  end

  test "observed JSON ping and session legacy sentinels admit only exact canonical PCM" do
    acknowledgement = %{
      "type" => "session.updated",
      "session" => %{
        "input_audio_format" => "not specified",
        "output_audio_format" => "not specified",
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
    }

    frames = [
      %{"type" => "ping"},
      acknowledgement,
      %{"type" => "response.output_audio.delta", "delta" => "AAA="}
    ]

    {:ok, session} = raw_open(transport_opts: [auto_ack: false, frames: frames])
    assert {:error, :audio_not_configured} = XaiRealtime.send_audio(session, <<0, 0>>)
    assert {:ok, session} = XaiRealtime.configure(session, %{audio_mode: :pcm16})

    assert %{input_format: %{sample_rate: 16_000}, output_format: %{sample_rate: 24_000}} =
             XaiRealtime.meta(session)

    assert [%{"type" => "session.update"}] = session.transport_state.sent
    assert {:ok, _, {:output_audio, <<0, 0>>}} = XaiRealtime.recv(session, 1_000)
    assert {:ok, _} = XaiRealtime.send_audio(session, <<0, 0>>)
  end

  test "security regression: legacy sentinels never replace canonical formats or excuse conflicting declarations" do
    sentinels = %{
      "input_audio_format" => "not specified",
      "output_audio_format" => "not specified"
    }

    valid = Map.merge(confirmed_session(), sentinels)

    for payload <- [
          sentinels,
          update_in(valid, ["audio", "input"], &Map.delete(&1, "format")),
          update_in(valid, ["audio", "output"], &Map.delete(&1, "format")),
          put_in(valid, ["audio", "input", "format", "rate"], 24_000),
          put_in(valid, ["audio", "output", "format", "type"], "audio/opus"),
          put_in(valid, ["audio", "output", "transport"], "binary"),
          Map.put(valid, "input_audio_format", "pcm16"),
          Map.put(valid, "output_audio_format", "g711_ulaw"),
          Map.put(valid, "input_audio_format", nil),
          Map.put(valid, "output_audio_format", %{"type" => "not specified"}),
          Map.put(valid, "input_audio_format", %URI{}),
          Map.put(valid, "input_audio_format", ""),
          Map.put(valid, "input_audio_format", "Not specified"),
          Map.put(valid, "input_audio_format", "not specified "),
          Map.put(valid, "sample_rate", "not specified"),
          put_in(valid, ["audio", "input_audio_format"], "not specified"),
          put_in(valid, ["audio", "input", "input_audio_format"], "not specified"),
          put_in(valid, ["audio", "output", "output_audio_format"], "not specified"),
          put_in(valid, ["audio", "output", "format", "output_audio_format"], "not specified")
        ] do
      configuration_refusal_log(%{"type" => "session.updated", "session" => payload})
    end
  end

  test "security regression: legacy sentinel exception never applies to output audio deltas" do
    for key <- ["input_audio_format", "output_audio_format"] do
      frame = %{
        "type" => "response.output_audio.delta",
        "delta" => "AAA=",
        key => "not specified"
      }

      {:ok, session} = open(transport_opts: [frames: [frame]])
      assert {:error, :xai_audio_protocol_error} = XaiRealtime.recv(session, 1_000)
    end
  end

  test "security regression: JSON ping cannot replace acknowledgement or admit early media or unknown events" do
    for {tail, expected_error} <- [
          {[], :xai_transport_failed},
          {[%{"type" => "response.output_audio.delta", "delta" => "AAA="}],
           :xai_audio_protocol_error},
          {[%{"type" => "session.updated", "session" => %{}}], :xai_audio_protocol_error},
          {[%{"type" => "ping.extra"}], :xai_audio_protocol_error}
        ] do
      parent = self()

      {:ok, session} =
        raw_open(
          transport_opts: [
            auto_ack: false,
            frames: [%{"type" => "ping"} | tail],
            on_close: fn latest -> send(parent, {:ping_closed_handle, latest}) end
          ]
        )

      assert {:error, ^expected_error, latest} =
               XaiRealtime.configure(session, %{audio_mode: :pcm16})

      assert %{input_format: nil, output_format: nil} = XaiRealtime.meta(latest)
      assert {:error, :audio_not_configured} = XaiRealtime.send_audio(latest, <<0, 0>>)
      assert [%{"type" => "session.update"}] = latest.transport_state.sent
      assert latest.transport_state.frames == []
      closed = latest.transport_state
      assert_receive {:ping_closed_handle, ^closed}
      refute_receive {:ping_closed_handle, _}, 0
    end
  end

  test "repeated JSON pings retain the original deadline and close the latest receive handle" do
    parent = self()
    key = {__MODULE__, make_ref()}
    Process.put(key, 0)
    acknowledgement = %{"type" => "session.updated", "session" => confirmed_session()}

    {:ok, session} =
      raw_open(
        clock_fun: fn -> Process.get(key) end,
        transport_opts: [
          auto_ack: false,
          frames: List.duplicate(%{"type" => "ping"}, 3) ++ [acknowledgement],
          on_recv: fn -> Process.put(key, Process.get(key) + 11_000) end,
          on_close: fn latest -> send(parent, {:ping_deadline_closed, latest}) end
        ]
      )

    assert {:error, :timeout, latest} = XaiRealtime.configure(session, %{audio_mode: :pcm16})
    assert Process.get(key) == 33_000
    assert %{input_format: nil, output_format: nil} = XaiRealtime.meta(latest)
    assert {:error, :audio_not_configured} = XaiRealtime.send_audio(latest, <<0, 0>>)
    assert [%{"type" => "session.update"}] = latest.transport_state.sent
    assert latest.transport_state.frames == [acknowledgement]
    closed = latest.transport_state
    assert_receive {:ping_deadline_closed, ^closed}

    receive do
      {:ping_deadline_closed, handle} when handle != closed ->
        flunk("configuration timeout closed a stale receive handle")
    after
      0 -> :ok
    end
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

  test "security regression: configuration error and unexpected events log only fixed failure classes" do
    secret = "private-provider-error-and-event-sentinel"

    for {frame, reason} <- [
          {%{"type" => "error", "error" => %{"message" => secret, "code" => secret}},
           :provider_rejected_configuration},
          {%{"type" => secret, "payload" => secret}, :unexpected_provider_event}
        ] do
      log = configuration_refusal_log(frame)
      assert log =~ "stage=provider_configuration reason=#{reason}"
      refute log =~ secret
    end
  end

  test "provider configuration rejection projects exact known codes and request paths" do
    secret = "private-known-provider-error-message"

    for {code, param, code_class, parameter_class} <- [
          {"unknown_parameter", "session.audio.input.transcription", :unknown_parameter,
           :input_transcription},
          {"invalid_value", "session.voice", :invalid_value, :session_voice},
          {"invalid_request_error", "session.tools", :invalid_request, :session_tools}
        ] do
      log =
        configuration_refusal_log(%{
          "type" => "error",
          "error" => %{"code" => code, "param" => param, "message" => secret}
        })

      assert log =~ "stage=provider_error_code reason=#{code_class}"
      assert log =~ "stage=provider_error_parameter reason=#{parameter_class}"
      refute log =~ secret
    end
  end

  test "security regression: unknown or malformed provider error fields never enter diagnostics" do
    secret = "private-unknown-provider-error-sentinel"

    for error <- [
          secret,
          %{"code" => "invalid_value.#{secret}", "param" => "session.voice.#{secret}"},
          %{"code" => %{secret => secret}, "param" => RuntimeError.exception(secret)},
          %{"code" => :invalid_value, "param" => :session_voice, "message" => secret},
          %{"message" => secret}
        ] do
      log = configuration_refusal_log(%{"type" => "error", "error" => error})
      assert log =~ "stage=provider_error_code reason=unknown"
      assert log =~ "stage=provider_error_parameter reason=unknown"
      refute log =~ secret
      refute log =~ "RuntimeError"
    end
  end

  test "unexpected startup events expose only known event classes and envelope shapes" do
    secret = "private-unexpected-startup-envelope"

    for {frame, event, session_shape, audio_shape} <- [
          {%{"type" => "session.created", "audio" => %{"private" => secret}}, :session_created,
           :absent, :map},
          {%{"type" => "session.created", "session" => nil, "audio" => nil}, :session_created,
           :null, :null},
          {%{"type" => "session.created", "session" => secret, "audio" => secret},
           :session_created, :non_map, :non_map},
          {%{"type" => "rate_limits.updated", "session" => %{"private" => secret}},
           :rate_limits_updated, :map, :absent},
          {%{"type" => "response.created"}, :response_created, :absent, :absent},
          {%{"type" => "response.output_audio.delta", "delta" => secret}, :media_before_ack,
           :absent, :absent}
        ] do
      log = configuration_refusal_log(frame)
      assert log =~ "stage=provider_event_type reason=#{event}"
      assert log =~ "stage=provider_session_envelope reason=#{session_shape}"
      assert log =~ "stage=provider_top_level_audio reason=#{audio_shape}"
      refute log =~ secret
    end
  end

  test "security regression: malformed or unknown startup event types never enter diagnostic text" do
    secret = "private-unknown-event-type"

    for {frame, event} <- [
          {%{"private" => secret}, :missing_event_type},
          {%{"type" => %{"private" => secret}}, :invalid_event_type},
          {%{"type" => :session_created}, :invalid_event_type},
          {%{"type" => "session.created.#{secret}"}, :unknown_event_type}
        ] do
      log = configuration_refusal_log(frame)
      assert log =~ "stage=provider_event_type reason=#{event}"
      refute log =~ secret
    end
  end

  test "security regression: invalid format acknowledgement logs bounded shape without weakening refusal" do
    secret = "private-format-acknowledgement-sentinel"

    for {payload, reason} <- [
          {%{}, :missing_audio_formats},
          {put_in(confirmed_session(), ["audio", "input", "format", "rate"], 8_000),
           :input_format_mismatch},
          {put_in(confirmed_session(), ["audio", "output", "format", "rate"], 8_000),
           :output_format_mismatch},
          {put_in(confirmed_session(), ["audio", "output", "transport"], "binary"),
           :non_json_transport},
          {put_in(confirmed_session(), ["audio", "input", "format", "extra"], secret),
           :conflicting_format_metadata},
          {Map.put(confirmed_session(), "output_audio_format", secret),
           :conflicting_format_metadata}
        ] do
      frame = %{"type" => "session.updated", "session" => Map.put(payload, "private", secret)}
      log = configuration_refusal_log(frame)
      assert log =~ "stage=provider_configuration reason=invalid_format_acknowledgement"
      assert log =~ "stage=provider_format_acknowledgement reason=#{reason}"
      refute log =~ secret
    end
  end

  defp configuration_refusal_log(frame) do
    parent = self()

    {:ok, session} =
      raw_open(
        transport_opts: [
          auto_ack: false,
          frames: [frame],
          on_close: fn latest -> send(parent, {:configuration_closed, latest}) end
        ]
      )

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:error, :xai_audio_protocol_error, latest} =
               XaiRealtime.configure(session, %{audio_mode: :pcm16})

      assert %{input_format: nil, output_format: nil} = XaiRealtime.meta(latest)
      closed = latest.transport_state
      assert_receive {:configuration_closed, ^closed}
      refute_receive {:configuration_closed, _}, 0
      assert {:error, :audio_not_configured} = XaiRealtime.send_audio(latest, <<0, 0>>)
    end)
  end

  test "PCM-mode configuration requests provider audio while retaining exact JSON format acknowledgement" do
    {:ok, session} = raw_open([])
    assert {:ok, session} = XaiRealtime.configure(session, %{audio_mode: :pcm16})
    [update] = session.transport_state.sent
    refute update["session"]["modalities"] == ["text"]
    assert update["session"]["audio"]["input"]["format"]["rate"] == 16_000
    assert update["session"]["audio"]["output"]["transport"] == "json"

    assert %{input_format: %{sample_rate: 16_000}, output_format: %{sample_rate: 24_000}} =
             XaiRealtime.meta(session)

    assert {:ok, _} = XaiRealtime.send_audio(session, <<0, 0>>)
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
    oversized = :binary.copy(<<0, 0>>, div(PcmFormat.max_bytes(), 2) + 1)
    invalid = [nil, "", "%%%", "AQ==", Base.encode64(oversized), 12]

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
