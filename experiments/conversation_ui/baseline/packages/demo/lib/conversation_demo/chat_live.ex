defmodule ConversationDemo.ChatLive do
  use Phoenix.LiveView
  alias ConversationDemo.Interaction
  import ConversationDemo.ChatComponents

  def mount(_params, _session, socket), do: {:ok, assign(socket, :ui, Interaction.new())}

  def handle_event("chat:send", %{"text" => text}, socket) do
    ui =
      socket.assigns.ui
      |> Interaction.act("draft", %{"text" => text})
      |> Interaction.act("send", %{})

    socket = assign(socket, :ui, ui)
    {:noreply, if(ui.error == nil, do: push_event(socket, "composer:sent", %{}), else: socket)}
  end

  def handle_event("chat:" <> action, params, socket) do
    {:noreply, assign(socket, :ui, Interaction.act(socket.assigns.ui, action, params))}
  end

  def render(assigns) do
    ~H"""
    <div class="study-shell">
      <header class="masthead">
        <a class="wordmark" href="/">Conversation<span> / </span>study</a>
        <nav aria-label="Interface variants"><span aria-current="page">LiveView</span><a href="http://127.0.0.1:4782">Hologram ↗</a></nav>
      </header>
      <section class="intro">
        <p class="eyebrow">ONE CONVERSATION · MANY SURFACES</p>
        <h1>The conversation<br />comes with you.</h1>
        <p class="lede">A shared record. A native interface. Try a message, follow its work, then reconnect.</p>
      </section>
      <main class="workspace">
        <section class="conversation" aria-label="Visual conversation">
          <div class="section-heading"><h2>Conversation</h2><span id="connection" class={if @ui.connected, do: "status", else: "status paused"}>{if @ui.connected, do: "● Following", else: "○ Disconnected"}</span></div>
          <div id="transcript" class="transcript" role="log" aria-label="Conversation history">
            <.semantic_block :for={block <- @ui.snapshot.projection["blocks"]} block={block} />
            <div :for={{id, text} <- @ui.snapshot.progress} id={"progress-" <> id} class="progress"><span class="pulse"></span>{text}<small>Temporary progress</small></div>
          </div>
          <p :if={@ui.error} class="error" role="alert">{@ui.error}</p>
          <.composer draft={@ui.draft} connected={@ui.connected} />
        </section>
        <aside class="rail" aria-label="Speech and experiment controls">
          <div class="rail-heading"><span class="eyebrow">ANOTHER MODALITY</span><h2>What you’d hear</h2><p>Final responses become speech. Protected decisions return to the screen.</p></div>
          <ol id="speech-preview" class="speech-list">
            <li :for={speech <- @ui.snapshot.projection["speech"]} class={speech["type"]}><span class="speech-label">{if speech["type"] == "screen_required", do: "SCREEN REQUIRED", else: "VOICE"}</span><p>{speech["text"]}</p></li>
          </ol>
          <p class="quiet">Text preview · audio is not playing</p>
          <div class="controls">
            <p class="eyebrow">FOLLOW THE WORK</p>
            <button id="advance" phx-click="chat:advance" class="primary">Advance one step <span>→</span></button>
            <p class="control-help">A message moves through progress, a tool, and a decision before its final response.</p>
            <div class="control-pair"><button id="disconnect" phx-click="chat:disconnect">Disconnect</button><button id="replay" phx-click="chat:replay">Reconnect & replay</button></div>
            <button id="uncertain" class="uncertain" phx-click="chat:uncertain">Simulate an uncertain outcome</button>
            <p class="control-help">These controls operate a local mock host. Approval buttons request a decision; only a returned host event changes the record.</p>
          </div>
          <footer class="record-meta"><span>Revision <strong id="revision">{@ui.snapshot.projection["revision"]}</strong></span><span>{@ui.snapshot.remaining} steps queued</span></footer>
        </aside>
      </main>
      <footer class="study-footer"><span>INTERFACE EXPERIMENT / 01</span><span>Visual + voice, with independent presentation state.</span></footer>
    </div>
    """
  end
end
