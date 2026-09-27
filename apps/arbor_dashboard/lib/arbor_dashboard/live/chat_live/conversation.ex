defmodule Arbor.Dashboard.Live.ChatLive.Conversation do
  @moduledoc """
  Socket-first private chat transport. Every read and admission uses fresh proof
  at Arbor.Agent's public boundary. Transcript and delivery-journal cursors are
  independent; only the journal can establish command completion.
  """

  import Phoenix.Component, only: [assign: 2, update: 3]
  import Phoenix.LiveView, only: [stream: 4, stream_insert: 3, push_event: 3]

  alias Arbor.Dashboard.Config

  @page_size 50
  @auth_error "Sign in with a valid session and chat permission to access this private conversation."

  def mount(socket) do
    assign(socket,
      conversation_authorized: false,
      conversation_engagement_id: nil,
      conversation_rebind_required: false,
      conversation_history_cursor: 0,
      conversation_journal_cursor: 0,
      conversation_pending: nil,
      conversation_status: nil,
      conversation_pending_cursor: 0,
      chat_history_cursor: nil,
      chat_has_more: false
    )
  end

  def connect(socket) do
    socket
    |> clear_private()
    |> mount()
    |> refresh()
  end

  def refresh(socket) do
    if socket.assigns[:group_mode] or is_nil(socket.assigns[:agent_id]) or
         socket.assigns.conversation_rebind_required do
      socket
    else
      with {:ok, history} <-
             request(socket, :conversation_history, [],
               after: socket.assigns.conversation_history_cursor,
               limit: @page_size
             ),
           :ok <- verify_engagement(socket.assigns.conversation_engagement_id, history),
           {:ok, journal} <-
             request(socket, :conversation_events, [socket.assigns.conversation_journal_cursor],
               expected_engagement_id: history.engagement_id,
               limit: @page_size
             ),
           :ok <- verify_engagement(history.engagement_id, journal) do
        socket =
          Enum.reduce(history.entries, socket, fn entry, acc ->
            stream_insert(acc, :messages, display_entry(entry))
          end)

        socket =
          assign(socket,
            conversation_authorized: true,
            conversation_engagement_id: history.engagement_id,
            conversation_history_cursor: history.cursor,
            conversation_journal_cursor: journal.cursor,
            chat_has_more: history.has_more,
            chat_history_cursor: history.cursor
          )

        Enum.reduce(journal.events, socket, fn event, acc ->
          record_command(acc, event.command)
        end)
      else
        {:error, reason} -> failure(socket, reason)
      end
    end
  end

  def submit(socket, text, request_id) do
    socket = ensure_bound(socket)
    pending = socket.assigns.conversation_pending

    cond do
      not socket.assigns.conversation_authorized ->
        socket

      pending && (pending.text != text or pending.id != request_id) ->
        assign(socket, error: "Check the previous delivery before sending a different message.")

      not valid_id?(request_id) ->
        assign(socket, error: "Reconnect before sending so the message has a stable request ID.")

      true ->
        command = %{id: request_id, text: text}
        socket = assign(socket, conversation_pending: command, error: nil)

        # Admission owns a supervised worker in Arbor.Agent. Browser departure
        # cannot cancel it, and repeating this exact ID cannot dispatch twice.
        case request(socket, :submit_conversation_command, [command], []) do
          {:ok, receipt} -> record_command(socket, receipt)
          {:error, reason} -> failure(socket, reason)
        end
    end
  end

  def restore(socket, %{"id" => id, "text" => text})
      when is_binary(text) and byte_size(text) <= 32_768 do
    socket = ensure_bound(socket)

    if valid_id?(id) and socket.assigns.conversation_authorized do
      socket =
        assign(socket,
          conversation_pending: %{id: id, text: text},
          conversation_pending_cursor: 0
        )

      # Restoring a tab only checks its receipt. It never resubmits a message.
      case request(socket, :conversation_command, [id], []) do
        {:ok, receipt} ->
          record_command(socket, receipt)

        {:error, :not_found} ->
          assign(socket,
            conversation_status: :not_found,
            loading: false,
            error: "This message has no confirmed admission. Retry preserves its request ID."
          )

        {:error, reason} ->
          failure(socket, reason)
      end
    else
      socket
    end
  end

  def restore(socket, _), do: socket

  def retry(socket) do
    case socket.assigns.conversation_pending do
      %{id: id, text: text} ->
        case request(socket, :conversation_command, [id], []) do
          {:ok, %{status: :admitted} = receipt} ->
            case verify_engagement(socket.assigns.conversation_engagement_id, receipt) do
              :ok -> submit(socket, text, id)
              {:error, reason} -> failure(socket, reason)
            end

          {:ok, receipt} ->
            record_command(socket, receipt)

          {:error, :not_found} ->
            submit(socket, text, id)

          {:error, reason} ->
            failure(socket, reason)
        end

      _ ->
        socket
    end
  end

  def reconnect(socket), do: connect(socket)

  def dismiss(socket) do
    # Explicitly starting another message is distinct from retrying an unknown
    # delivery. Keep any newer composer draft intact.
    socket
    |> push_event("conversation-clear-pending", %{id: pending_id(socket)})
    |> assign(
      conversation_pending: nil,
      conversation_pending_cursor: 0,
      conversation_status: nil,
      loading: false,
      error: nil
    )
  end

  def clear_private(socket) do
    socket =
      assign(socket,
        conversation_authorized: false,
        loading: false,
        streaming_text: "",
        memory_stats: nil,
        agent_goals: [],
        signal_count: 0,
        thinking_count: 0,
        memories_count: 0,
        action_count: 0,
        approvals_count: 0,
        llm_interactions_count: 0,
        known_approval_ids: MapSet.new(),
        last_llm_thinking: nil,
        last_memory_notes: [],
        last_concerns: [],
        last_curiosity: [],
        last_identity_insights: []
      )

    Enum.reduce(
      [:messages, :signals, :thinking, :memories, :actions, :llm_interactions, :approvals],
      socket,
      fn name, acc ->
        # LiveView's reset flag clears the browser DOM, but retains inserts
        # queued before this render. Drop those too before publishing denial.
        acc
        |> update(:streams, fn streams ->
          Map.update!(streams, name, &%{&1 | inserts: [], deletes: []})
        end)
        |> stream(name, [], reset: true)
      end
    )
  end

  defp record_command(socket, command) do
    case verify_engagement(socket.assigns.conversation_engagement_id, command) do
      :ok -> record_owned_command(socket, command)
      {:error, reason} -> failure(socket, reason)
    end
  end

  defp record_owned_command(socket, command) do
    if command.id == pending_id(socket) and
         command.updated_cursor >= socket.assigns.conversation_pending_cursor do
      socket =
        assign(socket,
          conversation_status: command.status,
          conversation_pending_cursor: command.updated_cursor,
          loading: false
        )

      case command.status do
        :completed ->
          socket
          |> push_event("conversation-completed", %{id: command.id, text: command.text})
          |> assign(
            conversation_pending: nil,
            input: if(socket.assigns.input == command.text, do: "", else: socket.assigns.input),
            error: nil
          )

        :uncertain ->
          assign(socket,
            error:
              "Delivery outcome is unknown. The saved request will not run again. Check the transcript before starting another message."
          )

        :dispatch_started ->
          assign(socket, error: nil)

        :admitted ->
          assign(socket, error: nil)
      end
    else
      socket
    end
  end

  defp failure(socket, :conversation_scope_changed) do
    socket
    |> clear_private()
    |> mount()
    |> assign(
      input: "",
      conversation_rebind_required: true,
      error:
        "Conversation ownership changed. Reconnect to load the current conversation; the old draft and delivery are detached."
    )
    |> push_event("conversation-access-denied", %{})
  end

  defp failure(socket, :unauthorized) do
    socket
    |> clear_private()
    |> mount()
    |> assign(input: "", error: @auth_error)
    |> push_event("conversation-access-denied", %{})
  end

  defp failure(socket, reason) do
    message =
      case reason do
        :command_conflict ->
          "That request ID belongs to different text. The message was not sent."

        :invalid_command ->
          "The message or request ID is invalid. The draft has been kept."

        _ ->
          "Conversation unavailable. Delivery is unconfirmed; the draft and request ID have been kept."
      end

    assign(socket, loading: false, error: message)
  end

  defp request(socket, function, args, opts) do
    principal = socket.assigns[:current_agent_id]
    token = socket.assigns[:session_token]
    target = socket.assigns[:agent_id]

    if is_binary(principal) and principal != "" and is_binary(token) and token != "" and
         is_binary(target) and target != "" do
      opts =
        if socket.assigns.conversation_engagement_id do
          Keyword.put_new(
            opts,
            :expected_engagement_id,
            socket.assigns.conversation_engagement_id
          )
        else
          opts
        end

      apply(
        Config.conversation_api(),
        function,
        [principal, target] ++ args ++ [[session_token: token] ++ opts]
      )
    else
      {:error, :unauthorized}
    end
  rescue
    _ -> {:error, :conversation_unavailable}
  catch
    :exit, _ -> {:error, :conversation_unavailable}
  end

  defp ensure_bound(socket) do
    if socket.assigns.conversation_engagement_id, do: socket, else: refresh(socket)
  end

  defp verify_engagement(expected, %{engagement_id: engagement_id})
       when is_binary(engagement_id) and byte_size(engagement_id) > 0 do
    if is_nil(expected) or expected == engagement_id,
      do: :ok,
      else: {:error, :conversation_scope_changed}
  end

  defp verify_engagement(_expected, _page), do: {:error, :conversation_scope_changed}

  defp pending_id(socket) do
    case socket.assigns[:conversation_pending] do
      %{id: id} -> id
      _ -> nil
    end
  end

  defp valid_id?(id),
    do: is_binary(id) and byte_size(id) in 1..128 and Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, id)

  defp display_entry(entry) do
    %{
      id: entry.id,
      role: if(entry.role in [:user, "user"], do: :user, else: :assistant),
      content: entry.content,
      timestamp: entry.timestamp,
      tool_uses: [],
      memory_count: 0,
      model: nil,
      session_id: nil
    }
  end
end
