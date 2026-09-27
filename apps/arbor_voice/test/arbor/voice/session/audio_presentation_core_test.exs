defmodule Arbor.Voice.Session.AudioPresentationCoreTest do
  use ExUnit.Case, async: true
  alias Arbor.Voice.PcmFormat
  alias Arbor.Voice.Redacted
  alias Arbor.Voice.Session.{AudioPresentationCore, ManagedDispatchCore}
  @moduletag :fast
  @moduletag spec: "VOICE-13"

  defp input do
    %{
      provider_terminal_text: "The result is ready.",
      final_text: "The result is ready.",
      verdict: {:speak, "The result is ready."},
      guarded_text: "The result is ready.",
      audio: Redacted.new([<<1, 2>>, <<3, 4>>]),
      audio_format: PcmFormat.mono_s16le(24_000),
      authorized_format: PcmFormat.mono_s16le(24_000)
    }
  end

  test "only exact authoritative text, guarded speech and matching format release PCM" do
    assert AudioPresentationCore.render(input()) == %{
             verdict: {:speak, "The result is ready."},
             spoken_text: "The result is ready.",
             audio: <<1, 2, 3, 4>>,
             format: PcmFormat.mono_s16le(24_000)
           }

    for changed <- [
          Map.put(input(), :final_text, "The result is ready. "),
          Map.put(input(), :authorized_format, PcmFormat.mono_s16le(16_000)),
          Map.put(input(), :audio_format, nil),
          Map.put(input(), :audio, Redacted.new([])),
          Map.put(input(), :audio, Redacted.new([<<1>>])),
          Map.put(input(), :audio, <<1, 2>>)
        ] do
      assert %{audio: nil, format: nil, spoken_text: "The result is ready."} =
               AudioPresentationCore.render(changed)
    end
  end

  test "D1 source rewrite suppresses provider audio while retaining guarded source confirmation" do
    final_text = ManagedDispatchCore.confirmation_sentence()

    rewritten = %{
      input()
      | final_text: final_text,
        verdict: {:speak, final_text},
        guarded_text: final_text
    }

    assert %{audio: nil, format: nil, spoken_text: ^final_text} =
             AudioPresentationCore.render(rewritten)
  end

  test "security regression: a rewritten guard suppresses otherwise matching provider PCM" do
    rewritten = %{
      input()
      | verdict: {:speak, "See your screen."},
        guarded_text: "See your screen."
    }

    assert %{
             verdict: {:speak, "See your screen."},
             spoken_text: "See your screen.",
             audio: nil,
             format: nil
           } = AudioPresentationCore.render(rewritten)
  end

  test "truncated and sensitive verdicts preserve only their guarded presentation" do
    for {tag, spoken_text} <- [{:speak_truncated, "See your screen."}, {:screen_only, ""}] do
      verdict = {tag, "See your screen."}
      candidate = %{input() | verdict: verdict, guarded_text: "See your screen."}

      assert %{verdict: ^verdict, spoken_text: ^spoken_text, audio: nil, format: nil} =
               AudioPresentationCore.render(candidate)
    end
  end

  test "malformed or mismatched guards cannot fall back to raw provider text or audio" do
    for malformed <- [
          %{input() | verdict: :speak},
          %{input() | guarded_text: nil},
          %{input() | guarded_text: "unguarded replacement"},
          %{input() | verdict: {:speak, <<255>>}, guarded_text: <<255>>},
          %{input() | verdict: {:speak, ""}, guarded_text: ""},
          %{}
        ] do
      assert %{verdict: {:screen_only, ""}, spoken_text: "", audio: nil, format: nil} =
               AudioPresentationCore.render(malformed)
    end
  end
end
