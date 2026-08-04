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

  @default_host "api.x.ai"
  @default_port 443
  @default_path "/v1/realtime?model=grok-voice-latest"
  @authorization_error :xai_effect_not_authorized
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
    defstruct [:transport_mod, :transport_state, :clock_fun, :effect_authorizer, acc: ""]
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
    payload =
      %{"turn_detection" => nil}
      |> maybe_put("instructions", Map.get(config, :instructions))
      |> maybe_put("tools", Map.get(config, :tools))
      |> put_media(Map.get(config, :audio))

    put_frame(session, :configure, %{"type" => "session.update", "session" => payload})
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Proven nested shape from the prototype's audio_session_update/0: PCM16
  # 16kHz in / 24kHz out, with an optional :voice override. Does not assume
  # the provider honors a text-only request -- the 2026-08-02 live run
  # returned audio plus transcript events for a text-mode session.
  defp put_media(payload, audio) when is_map(audio) do
    voice = Map.get(audio, :voice) || Map.get(audio, "voice") || "ara"

    Map.put(payload, "audio", %{
      "input" => %{"format" => %{"type" => "audio/pcm", "rate" => 16_000}, "transcription" => %{}},
      "output" => %{"format" => %{"type" => "audio/pcm", "rate" => 24_000}, "voice" => voice}
    })
  end

  defp put_media(payload, _audio), do: Map.put(payload, "modalities", ["text"])

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
    send_frames(session, [
      {:audio_append,
       %{
         "type" => "input_audio_buffer.append",
         "audio" => Base.encode64(pcm)
       }},
      {:audio_commit, %{"type" => "input_audio_buffer.commit"}},
      {:audio_response, %{"type" => "response.create"}}
    ])
  end

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
  defp send_frames(%Session{} = session, frames) when is_list(frames) do
    Enum.reduce_while(frames, {:ok, session, false}, fn {effect, frame}, {:ok, latest, sent?} ->
      case put_frame(latest, effect, frame) do
        {:ok, next} ->
          {:cont, {:ok, next, true}}

        {:error, reason} when sent? ->
          {:halt, {:error, reason, latest}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, latest, _sent?} -> {:ok, latest}
      error -> error
    end
  end

  defp put_frame(%Session{} = session, effect, frame) when effect in @effects do
    with :ok <- authorize_effect(session.effect_authorizer, effect) do
      case session.transport_mod.send_frame(session.transport_state, frame) do
        {:ok, tstate} -> {:ok, %{session | transport_state: tstate}}
        {:error, :session_closed} -> {:error, :session_closed}
        {:error, _reason} -> {:error, :xai_transport_failed}
      end
    end
  rescue
    _exception -> {:error, :xai_transport_failed}
  catch
    _kind, _reason -> {:error, :xai_transport_failed}
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
          :skip -> recv_loop(session, deadline)
          {:ok, session, event} -> {:ok, session, event}
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
    pcm =
      case Base.decode64(frame["delta"] || "") do
        {:ok, bin} -> bin
        :error -> <<>>
      end

    {:ok, session, {:output_audio, pcm}}
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
  def meta(%Session{}) do
    %{backend: :xai_realtime, mode: :cloud, input_rate: 16_000, output_rate: 24_000}
  end
end
