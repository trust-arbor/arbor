defmodule Arbor.Voice.Diagnostics do
  @moduledoc false
  require Logger
  alias Arbor.Voice.Contracts.AudioTurn
  alias Arbor.Voice.Redacted
  alias Arbor.Voice.Session.AudioTurnCore

  # Observations only: never retain or inspect collaborator data, and never
  # use logging success as evidence of authorization or resource closure.
  @stages [
    :admitting,
    :capture,
    :starting,
    :turn,
    :tool_execution,
    :audio_admission,
    :audio_handoff,
    :audio_operation,
    :audio_receive,
    :audio_reduce,
    :audio_final_authority,
    :audio_final_liveness,
    :audio_persistence,
    :backend_receive,
    :backend_send_audio,
    :provider_runtime_error_code,
    :provider_runtime_error_parameter,
    :provider_runtime_error_envelope,
    :provider_runtime_error_type_shape,
    :provider_runtime_error_code_shape,
    :provider_runtime_error_parameter_shape,
    :provider_runtime_error_type,
    :provider_runtime_last_effect,
    :provider_runtime_commit_seen,
    :provider_runtime_transcript_seen,
    :provider_runtime_response_seen,
    :presenting,
    :cleanup_pending,
    :desk_admission,
    :desk_configuration,
    :desk_budget,
    :route_resolution,
    :conversation_admission,
    :budget_readiness,
    :budget_reservation,
    :route_grant,
    :backend_open,
    :backend_configure,
    :backend_metadata,
    :provider_configuration,
    :provider_format_acknowledgement,
    :provider_error_code,
    :provider_error_parameter,
    :provider_event_type,
    :provider_session_envelope,
    :provider_top_level_audio
  ]
  @reasons [
    :start_failed,
    :operation_failed,
    :conversation_unauthorized,
    :budget_exhausted,
    :disabled,
    :invalid_config,
    :invalid_opts,
    :invalid_user_id,
    :invalid_agent_id,
    :unsupported,
    :not_node_restart,
    :unavailable,
    :capture_failed,
    :playback_failed,
    :device_unavailable,
    :device_busy,
    :permission_denied,
    :invalid_media,
    :invalid_presentation,
    :cleanup_pending,
    :cancelled,
    :timeout,
    :lease_expired,
    :caller_down,
    :turn_failed,
    :tool_timeout,
    :turn_timeout,
    :turn_not_current,
    :audio_operation_failed,
    :audio_cancelled,
    :owner_timeout,
    :session_closed,
    :invalid_backend_event,
    :backend_event_error,
    :tool_before_completed_transcript,
    :event_after_terminal,
    :invalid_input_transcript,
    :input_transcript_nonbinary,
    :input_transcript_empty,
    :input_transcript_oversized,
    :input_transcript_invalid_utf8,
    :input_transcript_blank,
    :input_transcript_conflicting,
    :invalid_output_audio,
    :output_audio_nonbinary,
    :output_audio_empty,
    :output_audio_oversized,
    :output_audio_odd_bytes,
    :output_audio_total_byte_limit,
    :invalid_output_text,
    :invalid_tool_call,
    :invalid_terminal_event,
    :transcript_record_failed,
    :session_stopped,
    :operation_timeout,
    :backend_callback_fault,
    :backend_open_failed,
    :backend_open_uncertain,
    :backend_partial_failure,
    :backend_callback_failed,
    :backend_effect_denied,
    :invalid_backend_meta,
    :backend_close_failed,
    :invalid_backend_return,
    :xai_audio_protocol_error,
    :xai_transport_failed,
    :provider_rejected_configuration,
    :unexpected_provider_event,
    :invalid_format_acknowledgement,
    :missing_audio_formats,
    :input_format_mismatch,
    :output_format_mismatch,
    :non_json_transport,
    :conflicting_format_metadata,
    :invalid_request,
    :server_error,
    :invalid_value,
    :unknown_parameter,
    :unsupported_parameter,
    :missing_required_parameter,
    :invalid_type,
    :invalid_api_key,
    :insufficient_quota,
    :rate_limit_exceeded,
    :session,
    :session_voice,
    :session_turn_detection,
    :session_tools,
    :session_instructions,
    :session_modalities,
    :session_audio,
    :input_audio,
    :input_format,
    :input_format_type,
    :input_format_rate,
    :input_transport,
    :input_transcription,
    :output_audio,
    :output_format,
    :output_format_type,
    :output_format_rate,
    :output_transport,
    :session_created,
    :session_updated,
    :conversation_created,
    :provider_error_event,
    :rate_limits_updated,
    :response_created,
    :media_before_ack,
    :missing_event_type,
    :invalid_event_type,
    :unknown_event_type,
    :absent,
    :null,
    :map,
    :non_map,
    :binary,
    :nonbinary,
    :observed,
    :not_observed,
    :connect,
    :configure,
    :text_item,
    :text_response,
    :audio_append,
    :audio_commit,
    :audio_response,
    :tool_result_item,
    :tool_result_response,
    :unknown,
    :unexpected_result
  ]

  @presentation_reasons [
    :audio_retained,
    :invalid_guard,
    :screen_only_classification,
    :truncated_guard,
    :raw_text_mismatch,
    :guard_text_mismatch,
    :format_mismatch,
    :provider_audio_absent,
    :invalid_provider_audio,
    :invalid_presentation_input,
    :presentation_authority_unavailable,
    :presentation_error
  ]

  # Deliberate speech suppression is an observation, not an operation failure.
  # Only fixed labels enter the logger; no text, PCM, proof or operation ID.
  def presentation_observation(reason) do
    reason = if reason in @presentation_reasons, do: reason, else: :unclassified
    Logger.info("[Voice] presentation observation reason=#{reason}")
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  def observe(stage, {:error, reason} = result) do
    failure(stage, reason)
    result
  end

  def observe(_stage, result), do: result

  # Unlike observe/2, this also records a non-error refusal (false, :failed,
  # or an unexpected collaborator shape) without changing that exact value.
  def expect(stage, result, expected) do
    if result !== expected, do: failure(stage, result)
    result
  end

  # Called only after the real reducer rejects. Project structural facts into
  # fixed labels; never inspect transcript, PCM, tool arguments, IDs or errors.
  def audio_rejected(core, event), do: failure(:audio_reduce, audio_rejection(core, event))

  defp audio_rejection(core, {:input_transcript, transcript}) do
    cond do
      not is_binary(transcript) -> :input_transcript_nonbinary
      byte_size(transcript) == 0 -> :input_transcript_empty
      byte_size(transcript) > AudioTurn.max_text_bytes() -> :input_transcript_oversized
      not String.valid?(transcript) -> :input_transcript_invalid_utf8
      String.trim(transcript) == "" -> :input_transcript_blank
      true -> transcript_conflict(core, transcript)
    end
  end

  defp audio_rejection(%Redacted{value: %{terminal: terminal}}, _)
       when not is_nil(terminal),
       do: :event_after_terminal

  defp audio_rejection(%Redacted{value: %{transcript: nil}}, {:tool_call, _}),
    do: :tool_before_completed_transcript

  defp audio_rejection(core, {:output_audio, chunk}) do
    cond do
      not is_binary(chunk) -> :output_audio_nonbinary
      byte_size(chunk) == 0 -> :output_audio_empty
      byte_size(chunk) > AudioTurn.max_output_event_bytes() -> :output_audio_oversized
      rem(byte_size(chunk), 2) != 0 -> :output_audio_odd_bytes
      true -> output_audio_limit(core, chunk)
    end
  end

  defp audio_rejection(_core, {:output_text_delta, _}), do: :invalid_output_text
  defp audio_rejection(_core, {:tool_call, _}), do: :invalid_tool_call
  defp audio_rejection(_core, {:turn_done, _}), do: :invalid_terminal_event
  defp audio_rejection(_core, {:error, _}), do: :provider_error_event
  defp audio_rejection(_, _), do: :invalid_backend_event

  # An exact duplicate is a pure no-op accepted by the real reducer. Use that
  # probe to distinguish conflicting completion from malformed core state
  # without copying the reducer's internal validity rules into diagnostics.
  defp transcript_conflict(%Redacted{value: %{transcript: previous}} = core, transcript)
       when is_binary(previous) and previous != transcript do
    if AudioTurn.text?(previous) and
         AudioTurnCore.reduce(core, {:input_transcript, previous}) == {:continue, core} do
      :input_transcript_conflicting
    else
      :invalid_input_transcript
    end
  end

  defp transcript_conflict(_, _), do: :invalid_input_transcript

  # Empty text is a pure no-op on a valid, nonterminal core. Only diagnose the
  # cumulative byte bound after that probe; malformed state keeps the generic reason.
  defp output_audio_limit(%Redacted{value: %{total_audio_bytes: total}} = core, chunk)
       when is_integer(total) and total >= 0 do
    if total + byte_size(chunk) > AudioTurn.max_output_bytes() and
         AudioTurnCore.reduce(core, {:output_text_delta, ""}) == {:continue, core} do
      :output_audio_total_byte_limit
    else
      :invalid_output_audio
    end
  end

  defp output_audio_limit(_, _), do: :invalid_output_audio

  def failure(stage, reason) do
    stage = if stage in @stages, do: stage, else: :unknown
    reason = bounded_reason(reason)
    Logger.warning("[Voice] operation failed stage=#{stage} reason=#{reason}")
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp bounded_reason(reason) when reason in @reasons, do: reason
  defp bounded_reason({:error, reason}) when reason in @reasons, do: reason
  defp bounded_reason({:error, reason, _}) when reason in @reasons, do: reason
  defp bounded_reason(_), do: :unclassified
end
