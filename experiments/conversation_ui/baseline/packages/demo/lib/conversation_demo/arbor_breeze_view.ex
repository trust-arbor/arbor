defmodule ConversationDemo.ArborBreezeView do
  use Breeze.View
  import Breeze.Blocks, only: [input: 1]
  alias ConversationDemo.ArborInteraction

  def mount(opts, term), do: {:ok, assign(term, ui: ArborInteraction.new(opts))}
  def handle_event("chat:draft", %{value: text}, term), do: act(term, "draft", %{"text" => text})
  def handle_event("chat:" <> action, params, term), do: act(term, action, params)
  def handle_event(:input, %{"key" => "Escape"}, term), do: {:stop, term}
  def handle_event(:input, %{"key" => "Enter"}, term), do: act(term, "send", %{})
  def handle_event(:input, %{"key" => "F3"}, term), do: act(term, "refresh", %{})
  def handle_event(:input, %{"key" => "F4"}, term), do: act(term, "disconnect", %{})
  def handle_event(:input, %{"key" => "F5"}, term), do: act(term, "reconnect", %{})
  def handle_event(:input, %{"key" => "F6"}, term), do: act(term, "retry", %{})
  def handle_event(:input, %{"key" => "F7"}, term), do: act(term, "question:cycle", %{})

  def handle_event(:input, %{"key" => "F8"}, term),
    do: act(term, "question:confirm", ConversationDemo.Question.params(term.assigns.ui.question))

  def handle_event(:input, %{"key" => "F9"}, term), do: act(term, "history:older", %{})
  def handle_event(:input, %{"key" => "F10"}, term), do: act(term, "history:newer", %{})
  def handle_event(:input, %{"key" => "F11"}, term), do: act(term, "history:toggle", %{})
  def handle_event(_, _, term), do: {:noreply, term}

  defp act(term, action, params),
    do: {:noreply, assign(term, ui: ArborInteraction.act(term.assigns.ui, action, params))}

  def render(assigns) do
    assigns =
      Map.put(
        assigns,
        :history,
        ConversationDemo.HistoryWindow.show(assigns.ui.window, assigns.ui.snapshot)
      )

    ~H"""
    <box class="w-screen h-screen">
      <box class="w-full height-1 overflow-hidden text-green font-bold">
        ARBOR / BREEZE · shared conversation
      </box>
      <box class="w-full height-1 overflow-hidden">
        {if @ui.snapshot.connected,
          do: "Connected · explicit refresh",
          else: "Disconnected · F5 reconnect"}
      </box>
      <box id="transcript" class={"height-#{max(@breeze.terminal.height - 17, 2)} scroll-y"}>
        <box :for={block <- @history.blocks} class="min-height-2">
          <box class="text-green">{block["role"] || block["type"]} {block["status"] || ""}</box>
          <box>{block["text"]}</box>
        </box>
      </box>
      <box id="history-window" class="w-full height-1 overflow-hidden">
        Messages {@history.first}–{@history.last} of {@history.total} · F9 older · F10 newer · F11 full/recent
      </box>
      <box :if={@ui.question} id="structured-question" class="w-full height-5 overflow-hidden">
        <box class="w-full height-1">{@ui.question.prompt} [{@ui.question.status}]</box>
        <box :for={option <- @ui.question.options} class="w-full height-1">
          {if @ui.question.selected == option["id"], do: "● ", else: "○ "}{option["label"]}
        </box>
        <box class="w-full height-1">F7 select next · F8 confirm choice</box>
      </box>
      <box class="w-full height-1 overflow-hidden text-red">{@ui.snapshot.error || ""}</box>
      <box :if={@ui.snapshot.pending_id} class="w-full height-1 overflow-hidden">
        Unconfirmed admission · F6 checks the saved ID
      </box>
      <.input
        :if={@ui.snapshot.send_allowed}
        id="draft"
        class="w-full"
        input-value={@ui.draft}
        input-placeholder="Message · Enter to send"
        br-change="chat:draft"
        br-submit="chat:send"
        default-focus
      >
        {@ui.draft}
      </.input>
      <box :if={!@ui.snapshot.send_allowed} id="paused-draft" class="w-full height-1 overflow-hidden">
        Draft: {@ui.draft}
      </box>
      <box class="w-full height-1 overflow-hidden">F3 refresh · F4 disconnect · F5 reconnect</box>
      <box class="w-full height-1 overflow-hidden">F6 check / retry saved request · Esc exit</box>
      <box class="w-full height-1 overflow-hidden">
        Transcript {@ui.snapshot.position.history} · Journal {@ui.snapshot.position.commands}
      </box>
      <box class="w-full height-1 overflow-hidden">Text preview only · audio is not playing</box>
    </box>
    """
  end

  def run(opts \\ []), do: Breeze.Server.run(view: __MODULE__, start_opts: opts)
end
