defmodule Arbor.Voice.Session.AudioPresentationCore do
  @moduledoc """
  Pure presentation selection for an already committed audio turn.

  The shell obtains Speakable's verdict and guard result for the exact final
  authoritative text after persistence and checks current conversation authority
  before calling this core and again before publication. This core never turns a
  cached boolean into authorization.
  """

  alias Arbor.Voice.Contracts.AudioTurn
  alias Arbor.Voice.PcmFormat
  alias Arbor.Voice.Redacted

  @silent %{verdict: {:screen_only, ""}, spoken_text: "", audio: nil, format: nil}

  @doc "Select only guarded text and audio for the exact authoritative final text."
  @spec render(map()) :: AudioTurn.presentation()
  def render(%{verdict: {tag, text} = verdict, guarded_text: guarded} = input)
      when tag in [:speak, :speak_truncated, :screen_only] and text == guarded do
    if AudioTurn.text?(guarded) do
      spoken_text = if tag == :screen_only, do: "", else: guarded
      presentation = %{verdict: verdict, spoken_text: spoken_text, audio: nil, format: nil}
      maybe_audio(presentation, input)
    else
      @silent
    end
  end

  def render(_), do: @silent

  @doc "Return the unchanged presentation and a fixed primary observation reason."
  def render_with_reason(input) do
    presentation = render(input)
    {presentation, presentation_reason(presentation, input)}
  end

  defp presentation_reason(%{audio: audio}, _input) when is_binary(audio),
    do: :audio_retained

  defp presentation_reason(_presentation, %{verdict: {tag, text}, guarded_text: guarded} = input)
       when tag in [:speak, :speak_truncated, :screen_only] and text == guarded do
    cond do
      not AudioTurn.text?(guarded) -> :invalid_guard
      tag == :screen_only -> :screen_only_classification
      tag == :speak_truncated -> :truncated_guard
      true -> withheld_audio_reason(input, guarded)
    end
  end

  defp presentation_reason(_presentation, _input), do: :invalid_guard

  defp withheld_audio_reason(
         %{
           provider_terminal_text: provider_text,
           final_text: final_text,
           audio: audio,
           audio_format: format,
           authorized_format: authorized
         },
         guarded
       ) do
    cond do
      provider_text != final_text -> :raw_text_mismatch
      final_text != guarded -> :guard_text_mismatch
      format != authorized or PcmFormat.validate(format) != :ok -> :format_mismatch
      match?(%Redacted{value: []}, audio) -> :provider_audio_absent
      true -> :invalid_provider_audio
    end
  end

  defp withheld_audio_reason(_input, _guarded), do: :invalid_presentation_input

  defp maybe_audio(%{verdict: {:speak, guarded}} = presentation, %{
         provider_terminal_text: provider_text,
         final_text: final_text,
         audio: %Redacted{} = audio,
         audio_format: format,
         authorized_format: format
       })
       when provider_text == final_text and final_text == guarded do
    with true <- AudioTurn.text?(final_text),
         :ok <- PcmFormat.validate(format),
         {:ok, pcm} <- AudioTurn.output_pcm(Redacted.value(audio)) do
      %{presentation | audio: pcm, format: format}
    else
      _ -> presentation
    end
  end

  defp maybe_audio(presentation, _input), do: presentation
end
