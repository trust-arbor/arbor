defmodule Arbor.Dashboard.Live.ConversationLive do
  @moduledoc "Candidate Home and native surface for authenticated private conversations."
  use Phoenix.LiveView, log: false
  alias Arbor.Dashboard.Components.VoiceDeskComponent
  alias Arbor.Dashboard.ConversationReviewCore
  alias Arbor.Dashboard.Live.ConversationLive.{Home, Surface}

  @impl true
  def mount(params, _session, socket) do
    Process.flag(:sensitive, true)
    target = params["agent_id"]

    socket =
      socket
      |> assign(page_title: "Conversation")
      |> Surface.mount(target)
      |> Home.mount(is_nil(target))

    socket =
      VoiceDeskComponent.mount(
        socket,
        if(connected?(socket), do: get_connect_info(socket, :peer_data)),
        if(connected?(socket), do: get_connect_info(socket, :uri)),
        if(connected?(socket), do: get_connect_info(socket, :x_headers))
      )

    {:ok, if(connected?(socket) and target, do: Surface.connect(socket), else: socket)}
  end

  @impl true
  def handle_params(params, _uri, socket), do: {:noreply, Home.route(socket, params)}

  @impl true
  def handle_event("home:" <> _ = event, params, socket),
    do: {:noreply, Home.event(socket, event, params)}

  # The voice desk re-checks conversation authority through the Surface's
  # synchronous access check before any audio-admitting action.
  def handle_event("voice:" <> action, params, socket),
    do:
      {:noreply,
       socket
       |> VoiceDeskComponent.event(action, params, &Surface.refresh_access/1)
       |> Home.sync()}

  def handle_event(event, params, socket),
    do: {:noreply, socket |> Surface.event(event, params) |> Home.sync()}

  @impl true
  def handle_info({:conversation_updated, pid, snapshot}, socket),
    do: {:noreply, socket |> Surface.update(pid, snapshot) |> Home.sync()}

  def handle_info({:home_result, pid, generation, kind, result}, socket),
    do: {:noreply, Home.result(socket, pid, generation, kind, result)}

  def handle_info({:home_timeout, pid, generation, kind}, socket),
    do: {:noreply, Home.timeout(socket, pid, generation, kind)}

  def handle_info(:home_refresh, socket), do: {:noreply, Home.refresh(socket)}

  def handle_info({:voice_desk_poll, id}, socket),
    do: {:noreply, VoiceDeskComponent.poll(socket, id)}

  def handle_info(:refresh_conversation, socket),
    do: {:noreply, Surface.event(socket, "conversation:refresh", %{})}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, socket),
    do: {:noreply, socket |> Home.down(ref) |> Surface.down(ref) |> Home.sync()}

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def terminate(_, socket) do
    Home.close(socket)
    Surface.close(socket)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="conversation-home"
      phx-hook="ConversationHome"
      class={if @home_enabled, do: "aw-home", else: "aw-home is-single"}
    >
      <a href="#conversation-main" class="aw-home-skip">Skip to conversation</a>
      <button
        :if={@home_enabled}
        type="button"
        phx-click="home:rail"
        class="aw-home-rail-toggle"
        aria-controls="conversation-rail"
        aria-expanded={to_string(@home_rail_open)}
      >
        Your conversations
      </button>
      <Home.rail
        :if={@home_enabled}
        rows={@home_rows}
        selected={@home_selected}
        loading={Map.has_key?(@home_workers, :index)}
        loaded={@home_loaded}
        more={@home_has_more}
        cursor={@home_page_cursor}
        open={@home_rail_open}
      />
      <main
        id="conversation-main"
        class="aw-home-main"
        tabindex="-1"
        aria-busy={to_string(Map.has_key?(@home_workers, :reference))}
      >
        <p :if={@home_notice} id="conversation-home-notice" class="aw-home-notice" role="status">
          {@home_notice}
        </p>
        <div :if={is_nil(@agent_id)} class="aw-home-welcome">
          <p class="aw-conversation-eyebrow">Arbor / home</p>
          <h1>A place to continue.</h1>
          <p :if={Map.has_key?(@home_workers, :reference)} role="status">
            Opening your conversation…
          </p>
          <p :if={!Map.has_key?(@home_workers, :reference)}>
            Choose a conversation to pick up where you left off.
          </p>
        </div>
        <div :if={@agent_id} class="aw-conversation" id="conversation-surface">
          <header class="aw-conversation-heading">
            <div>
              <p class="aw-conversation-eyebrow">Arbor / conversation</p>
              <h1 id="conversation-title">
                {if @home_selected, do: @home_selected.display_name, else: "Conversation"}
              </h1>
              <p class="aw-conversation-target">{@agent_id}</p>
            </div>
            <div class="aw-conversation-connection" role="status" aria-live="polite">
              <span class={
                if @conversation_snapshot.connected,
                  do: "aw-conversation-dot is-connected",
                  else: "aw-conversation-dot"
              }>
              </span>
              {if @conversation_snapshot.connected, do: "Connected", else: "Disconnected"}
              <button
                :if={@conversation_snapshot.connected}
                phx-click="conversation:disconnect"
                type="button"
              >
                Disconnect
              </button>
              <button
                :if={!@conversation_snapshot.connected}
                phx-click="conversation:reconnect"
                type="button"
              >
                Reconnect
              </button>
            </div>
          </header>
          <Home.inspector
            :if={@home_selected && @conversation_authorized}
            selected={@home_selected}
            snapshot={@conversation_snapshot}
          />
          <div class="aw-conversation-paper">
            <nav class="aw-conversation-history" aria-label="Conversation history">
              <div>
                <button
                  type="button"
                  phx-click="conversation:older"
                  disabled={!@conversation_snapshot.window.has_older || @conversation_snapshot.busy}
                >
                  ← Older
                </button>
                <button
                  type="button"
                  phx-click="conversation:newer"
                  disabled={!@conversation_snapshot.window.has_newer || @conversation_snapshot.busy}
                >
                  Newer →
                </button>
                <button
                  type="button"
                  phx-click="conversation:latest"
                  disabled={!@conversation_snapshot.connected}
                >
                  Latest
                </button>
              </div>
              <span>{length(@conversation_snapshot.projection["messages"])} messages in view</span>
            </nav>
            <div
              id="conversation-scroll"
              class="aw-conversation-scroll"
              phx-hook="ConversationScroll"
              data-mode={@conversation_navigation}
              data-window={"#{@conversation_snapshot.window.first}:#{@conversation_snapshot.window.last}"}
              tabindex="0"
              aria-label="Conversation messages"
            >
              <div
                :if={@conversation_snapshot.projection["messages"] == []}
                class="aw-conversation-empty"
              >
                <span aria-hidden="true">✳</span>
                <h2>
                  {if @conversation_authorized,
                    do: "What’s on your mind?",
                    else: "Your conversation is private."}
                </h2>
                <p>
                  {if @conversation_authorized,
                    do: "Send a message to begin. Typed and voice turns share this history.",
                    else: "Sign in with chat access to this agent to continue."}
                </p>
              </div>
              <article
                :for={message <- @conversation_snapshot.projection["messages"]}
                id={"conversation-message-" <> message["id"]}
                data-conversation-message="true"
                class={"aw-conversation-message is-" <> message["role"]}
              >
                <div class="aw-conversation-message-meta">
                  <strong>{role_label(message["role"])}</strong>
                  <span
                    :if={message["status_text"]}
                    data-conversation-message-status={message["status"]}
                  >
                    {message["status_text"]}
                  </span>
                  <time :if={message["timestamp"]} datetime={message["timestamp"]}>
                    {message["timestamp"]}
                  </time>
                </div>
                <p>{message["text"]}</p>
              </article>
            </div>
            <div
              :if={@conversation_notice || @conversation_snapshot.error}
              class="aw-conversation-notice"
              role="status"
            >
              {@conversation_notice || @conversation_snapshot.error}
            </div>
            <div
              :if={@conversation_snapshot.pending_id || @conversation_snapshot.receipt}
              class="aw-conversation-delivery"
              role="status"
              aria-live="polite"
            >
              <span>{delivery_label(@conversation_snapshot)}</span>
              <button
                :if={@conversation_snapshot.pending_id}
                type="button"
                phx-click="conversation:retry"
                disabled={!@conversation_snapshot.retry_allowed}
              >
                Check / retry saved request
              </button>
            </div>
            <.conversation_controls
              snapshot={@conversation_snapshot}
              authorized={@conversation_authorized}
              reviews={@conversation_reviews}
            />
            <.conversation_notices
              snapshot={@conversation_snapshot}
              authorized={@conversation_authorized}
            />
            <VoiceDeskComponent.controls {assigns} />
            <aside
              :if={@conversation_local_notice}
              id="conversation-local-notice"
              class="aw-conversation-notice"
              role="status"
              aria-live="polite"
            >
              <p>{@conversation_local_notice}</p>
              <a :if={@conversation_authorized} href="#conversation-controls">Current work</a>
              <button type="button" phx-click="conversation:close-help">Dismiss</button>
            </aside>
            <form
              id="conversation-composer"
              class="aw-conversation-composer"
              phx-hook="ConversationDraft"
              phx-submit="send-message"
              phx-change="update-input"
              data-conversation-plain-text="true"
              data-conversation-authorized={to_string(@conversation_authorized)}
              data-conversation-key={scope_key(assigns)}
            >
              <input type="hidden" name="command_id" value="" />
              <label for="conversation-message-input">Message</label>
              <textarea
                id="conversation-message-input"
                name="message"
                rows="3"
                maxlength="32768"
                placeholder="Write a message…"
                autocomplete="off"
                disabled={!@conversation_authorized}
                aria-describedby="conversation-composer-help"
              >{@input}</textarea>
              <div class="aw-conversation-composer-footer">
                <span id="conversation-composer-help">
                  Ctrl / ⌘ Enter to send · Enter for a new line
                </span>
                <button type="button" phx-click="conversation:help">Local help</button>
                <button
                  type="submit"
                  disabled={!Surface.composer_submit_allowed?(assigns)}
                >
                  Send message <span aria-hidden="true">↗</span>
                </button>
              </div>
            </form>
          </div>
          <footer class="aw-conversation-footnote">
            <span>Private conversation</span>
          </footer>
        </div>
      </main>
    </div>
    """
  end

  attr(:snapshot, :map, required: true)
  attr(:authorized, :boolean, required: true)

  defp conversation_notices(assigns) do
    assigns =
      assigns
      |> assign(:notices, Map.get(assigns.snapshot.projection, "notices", []))
      |> assign(:notice_status, Map.get(assigns.snapshot, :notices_status, :unavailable))
      |> assign(:notice_window, Map.get(assigns.snapshot, :notice_window, %{has_older: false}))
      |> assign(
        :can_read,
        assigns.authorized and assigns.snapshot.connected and not assigns.snapshot.busy
      )

    ~H"""
    <section
      id="conversation-notices"
      class="aw-conversation-controls"
      aria-labelledby="conversation-notices-title"
    >
      <div class="aw-conversation-controls-heading">
        <h2 id="conversation-notices-title">Notices</h2>
      </div>
      <p id="conversation-notices-status" role="status" aria-live="polite">
        {notice_status(@notice_status, @notices)}
      </p>
      <p :if={@notice_status == :available} class="aw-conversation-control-status">
        Page cutoff {@notice_window.through} · latest observed {@notice_window.head}
      </p>
      <ol
        class="aw-conversation-controls-list"
        tabindex="0"
        aria-label="Read-only conversation notices"
      >
        <li :for={notice <- @notices} id={"conversation-notice-" <> notice["id"]}>
          <span>{String.capitalize(notice["kind"])}</span>
          <time datetime={notice["timestamp"]}>{notice["timestamp"]}</time>
          <p class="aw-conversation-control-text">{notice["text"]}</p>
        </li>
      </ol>
      <button
        type="button"
        phx-click="conversation:older-notices"
        disabled={!@can_read || !@notice_window.has_older}
      >
        Older notices
      </button>
      <button
        type="button"
        phx-click="conversation:latest-notices"
        disabled={!@can_read || @notice_status == :unsupported}
      >
        Latest notices
      </button>
      <p>Read-only updates · no message or audio is sent</p>
    </section>
    """
  end

  defp notice_status(:checking, _), do: "Checking notices…"
  defp notice_status(:available, []), do: "No notices in this page."
  defp notice_status(:available, _), do: "Notices available."
  defp notice_status(:unsupported, _), do: "Notices require a human conversation identity."
  defp notice_status(_, _), do: "Notices could not be checked. Refresh to try again."

  attr(:snapshot, :map, required: true)
  attr(:authorized, :boolean, required: true)
  attr(:reviews, :map, required: true)

  defp conversation_controls(assigns) do
    assigns =
      assigns
      |> assign(
        :controls,
        Map.get(assigns.snapshot, :controls, %{"activities" => [], "interactions" => []})
      )
      |> assign(:available, Map.get(assigns.snapshot, :controls_available, false))
      |> assign(
        :discovery,
        Map.get(assigns.snapshot, :controls_discovery, %{
          has_more: false,
          incomplete: false,
          truncated: false
        })
      )
      |> assign(
        :can_act,
        assigns.authorized and assigns.snapshot.connected and
          Map.get(assigns.snapshot, :control_action_allowed, false)
      )
      |> assign(:can_edit, assigns.authorized and assigns.snapshot.connected)
      |> assign(:can_approve, Map.get(assigns.snapshot, :approval_answer_allowed, false))

    ~H"""
    <section
      :if={@authorized}
      id="conversation-controls"
      class="aw-conversation-controls"
      aria-label="Current conversation work"
      aria-busy={to_string(@snapshot.busy)}
    >
      <header class="aw-conversation-controls-heading">
        <h2>Current work</h2>
        <div>
          <button
            :if={@available && @discovery.has_more}
            type="button"
            phx-click="conversation:more-activity"
            disabled={!@can_act}
          >
            Earlier work
          </button>
          <button
            :if={@available}
            type="button"
            phx-click="conversation:latest-activity"
            disabled={!@can_act}
          >
            Latest work
          </button>
        </div>
      </header>
      <p :if={!@available} id="conversation-controls-unavailable" role="status">
        Current work could not be checked. Refresh to try again.
      </p>
      <p :if={@available && (@discovery.incomplete || @discovery.truncated)} role="status">
        This is a partial view of current work. Some work or prompts are not displayed.
      </p>
      <p :if={@available && @controls["activities"] == [] && @controls["interactions"] == []}>
        No current work in this view.
      </p>
      <div :if={@available} class="aw-conversation-controls-list">
        <article
          :for={activity <- @controls["activities"]}
          id={"conversation-activity-" <> activity["command_id"]}
          class="aw-conversation-activity"
        >
          <div class="aw-conversation-control-row">
            <div>
              <strong>Message work</strong>
              <span class="aw-conversation-control-id">{activity["command_id"]}</span>
            </div>
            <button
              :if={activity["cancel_actionable"]}
              type="button"
              phx-click="conversation:cancel"
              phx-value-command_id={activity["command_id"]}
              disabled={!@can_act}
            >
              Request cancellation
            </button>
          </div>
          <p class="aw-conversation-control-status">
            {activity["delivery_text"]} · {activity["execution_text"]}
          </p>
          <p role="status">{activity["cancellation_text"]}</p>
          <p :if={activity["progress"]} class="aw-conversation-control-status">
            {progress_label(activity["progress"])}
          </p>
          <details
            :if={activity["preview"] != ""}
            id={"conversation-activity-preview-" <> activity["command_id"]}
            phx-mounted={Phoenix.LiveView.JS.ignore_attributes("open")}
          >
            <summary>
              Response preview{if activity["preview_truncated"], do: " (partial)", else: ""}
            </summary>
            <p class="aw-conversation-control-text">{activity["preview"]}</p>
          </details>
        </article>
        <article
          :for={prompt <- @controls["interactions"]}
          id={"conversation-interaction-" <> prompt["request_id"]}
          class="aw-conversation-interaction"
        >
          <div class="aw-conversation-control-row">
            <h3>{if prompt["protected"], do: "Permission review", else: "Your answer is needed"}</h3>
            <span class="aw-conversation-control-status">{prompt["status"]}</span>
          </div>
          <p class="aw-conversation-control-text">{prompt["text"]}</p>
          <p class="aw-conversation-control-id">
            Message {prompt["command_id"]} · revision {prompt["revision"]}
          </p>
          <div :if={!prompt["protected"]} class="aw-conversation-choice-buttons">
            <button
              :for={{choice, index} <- Enum.with_index(prompt["choices"], 1)}
              type="button"
              phx-click="conversation:choose"
              phx-value-command_id={prompt["command_id"]}
              phx-value-request_id={prompt["request_id"]}
              phx-value-operation_id={prompt["operation_id"]}
              phx-value-revision={prompt["revision"]}
              phx-value-choice_id={choice["id"]}
              disabled={!@can_act || !prompt["actionable"]}
            >
              <span aria-hidden="true">{index}. </span>{choice["label"]}
            </button>
          </div>
          <form
            :if={prompt["protected"] && @can_approve && prompt["actionable"]}
            id={"conversation-review-#{prompt["request_id"]}-#{prompt["revision"]}"}
            phx-submit="conversation:approve"
            phx-change="conversation:review-change"
            class="aw-conversation-approval-form"
          >
            <input type="hidden" name="command_id" value={prompt["command_id"]} />
            <input type="hidden" name="request_id" value={prompt["request_id"]} />
            <input type="hidden" name="operation_id" value={prompt["operation_id"]} />
            <input type="hidden" name="revision" value={prompt["revision"]} />
            <label for={"conversation-decision-#{prompt["request_id"]}-#{prompt["revision"]}"}>
              Decision for this action
            </label>
            <select
              id={"conversation-decision-#{prompt["request_id"]}-#{prompt["revision"]}"}
              name="decision"
              required
              disabled={!@can_edit}
            >
              <option value="" selected={ConversationReviewCore.show(@reviews, prompt).decision == ""}>
                Choose a decision…
              </option>
              <option
                value="approved"
                selected={ConversationReviewCore.show(@reviews, prompt).decision == "approved"}
              >
                Approve this action
              </option>
              <option
                value="denied"
                selected={ConversationReviewCore.show(@reviews, prompt).decision == "denied"}
              >
                Deny this action
              </option>
              <option
                value="rework"
                selected={ConversationReviewCore.show(@reviews, prompt).decision == "rework"}
              >
                Request rework
              </option>
            </select>
            <label for={"conversation-note-#{prompt["request_id"]}-#{prompt["revision"]}"}>
              Review note (optional)
            </label>
            <textarea
              id={"conversation-note-#{prompt["request_id"]}-#{prompt["revision"]}"}
              name="note"
              rows="2"
              maxlength="1024"
              disabled={!@can_edit}
            >{ConversationReviewCore.show(@reviews, prompt).note}</textarea>
            <button type="submit" disabled={!@can_act}>Submit decision</button>
            <p class="aw-conversation-control-status">
              Your current sign-in and permission for this action are checked when you submit.
            </p>
          </form>
          <p :if={prompt["protected"] && !@can_approve && prompt["actionable"]}>
            Review this action in an authenticated browser with permission to approve it.
          </p>
        </article>
      </div>
    </section>
    """
  end

  defp progress_label(%{"type" => type, "node_id" => nil}), do: String.replace(type, "_", " ")

  defp progress_label(%{"type" => type, "node_id" => node}),
    do: String.replace(type, "_", " ") <> ": " <> node

  defp scope_key(assigns) do
    if assigns[:current_agent_id] && assigns[:agent_id] && assigns[:conversation_engagement_id],
      do:
        Enum.join(
          [assigns.current_agent_id, assigns.agent_id, assigns.conversation_engagement_id],
          ":"
        ),
      else: ""
  end

  defp role_label("user"), do: "You"
  defp role_label("assistant"), do: "Assistant"
  defp role_label(_), do: "Conversation"

  defp delivery_label(%{pending_id: id}) when not is_nil(id),
    do: "Delivery is unconfirmed. Your request is saved."

  defp delivery_label(%{receipt: %{"status" => "admitted"}}),
    do: "Message received. Waiting for a response…"

  defp delivery_label(%{receipt: %{"status" => "dispatch_started"}}),
    do: "Working on your message…"

  defp delivery_label(%{receipt: %{"status" => "completed"}}), do: "Response completed."

  defp delivery_label(%{receipt: %{"status" => "uncertain"}}),
    do: "The delivery outcome is uncertain."

  defp delivery_label(_), do: "Checking delivery…"
end
