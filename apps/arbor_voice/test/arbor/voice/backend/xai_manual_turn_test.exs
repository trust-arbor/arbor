defmodule Arbor.Voice.Backend.XaiManualTurnTest do
  use ExUnit.Case, async: true

  alias Arbor.Voice.Backend.XaiRealtime
  alias Arbor.Voice.Test.XaiRealtimeFakeTransport, as: FakeTransport

  @moduletag :fast

  test "manual turn configuration uses nested null type with independent provider acknowledgement" do
    # xAI documents turn_detection.type = null for client-controlled turns:
    # https://docs.x.ai/developers/model-capabilities/audio/speech-to-speech
    # Build the acknowledgement independently; echoing the request hid the
    # original top-level-null bug. Observed provider acknowledgements omit
    # turn_detection, so this test does not invent an acknowledgement guarantee.
    acknowledgement = %{
      "type" => "session.updated",
      "session" => %{
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

    {:ok, session} =
      XaiRealtime.open(
        transport: FakeTransport,
        transport_opts: [auto_ack: false, frames: [acknowledgement]],
        effect_authorizer: fn _, _ -> :allow end,
        oauth_resolver: fn :xai -> {:ok, "fixture-token"} end
      )

    refute Map.has_key?(acknowledgement["session"], "turn_detection")
    assert {:ok, session} = XaiRealtime.configure(session, %{audio_mode: :pcm16})

    assert %{input_format: %{sample_rate: 16_000}, output_format: %{sample_rate: 24_000}} =
             XaiRealtime.meta(session)

    [configuration] = session.transport_state.sent |> Jason.encode!() |> Jason.decode!()
    assert configuration["type"] == "session.update"
    assert configuration["session"]["turn_detection"] == %{"type" => nil}

    assert {:ok, session} = XaiRealtime.send_audio(session, <<0, 0>>)

    assert [
             ^configuration,
             %{"type" => "input_audio_buffer.append", "audio" => "AAA="},
             %{"type" => "input_audio_buffer.commit"},
             %{"type" => "response.create"}
           ] = session.transport_state.sent |> Jason.encode!() |> Jason.decode!()

    assert session.transport_state.frames == []
    assert :ok = XaiRealtime.close(session)
  end
end
