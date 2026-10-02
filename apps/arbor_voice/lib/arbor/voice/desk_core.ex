defmodule Arbor.Voice.DeskCore do
  @moduledoc false
  alias Arbor.Voice.Contracts.AudioTurn
  alias Arbor.Voice.PcmFormat

  @keys [
    :session_token,
    :signed_request,
    :duration_ms,
    :input_device,
    :output_device,
    :origin_node,
    :mode,
    :expected_engagement_id
  ]
  def options(user, agent, opts, server_node) do
    with true <- id?(user) and id?(agent),
         true <- is_list(opts) and Keyword.keyword?(opts),
         keys <- Keyword.keys(opts),
         true <- length(keys) == length(Enum.uniq(keys)) and Enum.all?(keys, &(&1 in @keys)),
         true <- Enum.count(keys, &(&1 in [:session_token, :signed_request])) == 1,
         true <- proof?(opts),
         mode <- Keyword.get(opts, :mode, :conversation),
         true <- mode in [:conversation, :loopback],
         duration <- Keyword.get(opts, :duration_ms, 3_000),
         true <- is_integer(duration) and duration in 100..10_000,
         input <- Keyword.get(opts, :input_device, :default),
         output <- Keyword.get(opts, :output_device, :default),
         true <- device?(input) and device?(output),
         expected <- Keyword.get(opts, :expected_engagement_id),
         true <- is_nil(expected) or engagement_id?(expected),
         origin <- Keyword.get(opts, :origin_node),
         true <- origin == nil or same_host?(origin, server_node) do
      {:ok,
       %{
         user: user,
         agent: agent,
         duration_ms: duration,
         input_device: input,
         output_device: output,
         mode: mode,
         expected_engagement_id: expected,
         origin_node: origin,
         proof: Keyword.take(opts, [:session_token, :signed_request])
       }}
    else
      _ -> {:error, :invalid_desk_options}
    end
  end

  defp engagement_id?(id),
    do: is_binary(id) and byte_size(id) == 36 and String.match?(id, ~r/\Aeng_[0-9a-f]{32}\z/)

  def same_host?(origin, server) when is_atom(origin) and is_atom(server) do
    case {host(origin), host(server)} do
      {{:ok, host}, {:ok, host}} -> true
      _ -> false
    end
  end

  def same_host?(_, _), do: false

  defp host(node) do
    case String.split(Atom.to_string(node), "@") do
      [name, host] when byte_size(name) > 0 and byte_size(host) > 0 and byte_size(host) <= 255 ->
        if String.contains?(host, [" ", "\n", "\r", "\t", <<0>>]),
          do: :error,
          else: {:ok, String.downcase(host)}

      _ ->
        :error
    end
  end

  def id?(id),
    do: is_binary(id) and byte_size(id) in 1..256 and String.valid?(id) and String.trim(id) != ""

  def operation_id?(id),
    do: is_binary(id) and byte_size(id) == 43 and String.match?(id, ~r/\A[A-Za-z0-9_-]+\z/)

  defp device?(:default), do: true
  defp device?(id), do: is_integer(id) and id in 0..65_535

  defp proof?(opts) do
    case Keyword.fetch(opts, :session_token) do
      {:ok, token} ->
        is_binary(token) and byte_size(token) in 1..4_096

      :error ->
        is_map(opts[:signed_request]) and :erlang.external_size(opts[:signed_request]) <= 16_384
    end
  end

  # The final provider media is already guarded by Voice. Enforce its exact
  # closed presentation shape again at the device boundary; never use reply.
  def presentation(
        %{verdict: {kind, text}, spoken_text: spoken, audio: audio, format: format} = p
      )
      when map_size(p) == 4 and kind in [:speak, :speak_truncated, :screen_only] do
    cond do
      not presentation_text?(text) ->
        {:error, :invalid_presentation}

      kind == :screen_only and spoken != "" ->
        {:error, :invalid_presentation}

      kind != :screen_only and spoken != text ->
        {:error, :invalid_presentation}

      is_nil(audio) and is_nil(format) ->
        {:ok, :screen_only}

      kind != :speak ->
        {:error, :invalid_presentation}

      not presentation_audio?(audio) ->
        {:error, :invalid_presentation}

      PcmFormat.validate(format) != :ok ->
        {:error, :invalid_presentation}

      true ->
        {:ok, %{pcm: audio, sample_rate: format.sample_rate, channels: 1, sample_format: :s16le}}
    end
  end

  def presentation(_), do: {:error, :invalid_presentation}

  defp presentation_text?(text),
    do: is_binary(text) and byte_size(text) <= 8_192 and String.valid?(text)

  defp presentation_audio?(audio),
    do: is_binary(audio) and byte_size(audio) in 2..8_388_608 and rem(byte_size(audio), 2) == 0

  def result(%{operation_id: id, reply: reply, input_transcript: transcript, presentation: p}, id) do
    with true <- AudioTurn.text?(reply) and AudioTurn.text?(transcript),
         {:ok, _} <- presentation(p) do
      {:ok,
       %{
         reply: reply,
         input_transcript: transcript,
         spoken_text: p.spoken_text,
         verdict: elem(p.verdict, 0)
       }}
    else
      _ -> {:error, :invalid_presentation}
    end
  end

  def result(_, _), do: {:error, :invalid_presentation}

  def error(reason)
      when reason in [
             :invalid_desk_options,
             :conversation_unauthorized,
             :device_busy,
             :device_unavailable,
             :permission_denied,
             :unsupported_format,
             :capture_failed,
             :playback_failed,
             :invalid_presentation,
             :cleanup_pending,
             :lease_expired,
             :cancelled,
             :timeout,
             :start_failed,
             :budget_exhausted,
             :turn_failed,
             :transcript_record_failed,
             :session_stopped,
             :presentation_busy
           ],
      do: reason

  def error(_), do: :operation_failed
end
