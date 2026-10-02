defmodule ConversationDemo.ArborChatLive do
  use Phoenix.LiveView
  alias ConversationDemo.ArborInteraction

  def mount(_params, _session, socket),
    do: {:ok, assign(socket, :ui, ArborInteraction.new())}

  def handle_event("chat:send", %{"text" => text}, socket) do
    ui =
      socket.assigns.ui
      |> ArborInteraction.act("draft", %{"text" => text})
      |> ArborInteraction.act("send", %{"text" => text})

    socket = assign(socket, :ui, ui)

    {:noreply, clear_composer(socket)}
  end

  def handle_event("chat:" <> action, params, socket) do
    ui = ArborInteraction.act(socket.assigns.ui, action, params)
    {:noreply, socket |> assign(:ui, ui) |> clear_composer()}
  end

  defp clear_composer(socket) do
    cond do
      socket.assigns.ui.snapshot.private_cleared ->
        push_event(socket, "composer:clear", %{})

      socket.assigns.ui.composer_ack != nil ->
        push_event(socket, "composer:sent", %{text: socket.assigns.ui.composer_ack})

      true ->
        socket
    end
  end

  def render(assigns) do
    assigns =
      assign(
        assigns,
        :history,
        ConversationDemo.HistoryWindow.show(assigns.ui.window, assigns.ui.snapshot)
      )

    ~H"""
    <div class="study-shell">
      <header class="masthead">
        <a class="wordmark" href="/arbor">Conversation<span> / </span>study</a>
        <nav aria-label="Interface variants">
          <span aria-current="page">Arbor · LiveView</span><a href="/">Fixture study ↗</a>
        </nav>
      </header>
      <section class="intro">
        <p class="eyebrow">ONE CONVERSATION · MANY SURFACES</p>
        <h1>The conversation<br />comes with you.</h1>
        <p class="lede">
          A shared Arbor record. Independent web and terminal views. Refresh to catch up.
        </p>
      </section>
      <main class="workspace">
        <section class="conversation" aria-label="Visual conversation">
          <div class="section-heading">
            <h2>Conversation</h2>
            <span
              id="connection"
              class={if @ui.snapshot.connected, do: "status", else: "status paused"}
            >
              {if @ui.snapshot.connected, do: "● Connected · refresh to sync", else: "○ Disconnected"}
            </span>
          </div>
          <div id="transcript" class="transcript" role="log" aria-label="Conversation history">
            <article
              :for={block <- @history.blocks}
              id={"arbor-block-" <> block["type"] <> "-" <> block["id"]}
              class={"block " <> block["type"]}
              data-kind={block["type"]}
            >
              <div class="block-label">
                <span>{block_label(block)}</span><span>{block["status"] || ""}</span>
              </div>
              <p>{block["text"]}</p>
            </article>
          </div>
          <div id="history-window">
            <span>Messages {@history.first}–{@history.last} of {@history.total}</span>
            <button id="history-older" phx-click="chat:history:older" disabled={!@history.older}>Older</button>
            <button id="history-newer" phx-click="chat:history:newer" disabled={!@history.newer}>Newer</button>
            <button id="history-toggle" phx-click="chat:history:toggle">{if @history.full, do: "Recent window", else: "Full history"}</button>
          </div>
          <section :if={@ui.question} id="structured-question" aria-label="Choose one option">
            <h3>{@ui.question.prompt}</h3>
            <button
              :for={option <- @ui.question.options}
              id={"question-option-" <> option["id"]}
              phx-click="chat:question:choose"
              phx-value-question_id={@ui.question.id}
              phx-value-revision={@ui.question.revision}
              phx-value-source_message_id={@ui.question.source_message_id}
              phx-value-option_id={option["id"]}
              aria-pressed={to_string(@ui.question.selected == option["id"])}
              disabled={!@ui.snapshot.send_allowed || @ui.question.status != "pending"}
            >{option["label"]}</button>
            <button
              id="question-confirm"
              phx-click="chat:question:confirm"
              phx-value-question_id={@ui.question.id}
              phx-value-revision={@ui.question.revision}
              phx-value-source_message_id={@ui.question.source_message_id}
              disabled={!@ui.snapshot.send_allowed || @ui.question.status != "pending" || is_nil(@ui.question.selected)}
            >Confirm choice</button>
            <p id="question-status" role="status">{@ui.question.status}</p>
          </section>
          <p :if={@ui.snapshot.error} id="host-error" class="error" role="alert">
            {@ui.snapshot.error}
          </p>
          <p :if={@ui.snapshot.pending_id} id="pending-request" class="quiet">
            Admission not confirmed. Saved request {@ui.snapshot.pending_id} will retain its ID when checked or retried.
          </p>
          <form
            id="composer"
            phx-submit="chat:send"
            phx-change="chat:draft"
            phx-hook="Composer"
            class="composer"
          >
            <label for="message">Message</label>
            <div class="compose-row">
              <input
                id="message"
                name="text"
                value={@ui.draft}
                placeholder="Write a message"
                autocomplete="off"
                disabled={!@ui.snapshot.send_allowed}
              />
              <button type="submit" disabled={!@ui.snapshot.send_allowed}>
                Send <span>↗</span>
              </button>
            </div>
            <p>
              Your draft belongs to this interface. The conversation belongs to the shared record.
            </p>
          </form>
        </section>
        <aside class="rail" aria-label="Speech and connection controls">
          <div class="rail-heading">
            <span class="eyebrow">ANOTHER MODALITY</span>
            <h2>What you’d hear</h2>
            <p>Speech descriptions appear here when the projection supports them.</p>
          </div>
          <ol id="speech-preview" class="speech-list">
            <li :for={speech <- @ui.snapshot.projection["speech"]}>
              <p>{speech["text"]}</p>
            </li>
          </ol>
          <p class="quiet">Text preview · audio is not playing</p>
          <div class="controls">
            <p class="eyebrow">SHARED RECORD</p>
            <button
              id="refresh"
              phx-click="chat:refresh"
              class="primary"
              disabled={!@ui.snapshot.connected}
            >
              Refresh <span>↻</span>
            </button>
            <div class="control-pair">
              <button id="disconnect" phx-click="chat:disconnect" disabled={!@ui.snapshot.connected}>
                Disconnect
              </button>
              <button id="reconnect" phx-click="chat:reconnect">Reconnect & replay</button>
            </div>
            <button
              :if={@ui.snapshot.pending_id}
              id="retry"
              phx-click="chat:retry"
              disabled={!@ui.snapshot.retry_allowed}
            >
              Check / retry saved request
            </button>
            <p class="control-help">
              Delivery continues after you disconnect. An unknown delivery outcome remains unknown; refresh reads its saved state.
            </p>
            <p
              :if={
                @ui.snapshot.sync_status.history.has_more or
                  @ui.snapshot.sync_status.commands.has_more
              }
              id="more-history"
              class="control-help"
            >
              More records are available. Refresh to continue this page sequence.
            </p>
          </div>
          <footer class="record-meta">
            <span>
              Transcript <strong id="history-position">{@ui.snapshot.position.history}</strong>
            </span>
            <span>
              Journal <strong id="command-position">{@ui.snapshot.position.commands}</strong>
            </span>
          </footer>
        </aside>
      </main>
      <footer class="study-footer">
        <span>ARBOR ADAPTER / 02</span><span>Explicit refresh · native presentation · no audio playback</span>
      </footer>
    </div>
    """
  end

  defp block_label(%{"type" => "message", "role" => "user"}), do: "You"
  defp block_label(%{"type" => "message"}), do: "Assistant"
  defp block_label(_), do: "Delivery status"
end
