defmodule Arbor.Voice.Session.AudioTurnCore do
  @moduledoc """
  Pure audio event reduction. Only completed STT is authoritative input.

  Text/tool validation delegates to TurnCore. One transcript survives tool-wave
  resets, while intermediate text/audio cannot become final presentation. PCM
  uses bounded reversed iodata under Redacted; neither Inspect nor error results
  expose it. No clock, authority, persistence or provider effect lives here.
  """

  alias Arbor.Voice.Contracts.AudioTurn
  alias Arbor.Voice.PcmFormat
  alias Arbor.Voice.Redacted
  alias Arbor.Voice.Session.TurnCore

  @type t :: Redacted.t()
  @type outcome ::
          {:continue, t()}
          | {:cycle_reset, t()}
          | {:admit_tool, t(), TurnCore.admit_call()}
          | {:done, Redacted.t()}
          | {:error, :protocol_error}

  @spec new(PcmFormat.t()) :: {:ok, t()} | {:error, :invalid_audio_format}
  def new(format) do
    with :ok <- PcmFormat.validate(format) do
      {:ok,
       Redacted.new(%{
         text: TurnCore.new(),
         transcript: nil,
         output_format: format,
         audio_rev: [],
         audio_bytes: 0,
         total_audio_bytes: 0,
         terminal: nil
       })}
    end
  end

  @spec reduce(t(), term()) :: outcome()
  def reduce(
        %Redacted{
          value:
            %{
              text: %{text_acc: acc, tool_wave: wave, seen_tool_ids: %MapSet{}},
              transcript: transcript,
              output_format: format,
              audio_rev: chunks,
              audio_bytes: bytes,
              total_audio_bytes: total,
              terminal: terminal
            } = state
        },
        event
      )
      when map_size(state) == 7 and is_binary(acc) and is_boolean(wave) and
             is_list(chunks) and is_integer(bytes) and bytes >= 0 and
             is_integer(total) and total >= bytes do
    if (is_nil(transcript) or AudioTurn.text?(transcript)) and
         total <= AudioTurn.max_output_bytes() and valid_terminal?(terminal) and
         PcmFormat.validate(format) == :ok do
      reduce_state(state, event)
    else
      {:error, :protocol_error}
    end
  end

  def reduce(_, _), do: {:error, :protocol_error}

  defp reduce_state(state, {:input_transcript, transcript}) when is_map(state) do
    cond do
      not AudioTurn.text?(transcript) -> {:error, :protocol_error}
      state.transcript == transcript -> {:continue, Redacted.new(state)}
      not is_nil(state.transcript) -> {:error, :protocol_error}
      true -> maybe_complete(%{state | transcript: transcript})
    end
  end

  defp reduce_state(%{terminal: terminal}, _event) when not is_nil(terminal),
    do: {:error, :protocol_error}

  defp reduce_state(%{transcript: nil}, {:tool_call, _}),
    do: {:error, :protocol_error}

  defp reduce_state(state, {:output_audio, chunk}) when is_map(state) do
    if AudioTurn.output_chunk?(chunk) and
         state.total_audio_bytes + byte_size(chunk) <= AudioTurn.max_output_bytes() do
      state = %{state | total_audio_bytes: state.total_audio_bytes + byte_size(chunk)}

      next =
        if state.text.tool_wave do
          state
        else
          %{
            state
            | audio_rev: [chunk | state.audio_rev],
              audio_bytes: state.audio_bytes + byte_size(chunk)
          }
        end

      {:continue, Redacted.new(next)}
    else
      {:error, :protocol_error}
    end
  end

  defp reduce_state(%{text: text_core} = state, event) do
    case TurnCore.reduce(text_core, event) do
      {:continue, text} ->
        {:continue, Redacted.new(%{state | text: text})}

      {:cycle_reset, text} ->
        {:cycle_reset, Redacted.new(%{state | text: text, audio_rev: [], audio_bytes: 0})}

      {:admit_tool, text, call} ->
        {:admit_tool, Redacted.new(%{state | text: text, audio_rev: [], audio_bytes: 0}), call}

      {:done, provider_text} ->
        {:turn_done, %{text: terminal_text}} = event

        maybe_complete(%{
          state
          | terminal: %{provider_text: provider_text, provider_terminal_text: terminal_text}
        })

      {:error, :protocol_error} = error ->
        error
    end
  end

  defp reduce_state(_, _), do: {:error, :protocol_error}

  defp valid_terminal?(nil), do: true

  defp valid_terminal?(%{provider_text: text, provider_terminal_text: terminal}) do
    AudioTurn.text?(text) and is_binary(terminal) and String.valid?(terminal) and
      byte_size(terminal) <= AudioTurn.max_text_bytes()
  end

  defp valid_terminal?(_), do: false

  defp maybe_complete(%{terminal: nil} = state), do: {:continue, Redacted.new(state)}
  defp maybe_complete(%{transcript: nil} = state), do: {:continue, Redacted.new(state)}

  defp maybe_complete(state) do
    {:done,
     Redacted.new(%{
       input_transcript: state.transcript,
       provider_text: state.terminal.provider_text,
       provider_terminal_text: state.terminal.provider_terminal_text,
       audio: Redacted.new(Enum.reverse(state.audio_rev)),
       audio_bytes: state.audio_bytes,
       output_format: state.output_format
     })}
  end
end
