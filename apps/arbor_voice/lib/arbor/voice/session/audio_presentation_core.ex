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
