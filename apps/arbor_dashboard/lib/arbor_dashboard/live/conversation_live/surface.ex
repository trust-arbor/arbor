defmodule Arbor.Dashboard.Live.ConversationLive.Surface do
  @moduledoc """
  Socket-first surface over the maintained private Connection owner. Assigns
  contain display snapshots and the connection PID, never adapter clients or
  transport callbacks. Voice admission independently checks fresh host authority.
  """
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [push_event: 3]
  alias Arbor.Dashboard.Config
  alias Arbor.Dashboard.ConversationReviewCore
  alias ConversationKit.Composer
  alias ConversationKit.Arbor
  alias ConversationKit.Arbor.Connection

  def mount(socket, target) do
    assign(socket,
      conversation_surface: true,
      conversation_connection: nil,
      conversation_monitor: nil,
      conversation_snapshot: empty_snapshot(),
      conversation_authorized: false,
      conversation_engagement_id: nil,
      conversation_rebind_required: false,
      conversation_notice: nil,
      conversation_local_notice: nil,
      conversation_navigation: :latest,
      conversation_composer: Composer.new(),
      conversation_reviews: ConversationReviewCore.new(),
      agent_id: target,
      group_mode: false,
      input: ""
    )
  end

  def connect(socket) do
    socket = refresh_access(assign(socket, conversation_rebind_required: false))

    if socket.assigns.conversation_authorized do
      case socket.assigns.conversation_connection do
        pid when is_pid(pid) ->
          Connection.act(pid, :reconnect)
          socket

        nil ->
          token = socket.assigns.session_token

          options = [
            caller: socket.assigns.current_agent_id,
            target: socket.assigns.agent_id,
            approval_answer_allowed: true,
            proof_provider: fn _request -> {:ok, [session_token: token]} end,
            adapter_options: [
              facade: Config.conversation_api(),
              page_limit: 20,
              expected_engagement_id: socket.assigns.conversation_engagement_id
            ]
          ]

          case Connection.start(options) do
            {:ok, pid} ->
              assign(socket,
                conversation_connection: pid,
                conversation_monitor: Process.monitor(pid),
                conversation_notice: nil,
                conversation_navigation: :latest
              )

            _ ->
              assign(socket,
                conversation_notice: "The conversation could not connect. Try reconnecting."
              )
          end
      end
    else
      socket
    end
  end

  # This is intentionally synchronous and bounded. A previous asynchronous
  # display snapshot cannot authorize the microphone or bind a voice turn.
  def refresh_access(socket) do
    if socket.assigns.conversation_rebind_required do
      socket
    else
      opts = [session_token: socket.assigns[:session_token], limit: 1]
      expected = socket.assigns.conversation_engagement_id
      opts = if expected, do: Keyword.put(opts, :expected_engagement_id, expected), else: opts

      case access_window(socket, opts) do
        {:ok, %{engagement_id: engagement}} when is_binary(engagement) ->
          if (is_nil(expected) or engagement == expected) and
               Regex.match?(~r/\Aeng_[0-9a-f]{32}\z/, engagement) do
            assign(socket,
              conversation_authorized: true,
              conversation_engagement_id: engagement,
              conversation_notice: nil
            )
          else
            clear_private(socket)
          end

        {:error, reason}
        when reason in [:unauthorized, :conversation_scope_changed, :scope_mismatch] ->
          clear_private(socket)

        _ ->
          assign(socket,
            conversation_authorized: false,
            conversation_notice:
              "Conversation access could not be confirmed. Reconnect to try again."
          )
      end
    end
  end

  def update(socket, pid, snapshot) do
    if pid == socket.assigns.conversation_connection do
      cond do
        snapshot.private_cleared or
            (snapshot.connected and
               snapshot.engagement_id != socket.assigns.conversation_engagement_id) ->
          clear_private(socket)

        socket.assigns.conversation_rebind_required ->
          socket

        true ->
          previous = socket.assigns.conversation_snapshot
          socket = assign(socket, conversation_snapshot: snapshot)

          socket =
            if snapshot.connected and not socket.assigns.conversation_authorized,
              do: refresh_access(socket),
              else: socket

          socket = sync_reviews(socket)

          case snapshot.ack do
            %{id: id, text: text} ->
              composer =
                Composer.acknowledge(socket.assigns.conversation_composer, %{id: id, text: text})

              socket
              |> assign(conversation_composer: composer, input: composer.draft)
              |> push_event("conversation-completed", %{id: id, text: text})

            _ ->
              if previous.pending_id && is_nil(snapshot.pending_id) do
                composer =
                  Composer.reject(socket.assigns.conversation_composer, previous.pending_id)

                socket
                |> assign(conversation_composer: composer)
                |> push_event("conversation-clear-pending", %{id: previous.pending_id})
              else
                socket
              end
          end
      end
    else
      socket
    end
  end

  def event(socket, "update-input", %{"message" => text})
      when is_binary(text) and byte_size(text) <= 32_768 do
    if String.valid?(text) do
      assign(socket,
        input: text,
        conversation_composer: Composer.draft(socket.assigns.conversation_composer, text)
      )
    else
      socket
    end
  end

  def event(socket, "send-message", %{"message" => text} = params) do
    case Arbor.classify_composer_input(text) do
      {:message, original} ->
        submit_message(socket, original, params["command_id"])

      {:local, action} ->
        socket |> retire_local_marker(params["command_id"]) |> local_action(action)

      {:unavailable, reason} ->
        socket |> retire_local_marker(params["command_id"]) |> local_refusal(reason)

      {:error, :invalid_input} ->
        local_refusal(socket, :invalid_input)
    end
  end

  def event(socket, "conversation:restore", %{"id" => id, "text" => text})
      when is_binary(id) and byte_size(id) in 1..128 do
    case Arbor.classify_composer_input(text) do
      {:message, original} -> act(socket, :restore, %{id: id, text: original})
      _ -> retire_local_marker(socket, id)
    end
  end

  def event(socket, "conversation:help", _), do: local_action(socket, :help)

  def event(socket, "conversation:close-help", _),
    do: assign(socket, conversation_local_notice: nil)

  def event(socket, "conversation:cancel", params),
    do: control_event(socket, :cancel, params, ~w(command_id))

  def event(socket, "conversation:choose", params),
    do:
      control_event(
        socket,
        :choose,
        params,
        ~w(command_id request_id operation_id revision choice_id)
      )

  def event(socket, "conversation:review-change", params) do
    socket = sync_reviews(socket)

    with {:ok, params} <- review_params(params, :change),
         {:ok, input} <- control_input(params),
         {:ok, reviews} <- ConversationReviewCore.edit(socket.assigns.conversation_reviews, input) do
      assign(socket, conversation_reviews: reviews)
    else
      _ -> socket
    end
  end

  def event(socket, "conversation:approve", params) do
    with {:ok, params} <- review_params(params, :submit) do
      control_event(
        socket,
        :approve,
        params,
        ~w(command_id request_id operation_id revision decision note)
      )
    else
      _ -> socket
    end
  end

  def event(socket, "conversation:reconnect", _), do: connect(socket)

  def event(socket, "conversation:" <> action, _) do
    case action do
      "older" -> socket |> assign(conversation_navigation: :browsing) |> act(:older)
      "newer" -> socket |> assign(conversation_navigation: :browsing) |> act(:newer)
      "latest" -> socket |> assign(conversation_navigation: :latest) |> act(:latest)
      "more-activity" -> act(socket, :more_activity)
      "latest-activity" -> act(socket, :latest_activity)
      "older-notices" -> act(socket, :older_notices)
      "latest-notices" -> act(socket, :latest_notices)
      "refresh" -> act(socket, :refresh)
      "retry" -> act(socket, :retry)
      "disconnect" -> socket |> assign(conversation_authorized: false) |> act(:disconnect)
      _ -> socket
    end
  end

  def event(socket, _, _), do: socket

  def composer_submit_allowed?(assigns) do
    case Arbor.classify_composer_input(assigns.input) do
      {:message, text} ->
        assigns.conversation_authorized and assigns.conversation_snapshot.send_allowed and
          String.trim(text) != ""

      {:error, _} ->
        false

      _ ->
        true
    end
  end

  defp submit_message(socket, text, id) when is_binary(id) and byte_size(id) in 1..128 do
    composer = socket.assigns.conversation_composer
    composer = if composer.draft == text, do: composer, else: Composer.draft(composer, text)

    allowed =
      socket.assigns.conversation_authorized and socket.assigns.conversation_snapshot.send_allowed

    case Composer.submit(composer, allowed, id) do
      {:send, request, next} ->
        socket
        |> assign(input: next.draft, conversation_composer: next, conversation_local_notice: nil)
        |> act(:send, request)

      {:ignored, next} ->
        assign(socket, input: next.draft, conversation_composer: next)
    end
  end

  defp submit_message(socket, _, _), do: socket

  # The browser hook may have allocated a marker for local input. Retiring it
  # never acknowledges a host command and must not replace a saved delivery.
  defp retire_local_marker(socket, id) when is_binary(id) and byte_size(id) in 1..128 do
    submitted = socket.assigns.conversation_composer.submitted
    protected_id = if submitted, do: submitted.id, else: nil

    if id in [socket.assigns.conversation_snapshot.pending_id, protected_id],
      do: socket,
      else: push_event(socket, "conversation-clear-pending", %{id: id})
  end

  defp retire_local_marker(socket, _), do: socket

  defp local_action(socket, :help) do
    assign(socket,
      conversation_local_notice:
        "Local commands: /help, /retry, /refresh, /disconnect, /reconnect, /older, /newer, /latest, /work, /more-work, /latest-work, /notices, /older-notices, /latest-notices. Retry checks the saved request with its original ID. Use /agents or /attach TOKEN for authenticated Home guidance. Manage agents through the authorized Console or CLI; runtime slash commands are unavailable here."
    )
  end

  defp local_action(socket, :quit),
    do:
      assign(socket,
        conversation_local_notice:
          "Close this browser tab to leave. Use Disconnect to pause this conversation connection."
      )

  defp local_action(socket, :agents), do: navigation_guidance(socket)
  defp local_action(socket, {:attach, _token}), do: navigation_guidance(socket)

  defp local_action(socket, :work),
    do:
      assign(socket,
        conversation_local_notice:
          "Current work appears above the composer. Use its exact choice, cancellation or browser-review controls."
      )

  defp local_action(socket, :notices),
    do:
      assign(socket,
        conversation_local_notice:
          "Notices appear in a separate read-only panel above the composer. Older notices retain their original cutoff; Latest notices explicitly checks the current head."
      )

  defp local_action(socket, :older_notices), do: event(socket, "conversation:older-notices", %{})

  defp local_action(socket, :latest_notices),
    do: event(socket, "conversation:latest-notices", %{})

  defp local_action(socket, :more_activity), do: event(socket, "conversation:more-activity", %{})

  defp local_action(socket, :latest_activity),
    do: event(socket, "conversation:latest-activity", %{})

  defp local_action(socket, action),
    do: event(socket, "conversation:" <> Atom.to_string(action), %{})

  defp navigation_guidance(socket),
    do:
      assign(socket,
        conversation_local_notice:
          "Select a conversation through the authenticated Home at /home. This local command did not change the target or send anything to the agent."
      )

  defp local_refusal(socket, :management),
    do:
      assign(socket,
        conversation_local_notice:
          "Agent management is unavailable in this conversation. Use the authorized Console or CLI; a chat session does not grant management permission."
      )

  defp local_refusal(socket, :runtime_command),
    do:
      assign(socket,
        conversation_local_notice:
          "Runtime slash commands are unavailable in this conversation. Use /help for local commands. Nothing was sent to the agent."
      )

  defp local_refusal(socket, :invalid_input),
    do:
      assign(socket,
        conversation_local_notice:
          "Input must be valid UTF-8 and at most 32 KiB. Nothing was sent to the agent."
      )

  def down(socket, ref) do
    if ref == socket.assigns.conversation_monitor do
      assign(socket,
        conversation_connection: nil,
        conversation_monitor: nil,
        conversation_snapshot: empty_snapshot(),
        conversation_authorized: false,
        conversation_notice: "The connection closed. Reconnect to check your saved request."
      )
    else
      socket
    end
  end

  def close(socket) do
    if pid = socket.assigns[:conversation_connection], do: Connection.close(pid)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp control_event(socket, action, params, keys) do
    # LiveView adds the HTMLButtonElement's empty value to native click metadata.
    # Only choice/cancel buttons have this compatibility field; all selectors
    # remain exact and arbitrary or nonempty metadata still fails closed.
    params =
      if action in [:cancel, :choose] and is_map(params) and params["value"] == "",
        do: Map.delete(params, "value"),
        else: params

    snapshot = socket.assigns.conversation_snapshot

    allowed =
      socket.assigns.conversation_authorized and snapshot.connected and
        Map.get(snapshot, :control_action_allowed, false) and
        Map.get(snapshot, :controls_available, false) and
        (action != :approve or Map.get(snapshot, :approval_answer_allowed, false))

    with true <- allowed,
         true <- is_map(params) and Enum.sort(Map.keys(params)) == Enum.sort(keys),
         {:ok, input} <- control_input(params) do
      act(socket, action, input)
    else
      _ -> socket
    end
  end

  defp sync_reviews(socket) do
    snapshot = socket.assigns.conversation_snapshot

    scope =
      {socket.assigns[:current_agent_id], socket.assigns.agent_id,
       socket.assigns.conversation_engagement_id}

    reviews =
      ConversationReviewCore.sync(
        socket.assigns.conversation_reviews,
        scope,
        Map.get(snapshot.controls, "interactions", []),
        socket.assigns.conversation_authorized and snapshot.connected and
          not snapshot.private_cleared
      )

    assign(socket, conversation_reviews: reviews)
  end

  defp review_params(params, kind) when is_map(params) and not is_struct(params) do
    unused = ~w(_unused_decision _unused_note)

    valid_unused =
      Enum.all?(unused, fn key -> not Map.has_key?(params, key) or params[key] == "" end)

    valid_target =
      if kind == :change,
        do: params["_target"] in [["decision"], ["note"]],
        else: not Map.has_key?(params, "_target")

    params = if kind == :change, do: Map.delete(params, "_target"), else: params
    params = Map.drop(params, unused)
    expected = ~w(command_id request_id operation_id revision decision note)

    if valid_unused and valid_target and Enum.sort(Map.keys(params)) == Enum.sort(expected),
      do: {:ok, params},
      else: {:error, :invalid_review_params}
  end

  defp review_params(_, _), do: {:error, :invalid_review_params}

  defp control_input(params) do
    # Closed event names determine these atoms; none are derived from client data.
    fields = [
      command_id: "command_id",
      request_id: "request_id",
      operation_id: "operation_id",
      choice_id: "choice_id",
      decision: "decision",
      note: "note"
    ]

    input =
      Map.new(for {key, name} <- fields, Map.has_key?(params, name), do: {key, params[name]})

    case Map.fetch(params, "revision") do
      :error ->
        {:ok, input}

      {:ok, revision} when is_binary(revision) ->
        case Integer.parse(revision) do
          {value, ""} when value in 1..2_147_483_647 -> {:ok, Map.put(input, :revision, value)}
          _ -> {:error, :invalid_revision}
        end

      _ ->
        {:error, :invalid_revision}
    end
  end

  defp act(socket, action, input \\ nil) do
    if pid = socket.assigns.conversation_connection, do: Connection.act(pid, action, input)
    socket
  end

  defp access_window(socket, opts) do
    if is_binary(socket.assigns[:current_agent_id]) and is_binary(socket.assigns[:session_token]) and
         socket.assigns.session_token != "" do
      apply(Config.conversation_api(), :conversation_window, [
        socket.assigns.current_agent_id,
        socket.assigns.agent_id,
        opts
      ])
    else
      {:error, :unauthorized}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp clear_private(socket) do
    close(socket)
    if ref = socket.assigns.conversation_monitor, do: Process.demonitor(ref, [:flush])

    socket
    |> assign(
      conversation_connection: nil,
      conversation_monitor: nil,
      conversation_authorized: false,
      conversation_engagement_id: nil,
      conversation_rebind_required: true,
      conversation_snapshot: empty_snapshot(),
      input: "",
      conversation_composer: Composer.clear(socket.assigns.conversation_composer),
      conversation_reviews: ConversationReviewCore.new(),
      conversation_notice:
        "Conversation access changed. Private data was cleared. Reconnect to continue."
    )
    |> push_event("conversation-access-denied", %{})
  end

  defp empty_snapshot do
    %{
      projection: %{
        "messages" => [],
        "deliveries" => [],
        "notices" => [],
        "blocks" => [],
        "speech" => []
      },
      notices_status: :unavailable,
      notice_window: %{head: 0, through: 0, has_older: false, next_before: nil, complete: false},
      window: %{head: 0, first: 0, last: 0, has_older: false, has_newer: false},
      connected: false,
      busy: false,
      error: nil,
      private_cleared: false,
      engagement_id: nil,
      pending_id: nil,
      receipt: nil,
      ack: nil,
      send_allowed: false,
      retry_allowed: false,
      controls: %{"activities" => [], "interactions" => [], "blocks" => [], "speech" => []},
      controls_available: false,
      approval_answer_allowed: false,
      control_action_allowed: false,
      controls_discovery: %{has_more: false, incomplete: false, truncated: false}
    }
  end
end
