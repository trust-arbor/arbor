defmodule Arbor.Dashboard.Components.VoiceDeskComponent do
  @moduledoc false
  use Phoenix.Component
  alias Arbor.Dashboard.Config
  alias Arbor.Dashboard.Live.ChatLive.Conversation

  def mount(socket, peer, uri, headers) do
    assign(socket,
      voice_local:
        Config.local_voice_controls?() and loopback?(peer) and local_uri?(uri) and
          direct?(headers),
      voice_operation: nil,
      voice_message: "Start with a 3-second microphone and speaker check.",
      voice_error: false
    )
  end

  def event(socket, action, _params) when action in ["loopback", "talk"] do
    socket = Conversation.refresh(socket)

    if allowed?(socket) and is_nil(socket.assigns.voice_operation) do
      mode = if action == "loopback", do: :loopback, else: :conversation
      user = socket.assigns.current_agent_id
      agent = socket.assigns.agent_id
      token = socket.assigns.session_token

      opts = [
        session_token: token,
        duration_ms: 3_000,
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
    else
      message(socket, :unavailable)
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
        text =
          if mode == :loopback,
            do: "Loopback complete. You should have heard your 3-second recording.",
            else: "Voice turn complete. The transcript is in this conversation."

        send(self(), :refresh_conversation)
        assign(socket, voice_operation: nil, voice_message: text, voice_error: false)

      {:ok, %{terminal: true, error: reason}} ->
        socket |> assign(voice_operation: nil) |> message(reason)

      {:ok, %{terminal: false, state: state}} ->
        Process.send_after(self(), {:voice_desk_poll, id}, 250)
        assign(socket, voice_message: phase(state), voice_error: false)

      _ ->
        retire(socket, id)
    end
  end

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

  defp phase(:capture), do: "Recording for 3 seconds — speak now."
  defp phase(:starting), do: "Connecting voice…"
  defp phase(:turn), do: "Working on your voice turn…"
  defp phase(:presenting), do: "Playing through the host speaker…"

  defp phase(:cleanup_pending),
    do: "Waiting for audio to close. A new recording is blocked until cleanup finishes."

  defp phase(_), do: "Checking conversation access…"

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

  defp error(:start_failed),
    do: "Recording finished, but the voice session could not start."

  defp error(:turn_failed),
    do: "The recording was captured, but the voice response could not be completed."

  defp error(:budget_exhausted), do: "The voice budget is exhausted."
  defp error(:cancelled), do: "Recording cancelled. Audio is closed."
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
          3 seconds · one turn
        </span>
      </div>
      <p style="font-size: 0.8rem; margin: 0.4rem 0 0.65rem; color: var(--aw-text-muted, #aaa);">
        Uses the microphone and speaker on this Arbor host. Loopback stays on this machine.
        A voice turn sends your recording to the configured speech provider.
      </p>
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
          style={disabled_style(!@voice_allowed || @voice_operation != nil)}
          disabled={!@voice_allowed || @voice_operation != nil}
        >
          Test mic &amp; speaker
        </button>
        <button
          type="button"
          phx-click="voice:talk"
          class="aw-btn aw-btn-sm"
          style={disabled_style(!@voice_allowed || @voice_operation != nil)}
          disabled={!@voice_allowed || @voice_operation != nil}
        >
          Record voice turn
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
