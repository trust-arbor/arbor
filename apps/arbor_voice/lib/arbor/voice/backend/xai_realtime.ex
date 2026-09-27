defmodule Arbor.Voice.Backend.XaiRealtime do
  @moduledoc """
  `Arbor.Voice.RealtimeBackend` implementation for xAI's Realtime API,
  extracted from the verified `Arbor.Agent.Prototypes.XaiVoiceOrchestrator`
  prototype (which stays in place and continues to work standalone).

  Socket operations (WebSocket upgrade/send/recv) live behind
  `Arbor.Voice.Backend.XaiRealtime.Transport`, selected via `opts[:transport]`
  and defaulting to the real Mint implementation, so `recv/2`'s event mapping
  is unit-testable from scripted frames without any network access.

  `:effect_authorizer` is a required internal arity-2 callback. It receives
  only a closed effect atom and `egress_route/0`; missing, denied, malformed,
  or faulting callbacks fail closed before the corresponding transport effect.
  """

  @behaviour Arbor.Voice.RealtimeBackend

  alias Arbor.LLM.OAuth
  alias Arbor.Voice.Backend.XaiRealtime.Transport
  alias Arbor.Voice.{BackendWorker, PcmFormat}

  @default_host "api.x.ai"
  @default_port 443
  @default_path "/v1/realtime?model=grok-voice-latest"
  @authorization_error :xai_effect_not_authorized
  @send_timeout_ms 30_000
  @max_output_bytes 65_536
  @alternate_format_fields [
    "audio_format",
    "encoding",
    "sample_rate",
    "channels",
    "sample_format",
    "rate",
    "input_audio_format",
    "output_audio_format",
    "input_format",
    "output_format"
  ]
  @effects [
    :connect,
    :configure,
    :text_item,
    :text_response,
    :audio_append,
    :audio_commit,
    :audio_response,
    :tool_result_item,
    :tool_result_response
  ]

  @type effect ::
          :connect
          | :configure
          | :text_item
          | :text_response
          | :audio_append
          | :audio_commit
          | :audio_response
          | :tool_result_item
          | :tool_result_response

  @type effect_authorizer ::
          (effect(), Arbor.Voice.RealtimeBackend.egress_route() ->
             :allow | {:error, term()})

  @impl true
  def egress_route do
    %{
      destination: @default_host,
      provider: "xai",
      runtime: "arbor",
      model: "grok-voice-latest"
    }
  end

  defmodule Session do
    @moduledoc false
    @derive {Inspect, except: [:transport_state, :effect_authorizer, :acc]}
    @enforce_keys [:transport_mod, :transport_state, :clock_fun, :effect_authorizer]
    defstruct [
      :transport_mod,
      :transport_state,
      :clock_fun,
      :effect_authorizer,
      input_format: nil,
      output_format: nil,
      acc: ""
    ]
  end

  # ── open/1 ──

  @impl true
  def open(opts) do
    effect_authorizer = Keyword.get(opts, :effect_authorizer)
    resolver = Keyword.get(opts, :oauth_resolver, &OAuth.access_token/1)
    transport_mod = Keyword.get(opts, :transport, Transport)
    clock_fun = Keyword.get(opts, :clock_fun, fn -> System.monotonic_time(:millisecond) end)
    scripted = Keyword.get(opts, :transport_opts, [])

    canonical = [
      host: @default_host,
      port: @default_port,
      path: @default_path,
      clock_fun: clock_fun
    ]

    with :ok <- authorize_effect(effect_authorizer, :connect) do
      case resolver.(:xai) do
        {:ok, token} when is_binary(token) ->
          # Keyword.merge/2: keys in the 2nd list win on collision -- canonical
          # is 2nd, so no caller input, including transport_opts, can override
          # resolved credential or source-owned connection fields.
          connect_opts = Keyword.merge(scripted, Keyword.put(canonical, :token, token))
          connect_and_wrap(transport_mod, connect_opts, clock_fun, effect_authorizer)

        {:error, _reason} = err ->
          err

        _other ->
          {:error, :invalid_oauth_resolver_result}
      end
    end
  rescue
    _exception -> {:error, :oauth_resolver_failed}
  end

  # Once a token exists, nothing the transport returns or raises may reach
  # the caller verbatim -- a misbehaving/custom transport could echo
  # connect_opts (which now contains the real token) in its error reason or
  # exception message. Collapse unconditionally to a stable, content-free
  # atom rather than scanning-and-scrubbing (unreliable if the token is
  # transformed/encoded before being echoed back).
  defp connect_and_wrap(transport_mod, connect_opts, clock_fun, effect_authorizer) do
    case transport_mod.connect(connect_opts) do
      {:ok, tstate} ->
        {:ok,
         %Session{
           transport_mod: transport_mod,
           transport_state: tstate,
           clock_fun: clock_fun,
           effect_authorizer: effect_authorizer
         }}

      {:error, _reason} ->
        {:error, :xai_connect_failed}
    end
  rescue
    _exception -> {:error, :xai_connect_failed}
  catch
    _kind, _reason -> {:error, :xai_connect_failed}
  end

  # ── configure/2 ──

  @impl true
  def configure(%Session{} = session, config) do
    with {:ok, requested} <- PcmFormat.configured_formats(config),
         :ok <- PcmFormat.matches_request(requested, configured_meta()) do
      deadline = send_deadline(session)

      payload =
        %{"turn_detection" => nil}
        |> maybe_put("instructions", Map.get(config, :instructions))
        |> maybe_put("tools", Map.get(config, :tools))
        |> put_media(
          if(Map.get(config, :audio_mode) == :pcm16,
            do: Map.get(config, :audio, %{}),
            else: Map.get(config, :audio)
          )
        )

      session = %{session | input_format: nil, output_format: nil}

      case send_frames(
             session,
             [{:configure, %{"type" => "session.update", "session" => payload}}],
             deadline
           ) do
        {:ok, latest} -> await_configuration(latest, deadline)
        error -> error
      end
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Explicit PCM16/JSON in both modes. Provider defaults are 24kHz in/out;
  # configure/2 only admits our 16kHz/24kHz profile after session.updated.
  defp put_media(payload, audio) do
    voice = if is_map(audio), do: Map.get(audio, :voice, "ara"), else: "ara"

    payload
    |> Map.put("voice", voice)
    |> Map.put("audio", %{
      "input" => %{
        "format" => %{"type" => "audio/pcm", "rate" => 16_000},
        "transport" => "json",
        "transcription" => %{}
      },
      "output" => %{"format" => %{"type" => "audio/pcm", "rate" => 24_000}, "transport" => "json"}
    })
    |> then(fn payload ->
      if is_map(audio), do: payload, else: Map.put(payload, "modalities", ["text"])
    end)
  end

  defp await_configuration(session, deadline) do
    with remaining when is_integer(remaining) <- remaining_budget(deadline, session.clock_fun),
         {:ok, tstate, frame} <-
           session.transport_mod.recv_frame(session.transport_state, remaining) do
      latest = %{session | transport_state: tstate}

      case {send_budget(latest, deadline), frame} do
        {:ok, %{"type" => "session.updated"}} ->
          if confirmed_formats?(frame) do
            {:ok,
             %{
               latest
               | input_format: PcmFormat.mono_s16le(16_000),
                 output_format: PcmFormat.mono_s16le(24_000)
             }}
          else
            configuration_error(latest, :xai_audio_protocol_error)
          end

        {:ok, %{"type" => "session.created", "session" => initial}} when is_map(initial) ->
          # Provider defaults precede our update (currently 24k/24k). They are
          # control data only, never authority to accept or emit PCM.
          await_configuration(latest, deadline)

        {:ok, %{"type" => "conversation.created"}} ->
          await_configuration(latest, deadline)

        {{:error, :timeout}, _} ->
          configuration_error(latest, :timeout)

        _ ->
          configuration_error(latest, :xai_audio_protocol_error)
      end
    else
      :timeout -> configuration_error(session, :timeout)
      {:error, :timeout} -> configuration_error(session, :timeout)
      _ -> configuration_error(session, :xai_transport_failed)
    end
  rescue
    _ -> configuration_error(session, :xai_transport_failed)
  catch
    _, _ -> configuration_error(session, :xai_transport_failed)
  end

  defp configuration_error(session, reason) do
    close(session)
    {:error, reason, session}
  end

  defp confirmed_formats?(
         %{"session" => %{"audio" => %{"input" => input, "output" => output}}} = frame
       )
       when is_map(input) and is_map(output) do
    validate_session_formats(frame) == :ok and
      input["format"] == %{"type" => "audio/pcm", "rate" => 16_000} and
      output["format"] == %{"type" => "audio/pcm", "rate" => 24_000} and
      Map.get(input, "transport", "json") == "json" and
      Map.get(output, "transport", "json") == "json"
  end

  defp confirmed_formats?(_), do: false

  # ── send_text/2, send_audio/2, send_tool_result/3 ──

  @impl true
  def send_text(%Session{} = session, text) do
    frame = %{
      "type" => "conversation.item.create",
      "item" => %{
        "type" => "message",
        "role" => "user",
        "content" => [%{"type" => "input_text", "text" => text}]
      }
    }

    send_frames(session, [
      {:text_item, frame},
      {:text_response, %{"type" => "response.create"}}
    ])
  end

  @impl true
  def send_audio(%Session{} = session, pcm) when is_binary(pcm) do
    # Start the one budget before validation/base64 allocation. Every subsequent
    # frame and physical write uses this same deadline, including worker limits.
    deadline = send_deadline(session)

    with :ok <- PcmFormat.validate_pcm(pcm),
         :ok <- require_audio_configuration(session),
         :ok <- send_budget(session, deadline) do
      send_frames(
        session,
        [
          {:audio_append,
           %{
             "type" => "input_audio_buffer.append",
             "audio" => Base.encode64(pcm)
           }},
          {:audio_commit, %{"type" => "input_audio_buffer.commit"}},
          {:audio_response, %{"type" => "response.create"}}
        ],
        deadline
      )
    end
  end

  def send_audio(%Session{}, _pcm), do: {:error, :invalid_audio}

  defp require_audio_configuration(%Session{input_format: input, output_format: output})
       when is_map(input) and is_map(output), do: :ok

  defp require_audio_configuration(_), do: {:error, :audio_not_configured}

  @impl true
  def send_tool_result(%Session{} = session, call_id, output) do
    frame = %{
      "type" => "conversation.item.create",
      "item" => %{"type" => "function_call_output", "call_id" => call_id, "output" => output}
    }

    send_frames(session, [
      {:tool_result_item, frame},
      {:tool_result_response, %{"type" => "response.create"}}
    ])
  end

  # Once at least one physical frame succeeds, retain the latest opaque
  # backend session in a private third tuple element. ResourceOwner consumes
  # and redacts it, marks the connection poisoned, and closes this latest
  # transport state; public Voice callers still receive only a stable atom.
  defp send_frames(%Session{} = session, frames),
    do: send_frames(session, frames, send_deadline(session))

  defp send_frames(%Session{} = session, frames, deadline) when is_list(frames) do
    Enum.reduce_while(frames, {:ok, session, false}, fn {effect, frame}, {:ok, latest, sent?} ->
      case put_frame(latest, effect, frame, deadline) do
        {:ok, next} ->
          {:cont, {:ok, next, true}}

        {:error, reason} when sent? ->
          {:halt, {:error, reason, latest}}

        {:error, reason} ->
          {:halt, {:error, reason}}

        {:error, reason, latest} ->
          {:halt, {:error, reason, latest}}
      end
    end)
    |> case do
      {:ok, latest, _sent?} -> {:ok, latest}
      error -> error
    end
  end

  defp put_frame(%Session{} = session, effect, frame, deadline) when effect in @effects do
    with :ok <- send_budget(session, deadline),
         :ok <- authorize_effect(session.effect_authorizer, effect),
         :ok <- send_budget(session, deadline) do
      case session.transport_mod.send_frame(session.transport_state, frame, deadline) do
        {:ok, tstate} ->
          latest = %{session | transport_state: tstate}

          case send_budget(latest, deadline) do
            :ok -> {:ok, latest}
            {:error, reason} -> {:error, reason, latest}
          end

        {:error, :session_closed} ->
          {:error, :session_closed}

        {:error, :timeout} ->
          close(session)
          {:error, :timeout}

        {:error, _reason} ->
          {:error, :xai_transport_failed}

        {:error, reason, tstate} ->
          latest = %{session | transport_state: tstate}
          close(latest)
          safe_reason = if reason == :timeout, do: :timeout, else: :xai_transport_failed
          {:error, safe_reason, latest}
      end
    end
  rescue
    _exception -> {:error, :xai_transport_failed}
  catch
    _kind, _reason -> {:error, :xai_transport_failed}
  end

  defp send_deadline(session) do
    local = session.clock_fun.() + @send_timeout_ms

    case BackendWorker.operation_deadline() do
      {:ok, deadline} -> min(local, deadline)
      {:error, :no_operation} -> local
    end
  end

  defp send_budget(session, deadline) do
    if deadline > session.clock_fun.() do
      :ok
    else
      close(session)
      {:error, :timeout}
    end
  end

  defp authorize_effect(authorizer, effect)
       when is_function(authorizer, 2) and effect in @effects do
    case authorizer.(effect, egress_route()) do
      :allow -> :ok
      _denied_or_malformed -> {:error, @authorization_error}
    end
  rescue
    _exception -> {:error, @authorization_error}
  catch
    _kind, _reason -> {:error, @authorization_error}
  end

  defp authorize_effect(_authorizer, effect) when effect in @effects,
    do: {:error, @authorization_error}

  # ── recv/2 ──

  @impl true
  def recv(%Session{} = session, :infinity), do: recv_loop(session, :infinity)

  def recv(%Session{} = session, timeout) when is_integer(timeout) and timeout >= 0 do
    deadline = session.clock_fun.() + timeout
    recv_loop(session, deadline)
  end

  def recv(%Session{}, _timeout), do: {:error, :invalid_timeout}

  # One absolute deadline computed once here; every unknown-event skip
  # recurses through recv_loop/2 against this SAME deadline, passing a
  # shrinking `remaining` into recv_frame/2 -- never a fresh window.
  defp recv_loop(session, deadline) do
    case remaining_budget(deadline, session.clock_fun) do
      :timeout ->
        {:error, :timeout}

      remaining ->
        recv_transport(session, deadline, remaining)
    end
  end

  defp recv_transport(session, deadline, remaining) do
    case session.transport_mod.recv_frame(session.transport_state, remaining) do
      {:ok, tstate, frame} ->
        session = %{session | transport_state: tstate}

        case map_event(session, frame) do
          :skip ->
            recv_loop(session, deadline)

          {:ok, session, event} ->
            {:ok, session, event}

          {:error, reason} ->
            # recv advanced the opaque transport handle. Close that exact handle
            # before returning the bounded error; the owner will also retire it.
            close(session)
            {:error, reason}
        end

      {:error, reason} when reason in [:timeout, :session_closed] ->
        {:error, reason}

      {:error, _reason} ->
        {:error, :xai_transport_failed}
    end
  rescue
    _exception -> {:error, :xai_transport_failed}
  catch
    _kind, _reason -> {:error, :xai_transport_failed}
  end

  defp remaining_budget(:infinity, _clock_fun), do: :infinity

  defp remaining_budget(deadline, clock_fun) do
    remaining = deadline - clock_fun.()
    if remaining <= 0, do: :timeout, else: remaining
  end

  defp map_event(
         session,
         %{"type" => "conversation.item.input_audio_transcription.completed"} = frame
       ) do
    {:ok, session, {:input_transcript, frame["transcript"] || ""}}
  end

  defp map_event(session, %{"type" => "response.output_audio.delta"} = frame) do
    with :ok <- require_audio_configuration(session),
         :ok <- validate_delta_format(frame),
         encoded when is_binary(encoded) <- frame["delta"],
         true <- byte_size(encoded) <= div(@max_output_bytes + 2, 3) * 4,
         {:ok, pcm} <- PcmFormat.decode_base64(encoded),
         true <- byte_size(pcm) <= @max_output_bytes do
      {:ok, session, {:output_audio, pcm}}
    else
      _ -> {:error, :xai_audio_protocol_error}
    end
  end

  defp map_event(_session, %{"type" => type})
       when type in ["session.created", "session.updated"] do
    # Only configure/2 owns acknowledgement. Unsolicited updates cannot silently
    # change the codec or sample rate of an admitted audio session.
    {:error, :xai_audio_protocol_error}
  end

  defp map_event(session, %{"type" => type, "delta" => delta})
       when type in ["response.output_audio_transcript.delta", "response.output_text.delta"] do
    delta = delta || ""
    session = %{session | acc: session.acc <> delta}
    {:ok, session, {:output_text_delta, delta}}
  end

  defp map_event(session, %{"type" => "response.function_call_arguments.done"} = frame) do
    name = frame["name"]
    call_id = frame["call_id"]

    case decode_tool_arguments(frame["arguments"]) do
      {:ok, args} -> {:ok, session, {:tool_call, %{id: call_id, name: name, arguments: args}}}
      :error -> {:ok, session, {:error, {:bad_tool_args, name}}}
    end
  end

  defp map_event(session, %{"type" => "response.done"}) do
    text = String.trim(session.acc)
    {:ok, %{session | acc: ""}, {:turn_done, %{text: text}}}
  end

  defp map_event(session, %{"type" => "error"} = frame) do
    {:ok, session, {:error, frame["error"]}}
  end

  defp map_event(_session, _frame), do: :skip

  defp validate_delta_format(frame) do
    # Alternate, incomplete declarations cannot silently override the source's
    # reviewed PCM contract. Standard delta frames usually omit format entirely.
    if alternate_format?(frame) do
      :error
    else
      validate_optional_wire_format(frame, 24_000)
    end
  end

  defp validate_session_formats(%{"session" => session}) when is_map(session) do
    if alternate_format?(session) or Map.has_key?(session, "format") do
      :error
    else
      case Map.fetch(session, "audio") do
        :error -> :ok
        {:ok, audio} when is_map(audio) -> validate_audio_formats(audio)
        _ -> :error
      end
    end
  end

  defp validate_session_formats(_), do: :error

  defp validate_audio_formats(audio) do
    if alternate_format?(audio) or Map.has_key?(audio, "format"),
      do: :error,
      else: validate_directional_formats(audio)
  end

  defp validate_directional_formats(audio) do
    Enum.reduce_while([{"input", 16_000}, {"output", 24_000}], :ok, fn {key, rate}, :ok ->
      case Map.fetch(audio, key) do
        :error ->
          {:cont, :ok}

        {:ok, value} when is_map(value) ->
          result =
            if alternate_format?(value),
              do: :error,
              else: validate_optional_wire_format(value, rate)

          case result do
            :ok -> {:cont, :ok}
            :error -> {:halt, :error}
          end

        _ ->
          {:halt, :error}
      end
    end)
  end

  defp alternate_format?(container),
    do: Enum.any?(@alternate_format_fields, &Map.has_key?(container, &1))

  defp validate_optional_wire_format(container, rate) do
    case Map.fetch(container, "format") do
      :error -> :ok
      {:ok, %{"type" => "audio/pcm", "rate" => ^rate} = format} when map_size(format) == 2 -> :ok
      _ -> :error
    end
  end

  defp decode_tool_arguments(bin) when is_binary(bin) do
    case Jason.decode(bin) do
      {:ok, %{} = map} -> {:ok, map}
      _other -> :error
    end
  end

  defp decode_tool_arguments(_other), do: :error

  # ── close/1, meta/1 ──

  @impl true
  def close(%Session{} = session) do
    _ = session.transport_mod.close(session.transport_state)
    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  @impl true
  def meta(%Session{} = session),
    do: %{
      backend: :xai_realtime,
      mode: :cloud,
      input_format: session.input_format,
      output_format: session.output_format
    }

  defp configured_meta do
    %{
      backend: :xai_realtime,
      mode: :cloud,
      input_format: PcmFormat.mono_s16le(16_000),
      output_format: PcmFormat.mono_s16le(24_000)
    }
  end
end
