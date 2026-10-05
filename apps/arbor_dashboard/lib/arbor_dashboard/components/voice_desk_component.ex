defmodule Arbor.Dashboard.Components.VoiceDeskComponent do
  @moduledoc false
  use Phoenix.Component
  alias Arbor.Dashboard.Config
  alias Arbor.Dashboard.Live.ChatLive.Conversation

  def mount(socket, peer, uri, headers) do
    recording = recording_options()

    socket =
      assign(socket,
        voice_local:
          Config.local_voice_controls?() and loopback?(peer) and local_uri?(uri) and
            direct?(headers),
        voice_operation: nil,
        voice_message: "Choose a recording length, then test the microphone and speaker.",
        voice_error: false,
        voice_recording: recording,
        voice_duration_text: if(recording, do: seconds(recording.default_ms), else: ""),
        voice_duration_ms: nil,
        voice_duration_error: nil
      )

    validate_duration(socket, recording, socket.assigns.voice_duration_text)
  end

  def event(socket, "duration", %{"seconds" => value}) do
    if is_nil(socket.assigns.voice_operation) do
      validate_duration(socket, recording_options(), value)
    else
      socket
    end
  end

  def event(socket, action, _params) when action in ["loopback", "talk"] do
    socket = Conversation.refresh(socket)

    if allowed?(socket) and is_nil(socket.assigns.voice_operation) do
      socket = validate_duration(socket, recording_options(), socket.assigns.voice_duration_text)

      if is_integer(socket.assigns.voice_duration_ms) do
        start_recording(socket, action)
      else
        socket
      end
    else
      message(socket, :unavailable)
    end
  end

  def event(socket, "finish", _params) do
    socket = Conversation.refresh(socket)

    case socket.assigns.voice_operation do
      %{id: id, can_finish: true} = op ->
        if allowed?(socket) and current_scope?(socket, op) do
          case safe_call(Config.voice_api(), :finish_desk_turn, [id]) do
            :ok ->
              assign(socket,
                voice_operation: Map.put(op, :can_finish, false),
                voice_message: "Finishing recording and closing the microphone…",
                voice_error: false
              )

            {:error, reason} ->
              message(socket, reason)

            _ ->
              message(socket, :finish_unavailable)
          end
        else
          retire(socket, id)
        end

      _ ->
        socket
    end
  end

  def event(socket, "cancel", _params) do
    case socket.assigns.voice_operation do
      %{id: id} ->
        safe_call(Config.voice_api(), :cancel_desk_turn, [id])
        assign(socket, voice_message: "Stopping and closing audio…", voice_error: false)

      nil ->
        socket
    end
  end

  def event(socket, action, _params) when action in ["permission", "request-permission"] do
    socket = Conversation.refresh(socket)

    if allowed?(socket) and is_nil(socket.assigns.voice_operation) do
      function =
        if action == "permission",
          do: :microphone_permission,
          else: :request_microphone_permission

      case safe_call(Config.multimedia_api(), function, []) do
        :authorized ->
          assign(socket,
            voice_message: "Microphone access is allowed. Ready for a loopback check.",
            voice_error: false
          )

        :not_determined ->
          assign(socket,
            voice_message:
              "Microphone access is pending. Respond to the macOS prompt, then check access again.",
            voice_error: false
          )

        :denied ->
          message(socket, :permission_denied)

        :restricted ->
          message(socket, :permission_denied)

        _ ->
          message(socket, :device_unavailable)
      end
    else
      message(socket, :unavailable)
    end
  end

  def event(socket, _, _), do: socket

  defp start_recording(socket, action) do
    mode = if action == "loopback", do: :loopback, else: :conversation
    user = socket.assigns.current_agent_id
    agent = socket.assigns.agent_id
    token = socket.assigns.session_token

    opts = [
      session_token: token,
      duration_ms: socket.assigns.voice_duration_ms,
      mode: mode,
      origin_node: node(),
      expected_engagement_id: socket.assigns.conversation_engagement_id
    ]

    case safe_call(Config.voice_api(), :start_desk_turn, [user, agent, opts]) do
      {:ok, id} when is_binary(id) and byte_size(id) == 43 ->
        Process.send_after(self(), {:voice_desk_poll, id}, 100)

        assign(socket,
          voice_operation: %{
            id: id,
            user: user,
            agent: agent,
            duration_ms: socket.assigns.voice_duration_ms,
            can_finish: false,
            mode: mode,
            engagement: socket.assigns.conversation_engagement_id
          },
          voice_message: "Checking conversation access…",
          voice_error: false
        )

      {:error, reason} ->
        message(socket, reason)

      _ ->
        message(socket, :unavailable)
    end
  end

  def poll(socket, id) do
    case socket.assigns[:voice_operation] do
      %{id: ^id} = operation ->
        cond do
          operation[:retiring] ->
            poll_retiring(socket, id)

          allowed?(socket) and current_scope?(socket, operation) ->
            poll_current(socket, id)

          true ->
            retire(socket, id)
        end

      _ ->
        socket
    end
  end

  defp poll_current(socket, id) do
    case safe_call(Config.voice_api(), :desk_turn_status, [id]) do
      {:ok, %{terminal: true, state: :complete, mode: mode, error: nil, result: result}}
      when is_map(result) ->
        text = completion_message(mode, result[:disposition])

        send(self(), :refresh_conversation)
        assign(socket, voice_operation: nil, voice_message: text, voice_error: false)

      {:ok, %{terminal: true, error: reason}} ->
        socket |> assign(voice_operation: nil) |> message(reason)

      {:ok, %{terminal: false, state: state} = status} ->
        Process.send_after(self(), {:voice_desk_poll, id}, 250)

        assign(socket,
          voice_operation:
            Map.put(socket.assigns.voice_operation, :can_finish, status[:can_finish] == true),
          voice_message: phase(state, socket.assigns.voice_operation[:duration_ms]),
          voice_error: false
        )

      _ ->
        retire(socket, id)
    end
  end

  defp completion_message(:loopback, :played),
    do: "Loopback complete. Your recording has finished playing."

  defp completion_message(_mode, :played),
    do: "Voice turn complete. The response finished playing through the host speaker."

  defp completion_message(_mode, :screen_only),
    do: "Voice turn complete. The response is on screen; no audio was played."

  defp completion_message(_mode, _disposition),
    do: "Voice turn complete. The transcript is in this conversation."

  defp retire(socket, id) do
    safe_call(Config.voice_api(), :cancel_desk_turn, [id])
    Process.send_after(self(), {:voice_desk_poll, id}, 250)

    socket
    |> assign(voice_operation: Map.put(socket.assigns.voice_operation, :retiring, true))
    |> message(:cleanup_pending)
  end

  defp poll_retiring(socket, id) do
    case safe_call(Config.voice_api(), :desk_turn_status, [id]) do
      {:ok, %{terminal: true}} ->
        socket |> assign(voice_operation: nil) |> message(:cancelled)

      _ ->
        Process.send_after(self(), {:voice_desk_poll, id}, 500)
        message(socket, :cleanup_pending)
    end
  end

  defp allowed?(socket) do
    Config.local_voice_controls?() and socket.assigns[:voice_local] == true and
      socket.assigns[:conversation_authorized] == true and
      socket.assigns[:conversation_rebind_required] != true and
      socket.assigns[:group_mode] != true and
      is_binary(socket.assigns[:session_token]) and socket.assigns.session_token != "" and
      is_binary(socket.assigns[:current_agent_id]) and is_binary(socket.assigns[:agent_id])
  end

  defp current_scope?(socket, op),
    do:
      socket.assigns.current_agent_id == op.user and socket.assigns.agent_id == op.agent and
        socket.assigns.conversation_engagement_id == op.engagement

  defp loopback?(%{address: {127, _, _, _}}), do: true
  defp loopback?(%{address: {0, 0, 0, 0, 0, 0, 0, 1}}), do: true
  defp loopback?(_), do: false
  defp local_uri?(%URI{host: host}), do: host in ["localhost", "127.0.0.1", "::1"]
  defp local_uri?(_), do: false

  defp direct?(headers) when is_list(headers) do
    markers = for {"x-arbor-voice-direct", value} <- headers, do: value

    markers == ["true"] and
      not Enum.any?(headers, fn
        {name, _} when is_binary(name) ->
          name = String.downcase(name)
          String.starts_with?(name, "x-forwarded") or name in ["forwarded", "via", "x-real-ip"]

        _ ->
          true
      end)
  end

  defp direct?(_), do: false

  defp safe_call(module, function, args) do
    apply(module, function, args)
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp recording_options do
    case safe_call(Config.voice_api(), :desk_recording_options, []) do
      {:ok, %{default_ms: default, min_ms: min, max_ms: max} = options}
      when map_size(options) == 3 and is_integer(min) and is_integer(max) and
             is_integer(default) and min > 0 and min <= default and default <= max ->
        options

      _ ->
        nil
    end
  end

  defp validate_duration(socket, nil, _value) do
    assign(socket,
      voice_recording: nil,
      voice_duration_text: "",
      voice_duration_ms: nil,
      voice_duration_error: "Recording settings are unavailable. Check the host configuration."
    )
  end

  defp validate_duration(socket, recording, value) do
    # Keep decimal seconds exact: never round a floating-point input into a
    # different duration. Browser fields are untrusted just like click payloads.
    value = if is_binary(value) and byte_size(value) <= 16, do: value, else: ""

    duration =
      if Regex.match?(~r/\A(?:0|[1-9][0-9]{0,2})(?:\.[0-9]{1,3})?\z/, value) do
        case String.split(value, ".") do
          [whole] ->
            String.to_integer(whole) * 1_000

          [whole, fraction] ->
            String.to_integer(whole) * 1_000 +
              String.to_integer(String.pad_trailing(fraction, 3, "0"))
        end
      end

    valid = is_integer(duration) and duration >= recording.min_ms and duration <= recording.max_ms

    assign(socket,
      voice_recording: recording,
      voice_duration_text: value,
      voice_duration_ms: if(valid, do: duration),
      voice_duration_error:
        if(!valid,
          do:
            "Choose a recording length from #{seconds(recording.min_ms)} to #{seconds(recording.max_ms)} seconds."
        )
    )
  end

  defp seconds(ms) do
    whole = Integer.to_string(div(ms, 1_000))
    fraction = ms |> rem(1_000) |> Integer.to_string() |> String.pad_leading(3, "0")
    if fraction == "000", do: whole, else: whole <> "." <> String.trim_trailing(fraction, "0")
  end

  defp phase(:preparing_capture, _), do: "Starting microphone—wait to speak."

  defp phase(:capture, duration) when is_integer(duration),
    do: "Recording for #{seconds(duration)} seconds — speak now."

  defp phase(:capture, _), do: "Recording — speak now."
  defp phase(:finishing, _), do: "Finishing recording and closing the microphone…"
  defp phase(:starting, _), do: "Connecting voice…"
  defp phase(:turn, _), do: "Working on your voice turn…"
  defp phase(:presenting, _), do: "Playing through the host speaker…"

  defp phase(:cleanup_pending, _),
    do: "Waiting for audio to close. A new recording is blocked until cleanup finishes."

  defp phase(_, _), do: "Checking conversation access…"

  defp message(socket, reason),
    do: assign(socket, voice_message: error(reason), voice_error: true)

  defp error(:permission_denied),
    do: "Microphone access is denied. Allow access in macOS Privacy & Security, then check again."

  defp error(:device_unavailable),
    do: "The local audio driver is unavailable. Enable the native audio driver on the Arbor host."

  defp error(:device_busy), do: "Another audio operation is still using the device."

  defp error(:cleanup_pending),
    do: "Audio cleanup is still pending. The device remains reserved until closure is confirmed."

  defp error(:conversation_unauthorized),
    do: "Conversation access changed. Reconnect before recording again."

  defp error(:capture_failed),
    do: "The microphone recording could not be completed. Try the mic and speaker check."

  defp error(:recording_too_short),
    do: "The recording was too short. Record at least the configured minimum before finishing."

  defp error(:finish_unavailable),
    do: "The recording could not finish early. Wait for its current status before starting again."

  defp error(:start_failed),
    do: "Recording finished, but the voice session could not start."

  defp error(:turn_failed),
    do: "The recording was captured, but the voice response could not be completed."

  defp error(:budget_exhausted), do: "The voice budget is exhausted."

  defp error(:invalid_config),
    do: "Recording settings are unavailable. Check the host configuration."

  defp error(:invalid_desk_options),
    do: "Recording settings changed. Choose a supported recording length."

  defp error(:cancelled), do: "Voice operation cancelled. Audio is closed."
  defp error(:timeout), do: "The voice turn timed out and audio is closed."

  defp error(_),
    do: "The voice check could not complete. Check conversation access and audio setup."

  def controls(assigns) do
    assigns =
      assigns
      |> assign_new(:voice_local, fn -> false end)
      |> assign_new(:voice_operation, fn -> nil end)
      |> assign_new(:voice_error, fn -> false end)
      |> assign_new(:voice_message, fn -> "" end)
      |> assign_new(:voice_recording, fn -> nil end)
      |> assign_new(:voice_duration_text, fn -> "" end)
      |> assign_new(:voice_duration_ms, fn -> nil end)
      |> assign_new(:voice_duration_error, fn -> nil end)

    assigns =
      assign(
        assigns,
        :voice_allowed,
        assigns[:voice_local] == true and assigns[:conversation_authorized] == true and
          assigns[:group_mode] != true
      )

    ~H"""
    <section
      :if={@voice_local}
      id="voice-desk"
      aria-label="Local voice check"
      style="padding: 0.75rem; border-top: 1px solid var(--aw-border, #333); background: var(--aw-bg-card, #161b22); flex-shrink: 0;"
    >
      <div style="display: flex; justify-content: space-between; gap: 1rem; align-items: baseline;">
        <strong style="font-size: 0.8rem; letter-spacing: 0.05em; text-transform: uppercase;">
          Local voice check
        </strong>
        <span style="font-size: 0.75rem; color: var(--aw-text-muted, #aaa);">
          Timed recording · one turn
        </span>
      </div>
      <p style="font-size: 0.8rem; margin: 0.4rem 0 0.65rem; color: var(--aw-text-muted, #aaa);">
        Uses the microphone and speaker on this Arbor host. Loopback stays on this machine.
        A voice turn sends your recording to the configured speech provider.
      </p>
      <form id="voice-duration-form" phx-change="voice:duration" phx-submit="voice:duration">
        <label for="voice-duration" style="font-size: 0.8rem;">
          Recording length (seconds)
        </label>
        <input
          id="voice-duration"
          name="seconds"
          type="number"
          min={@voice_recording && seconds(@voice_recording.min_ms)}
          max={@voice_recording && seconds(@voice_recording.max_ms)}
          step="0.001"
          value={@voice_duration_text}
          disabled={!@voice_allowed || @voice_operation != nil || @voice_recording == nil}
          aria-describedby="voice-duration-help"
          aria-invalid={to_string(@voice_duration_error != nil)}
          style="width: 5rem; margin: 0 0.4rem 0.5rem;"
        />
        <p id="voice-duration-help" style="font-size: 0.75rem; margin: 0 0 0.65rem;">
          <%= if @voice_duration_error do %>
            {@voice_duration_error}
          <% else %>
            <span :if={@voice_recording}>
              {seconds(@voice_recording.min_ms)}–{seconds(@voice_recording.max_ms)} seconds.
            </span>
            Your choice stays for subsequent turns while this page is open.
            Cancel stops the current audio operation. Any conversation text already saved is kept.
          <% end %>
        </p>
      </form>
      <div style="display: flex; gap: 0.4rem; flex-wrap: wrap;">
        <button
          type="button"
          phx-click="voice:permission"
          class="aw-btn aw-btn-sm"
          style={disabled_style(!@voice_allowed || @voice_operation != nil)}
          disabled={!@voice_allowed || @voice_operation != nil}
        >
          Check mic access
        </button>
        <button
          type="button"
          phx-click="voice:request-permission"
          class="aw-btn aw-btn-sm"
          style={disabled_style(!@voice_allowed || @voice_operation != nil)}
          disabled={!@voice_allowed || @voice_operation != nil}
        >
          Allow microphone
        </button>
        <button
          type="button"
          phx-click="voice:loopback"
          class="aw-btn aw-btn-sm aw-btn-primary"
          style={
            disabled_style(!@voice_allowed || @voice_operation != nil || @voice_duration_ms == nil)
          }
          disabled={!@voice_allowed || @voice_operation != nil || @voice_duration_ms == nil}
        >
          Test mic &amp; speaker
        </button>
        <button
          type="button"
          phx-click="voice:talk"
          class="aw-btn aw-btn-sm"
          style={
            disabled_style(!@voice_allowed || @voice_operation != nil || @voice_duration_ms == nil)
          }
          disabled={!@voice_allowed || @voice_operation != nil || @voice_duration_ms == nil}
        >
          Record voice turn
        </button>
        <button
          :if={@voice_operation != nil && @voice_operation[:can_finish] == true}
          type="button"
          phx-click="voice:finish"
          class="aw-btn aw-btn-sm aw-btn-primary"
          disabled={!@voice_allowed}
        >
          {if @voice_operation[:mode] == :loopback, do: "Finish and play", else: "Finish and send"}
        </button>
        <button
          :if={@voice_operation != nil}
          type="button"
          phx-click="voice:cancel"
          class="aw-btn aw-btn-sm aw-btn-danger"
        >
          Cancel
        </button>
      </div>
      <p
        id="voice-desk-status"
        role="status"
        aria-live="polite"
        style={"font-size: 0.8rem; margin: 0.65rem 0 0; color: " <> if(@voice_error, do: "var(--aw-error, #ff7777)", else: "var(--aw-text, #ddd)") <> ";"}
      >
        {@voice_message}
      </p>
    </section>
    """
  end

  defp disabled_style(true), do: "opacity: 0.45; cursor: not-allowed;"
  defp disabled_style(false), do: ""
end
