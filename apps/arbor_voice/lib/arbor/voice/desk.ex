defmodule Arbor.Voice.Desk do
  @moduledoc false
  use GenServer, restart: :temporary

  alias Arbor.Voice.{
    Config,
    ConversationAuthority,
    DeskCore,
    DeskWorker,
    Diagnostics,
    Presentation,
    Redacted
  }

  @lease_ms 3_000

  def start(user, agent, %Redacted{value: opts}) do
    with {:ok, recording} <- Config.desk_recording_options(),
         {:ok, options} <- DeskCore.options(user, agent, opts, node(), recording),
         {:ok, timeouts} <- Config.operation_timeouts() do
      options = Map.put(options, :timeout_ms, timeouts.desk_timeout_ms)
      id = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

      case DynamicSupervisor.start_child(
             Arbor.Voice.DeskSupervisor,
             {__MODULE__, Redacted.new({id, options})}
           ) do
        {:ok, _} -> {:ok, id}
        {:error, {:already_registered, _}} -> {:error, :device_busy}
        {:error, :device_busy} -> {:error, :device_busy}
        _ -> {:error, :desk_unavailable}
      end
    end
  rescue
    _ -> {:error, :desk_unavailable}
  catch
    _, _ -> {:error, :desk_unavailable}
  end

  def status(id), do: request(id, :status)
  def cancel(id), do: request(id, :cancel)
  def finish(id), do: request(id, :finish_capture)

  defp request(id, request) do
    if DeskCore.operation_id?(id) do
      case Registry.lookup(Arbor.Voice.Registry, {:desk, id}) do
        [{pid, _}] -> GenServer.call(pid, request, 1_000)
        [] -> {:error, :not_found}
      end
    else
      {:error, :invalid_operation_id}
    end
  catch
    _, _ -> {:error, :cleanup_pending}
  end

  def live?(%{pid: pid, revoked: cell, deadline: deadline}),
    do:
      Process.alive?(pid) and :atomics.get(cell, 1) == 0 and
        System.monotonic_time(:millisecond) < deadline

  def live?(_), do: false

  def start_link(%Redacted{value: {id, _}} = bootstrap),
    do:
      GenServer.start_link(__MODULE__, bootstrap,
        name: {:via, Registry, {Arbor.Voice.Registry, {:desk, id}}}
      )

  @impl true
  def init(%Redacted{value: {id, options}}) do
    Process.flag(:sensitive, true)
    Process.flag(:trap_exit, true)

    case Registry.register(Arbor.Voice.Registry, :desk_active, nil) do
      {:ok, _} ->
        now = now()
        permit = %{pid: self(), revoked: :atomics.new(1, []), deadline: now + options.timeout_ms}

        if options.origin_node && options.origin_node != node(),
          do: Node.monitor(options.origin_node, true)

        send(self(), :begin)
        Process.send_after(self(), :tick, 100)

        {:ok,
         %{
           id: id,
           options: Redacted.new(options),
           permit: permit,
           lease_until: now + @lease_ms,
           started_at: now,
           phase: :admitting,
           work: nil,
           cleanup_work: nil,
           binding: nil,
           proof: nil,
           captured: nil,
           capture_tag: nil,
           capture_control: nil,
           capture_started: false,
           finish_requested: false,
           session: nil,
           session_closed: false,
           startup_closed: nil,
           presentation_used: false,
           presentation_closed: :atomics.new(1, []),
           device_used: false,
           device_closed: true,
           cancellation: nil,
           result: nil,
           error: nil,
           terminal: false,
           cue: nil,
           multimedia: Config.desk_multimedia_module(),
           voice: Config.desk_voice_module(),
           session_opts: Config.desk_session_options()
         }}

      _ ->
        {:stop, :device_busy}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    state =
      if not state.terminal and now() < state.lease_until,
        do: %{state | lease_until: min(now() + @lease_ms, state.permit.deadline)},
        else: state

    state = enforce_deadline(state)
    {:reply, {:ok, public(state)}, state}
  end

  def handle_call(:finish_capture, _from, state) do
    state = enforce_deadline(state)

    cond do
      not finishable?(state) and
          not (state.finish_requested and state.phase == :capture and is_nil(state.cancellation)) ->
        {:reply, {:error, :finish_unavailable}, state}

      state.finish_requested ->
        {:reply, :ok, state}

      ConversationAuthority.recheck(state.binding) != :ok ->
        {:reply, {:error, :conversation_unauthorized},
         cancel_state(state, :conversation_unauthorized)}

      not live?(state.permit) or now() >= state.lease_until ->
        {:reply, {:error, :finish_unavailable}, enforce_deadline(state)}

      true ->
        case state.multimedia.finish_capture(Redacted.value(state.capture_control)) do
          :ok -> {:reply, :ok, %{state | finish_requested: true}}
          _ -> {:reply, {:error, :finish_unavailable}, cancel_state(state, :finish_unavailable)}
        end
    end
  end

  def handle_call(:cancel, _from, state) do
    state = if state.terminal, do: state, else: cancel_state(state, :cancelled)
    {:reply, if(state.terminal, do: :ok, else: {:error, :cleanup_pending}), state}
  end

  @impl true
  def handle_info(:begin, state) do
    opts = Redacted.value(state.options)
    config = state.session_opts

    fun = fn ->
      with true <- live?(state.permit),
           {:ok, security} <- Config.security_module(),
           {:ok, token} <- resolve_proof(security, opts),
           {:ok, binding} <-
             ConversationAuthority.admit(%{
               user_id: opts.user,
               agent_id: opts.agent,
               session_token: Redacted.new(token),
               security_module: security,
               comms: Keyword.get(config, :comms, Config.desk_comms_module()),
               engagement_store: Keyword.get(config, :engagement_store)
             }),
           true <-
             is_nil(opts.expected_engagement_id) or
               Redacted.value(binding).engagement_id == opts.expected_engagement_id do
        {:ok, Redacted.new(token), binding}
      else
        _ -> {:error, :conversation_unauthorized}
      end
    end

    {:noreply, launch(state, :admitting, fun)}
  end

  def handle_info(
        {:multimedia_capture_control, tag, control},
        %{capture_tag: tag, capture_control: nil, phase: :capture, cancellation: nil} = state
      )
      when is_reference(tag) and is_binary(control) and byte_size(control) == 32,
      do: {:noreply, %{state | capture_control: Redacted.new(control)}}

  def handle_info(
        {:multimedia_capture_started, tag, control},
        %{
          capture_tag: tag,
          capture_control: %Redacted{value: control},
          capture_started: false,
          phase: :capture,
          cancellation: nil
        } = state
      )
      when is_reference(tag) and is_binary(control) and byte_size(control) == 32 do
    state = enforce_deadline(state)

    if is_nil(state.cancellation) and live?(state.permit),
      do: {:noreply, %{state | capture_started: true}},
      else: {:noreply, state}
  end

  def handle_info({:desk_work, token, %Redacted{value: result}}, %{work: %{token: token}} = state) do
    Process.demonitor(state.work.ref, [:flush])
    phase = state.phase
    state = %{state | work: nil}
    {:noreply, completed(state, phase, result)}
  end

  def handle_info(
        {:desk_work, token, %Redacted{value: result}},
        %{cleanup_work: %{token: token}} = state
      ) do
    Process.demonitor(state.cleanup_work.ref, [:flush])
    state = %{state | cleanup_work: nil, session_closed: result == :ok or state.session_closed}
    {:noreply, settle_cancel(state)}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{work: %{ref: ref}} = state) do
    {:noreply, state |> Map.put(:work, nil) |> cancel_state(:operation_failed)}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{cleanup_work: %{ref: ref}} = state) do
    {:noreply, %{state | cleanup_work: nil, phase: :cleanup_pending}}
  end

  def handle_info({:nodedown, origin}, state) do
    if Redacted.value(state.options).origin_node == origin,
      do: {:noreply, cancel_state(state, :caller_down)},
      else: {:noreply, state}
  end

  def handle_info({:desk_cue, token}, %{permit: %{revoked: token}} = state),
    do: {:noreply, if(live?(state.permit), do: %{state | cue: "Working on it."}, else: state)}

  def handle_info(:tick, state) do
    state = enforce_deadline(state)

    state =
      if state.cancellation, do: state |> request_session_close() |> settle_cancel(), else: state

    if not state.terminal, do: Process.send_after(self(), :tick, 100)
    {:noreply, state}
  end

  def handle_info(:retire, state), do: {:stop, :normal, state}
  def handle_info(_, state), do: {:noreply, state}

  defp completed(%{cancellation: reason} = state, phase, result) when not is_nil(reason) do
    state =
      case {phase, result} do
        {:starting, {:ok, session}} ->
          %{state | session: Redacted.new(session), session_closed: false}

        {:turn, {:ok, _}} ->
          %{state | session_closed: true, session: nil}

        {phase, {:error, _, :closed}} when phase in [:starting, :turn] ->
          %{state | session_closed: true, session: nil}

        {:capture, {:ok, _}} ->
          %{state | device_closed: true}

        {:presenting, {:ok, _}} ->
          %{state | device_closed: true}

        _ ->
          state
      end

    state |> request_session_close() |> settle_cancel()
  end

  defp completed(state, :admitting, {:ok, proof, binding}) do
    opts = Redacted.value(state.options)
    tag = make_ref()
    controller = self()
    manual = manual_finish_supported?(state.multimedia)

    state = %{
      state
      | proof: proof,
        binding: binding,
        device_used: true,
        device_closed: false,
        capture_tag: if(manual, do: tag),
        capture_control: nil,
        capture_started: false,
        finish_requested: false
    }

    effect = fn ->
      capture_opts = [
        duration_ms: opts.duration_ms,
        sample_rate: 16_000,
        device_id: opts.input_device
      ]

      if manual do
        state.multimedia.capture_pcm(capture_opts,
          controller: {controller, tag},
          minimum_duration_ms: opts.minimum_duration_ms
        )
      else
        state.multimedia.capture_pcm(capture_opts)
      end
    end

    launch(state, :capture, guarded(state, effect))
  end

  defp completed(state, :capture, {:ok, %{audio: audio, utterance_ended_at: ended} = captured}) do
    opts = Redacted.value(state.options)

    with true <-
           audio.sample_rate == 16_000 and audio.channels == 1 and audio.sample_format == :s16le,
         true <- captured_size?(audio.pcm, opts, state.finish_requested),
         %DateTime{} <- ended do
      state = %{
        state
        | captured: Redacted.new(captured),
          device_closed: true,
          capture_control: nil,
          capture_tag: nil
      }

      if opts.mode == :loopback do
        p = %{
          verdict: {:speak, "Microphone recording"},
          spoken_text: "Microphone recording",
          audio: audio.pcm,
          format: %{encoding: :pcm, sample_rate: 16_000, channels: 1, sample_format: :s16le}
        }

        state = %{
          state
          | result: %{
              capture_frames: div(byte_size(audio.pcm), 2),
              capture_duration_ms: div(byte_size(audio.pcm), 32)
            }
        }

        present(state, p)
      else
        permit = state.permit
        desk = self()
        closed = :atomics.new(1, [])
        :atomics.put(closed, 1, 1)
        state = Map.put(state, :startup_closed, closed)

        voice_opts =
          state.session_opts
          |> Keyword.put(:session_token, Redacted.value(state.proof))
          |> Keyword.put(:audio_mode, :pcm16)
          |> Keyword.put(:speech_output, fn _ ->
            send(desk, {:desk_cue, permit.revoked})
            :ok
          end)

        launch(
          state,
          :starting,
          fn ->
            with true <- live?(permit),
                 :ok <- ConversationAuthority.recheck(state.binding),
                 true <- live?(permit) do
              state.voice.start_owned_desk_session(
                opts.user,
                opts.agent,
                voice_opts,
                permit |> Map.put(:binding, state.binding) |> Map.put(:closed, closed)
              )
            else
              _ -> {:error, :conversation_unauthorized, :closed}
            end
          end
        )
      end
    else
      _ -> cancel_state(state, :invalid_media)
    end
  end

  defp completed(state, :starting, {:ok, session}) do
    captured = Redacted.value(state.captured)
    state = %{state | session: Redacted.new(session), session_closed: false}

    launch(
      state,
      :turn,
      guarded(state, fn ->
        state.voice.owned_desk_audio_turn(session, captured.audio,
          operation_id: state.id,
          utterance_ended_at: captured.utterance_ended_at
        )
      end)
    )
  end

  defp completed(state, :turn, {:ok, result}) do
    state = %{state | session_closed: true, session: nil, captured: nil}

    case DeskCore.result(result, state.id) do
      {:ok, public} -> present(%{state | result: public}, result.presentation)
      {:error, reason} -> cancel_state(state, reason)
    end
  end

  defp completed(state, :presenting, {:ok, disposition}) do
    if live?(state.permit) and ConversationAuthority.recheck(state.binding) == :ok do
      terminal(
        %{state | device_closed: true, result: Map.put(state.result, :disposition, disposition)},
        :complete
      )
    else
      cancel_state(%{state | device_closed: true}, :conversation_unauthorized)
    end
  end

  defp completed(state, phase, {:error, reason, :closed}) when phase in [:starting, :turn],
    do: cancel_state(%{state | session_closed: true, session: nil}, DeskCore.error(reason))

  defp completed(state, phase, {:error, reason, :cleanup_pending})
       when phase in [:starting, :turn],
       do: cancel_state(state, DeskCore.error(reason))

  defp completed(state, _phase, {:error, reason}), do: cancel_state(state, DeskCore.error(reason))
  defp completed(state, _phase, _), do: cancel_state(state, :operation_failed)

  defp present(state, p) do
    opts = Redacted.value(state.options)

    ctx = %{
      id: state.id,
      permit: state.permit,
      binding: state.binding,
      multimedia: state.multimedia,
      output_device: opts.output_device,
      closed: state.presentation_closed
    }

    state = %{state | device_used: true, device_closed: false, presentation_used: true}
    launch(state, :presenting, fn -> Presentation.present(ctx, p) end)
  end

  defp guarded(state, fun),
    do: fn ->
      with true <- live?(state.permit),
           :ok <- ConversationAuthority.recheck(state.binding),
           true <- live?(state.permit),
           do: fun.(),
           else: (_ -> {:error, :conversation_unauthorized})
    end

  defp launch(state, phase, fun) do
    token = make_ref()

    case DeskWorker.start(self(), token, fun) do
      {:ok, pid} ->
        %{state | phase: phase, work: %{pid: pid, token: token, ref: Process.monitor(pid)}}

      _ ->
        cancel_state(state, :operation_failed)
    end
  end

  defp enforce_deadline(%{terminal: true} = state), do: state

  defp enforce_deadline(state) do
    cond do
      now() >= state.permit.deadline -> cancel_state(state, :timeout)
      now() >= state.lease_until -> cancel_state(state, :lease_expired)
      true -> state
    end
  end

  defp cancel_state(%{terminal: true} = state, _), do: state

  defp cancel_state(state, reason) do
    if is_nil(state.cancellation), do: Diagnostics.failure(state.phase, reason)
    :atomics.put(state.permit.revoked, 1, 1)

    state = %{
      state
      | cancellation: state.cancellation || DeskCore.error(reason),
        captured: nil,
        capture_control: nil,
        capture_tag: nil,
        result: nil
    }

    state =
      if state.work && state.phase in [:capture, :presenting] do
        Process.exit(state.work.pid, :kill)
        state
      else
        state
      end

    state |> request_session_close() |> settle_cancel()
  end

  defp request_session_close(
         %{session: %Redacted{value: session}, session_closed: false, cleanup_work: nil} = state
       ) do
    token = make_ref()
    voice = state.voice

    case DeskWorker.start(self(), token, fn -> voice.stop_owned_desk_session(session) end) do
      {:ok, pid} -> %{state | cleanup_work: %{pid: pid, token: token, ref: Process.monitor(pid)}}
      _ -> state
    end
  end

  defp request_session_close(state), do: state
  defp settle_cancel(%{cancellation: nil} = state), do: state

  defp settle_cancel(state) do
    idle =
      state.device_closed or (state.work == nil and state.multimedia.device_status() == :idle)

    # A failed startup can outlive its worker without ever producing a Session
    # handle. Join the retained receipt, never infer closure from its absence.
    voice_closed = state.session_closed or startup_closed?(state)

    presentation_closed =
      not state.presentation_used or :atomics.get(state.presentation_closed, 1) == 1

    if state.work == nil and state.cleanup_work == nil and idle and voice_closed and
         presentation_closed do
      terminal(%{state | error: state.cancellation, device_closed: true}, :cancelled)
    else
      %{state | error: state.cancellation}
    end
  rescue
    _ -> %{state | error: :cleanup_pending}
  end

  defp startup_closed?(state) do
    case Map.get(state, :startup_closed) do
      nil -> state.session == nil and state.phase != :starting
      closed -> :atomics.get(closed, 1) == 1
    end
  end

  defp terminal(state, phase) do
    :atomics.put(state.permit.revoked, 1, 1)
    Registry.unregister(Arbor.Voice.Registry, :desk_active)
    Process.send_after(self(), :retire, 60_000)

    %{
      state
      | terminal: true,
        phase: phase,
        captured: nil,
        capture_control: nil,
        capture_tag: nil,
        proof: nil,
        session: nil
    }
  end

  defp public(state) do
    authorized = is_nil(state.result) or ConversationAuthority.recheck(state.binding) == :ok

    %{
      operation_id: state.id,
      mode: Redacted.value(state.options).mode,
      state: public_phase(state),
      can_finish: finishable?(state),
      terminal: state.terminal,
      elapsed_ms: max(0, now() - state.started_at),
      cue: state.cue,
      result: if(authorized, do: state.result, else: nil),
      error: if(authorized, do: state.error, else: :conversation_unauthorized)
    }
  end

  defp public_phase(%{cancellation: reason, terminal: false}) when not is_nil(reason),
    do: :cleanup_pending

  defp public_phase(%{phase: :capture, finish_requested: true}), do: :finishing
  defp public_phase(%{phase: :capture, capture_started: false}), do: :preparing_capture
  defp public_phase(state), do: state.phase

  defp finishable?(state),
    do:
      state.phase == :capture and is_nil(state.cancellation) and
        not state.terminal and not state.finish_requested and
        match?(%Redacted{}, state.capture_control)

  defp captured_size?(pcm, opts, manual) when is_binary(pcm) do
    bytes = byte_size(pcm)

    if manual,
      do:
        rem(bytes, 2) == 0 and bytes >= opts.minimum_duration_ms * 32 and
          bytes <= opts.duration_ms * 32,
      else: bytes == opts.duration_ms * 32
  end

  defp captured_size?(_, _, _), do: false

  defp manual_finish_supported?(multimedia) do
    Code.ensure_loaded?(multimedia) and
      function_exported?(multimedia, :manual_capture_finish_supported?, 0) and
      function_exported?(multimedia, :capture_pcm, 2) and
      function_exported?(multimedia, :finish_capture, 1) and
      multimedia.manual_capture_finish_supported?() == true
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp resolve_proof(security, opts) do
    case Keyword.fetch(opts.proof, :session_token) do
      {:ok, token} ->
        {:ok, token}

      :error ->
        apply(security, :issue_signed_conversation_session, [
          opts.user,
          opts.agent,
          opts.proof[:signed_request]
        ])
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
  @impl true
  def format_status(status),
    do: Map.merge(status, %{state: :redacted, message: :redacted, reason: :redacted, log: []})
end
