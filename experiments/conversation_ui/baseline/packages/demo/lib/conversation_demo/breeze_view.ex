defmodule ConversationDemo.BreezeView do
  use Breeze.View
  import Breeze.Blocks, only: [input: 1]
  alias ConversationDemo.Interaction

  def mount(opts, term), do: {:ok, assign(term, ui: Interaction.new(opts))}

  def handle_event("chat:draft", %{value: value}, term),
    do: {:noreply, assign(term, ui: %{term.assigns.ui | draft: value})}

  def handle_event("chat:send", _params, term), do: act(term, "send", %{})
  def handle_event("chat:" <> action, params, term), do: act(term, action, params)
  def handle_event(:input, %{"key" => "Escape"}, term), do: {:stop, term}

  def handle_event(:input, %{"key" => key}, term),
    do: {:noreply, assign(term, ui: Interaction.key(term.assigns.ui, key))}

  def handle_event(_, _, term), do: {:noreply, term}

  defp act(term, action, params),
    do: {:noreply, assign(term, ui: Interaction.act(term.assigns.ui, action, params))}

  defp narrow?(width), do: width < 40

  def render(assigns) do
    ~H"""
    <box class="w-screen h-screen">
      <box class="height-1 overflow-hidden text-green font-bold">{if narrow?(@breeze.terminal.width), do: "BREEZE / r", else: "CONVERSATION / BREEZE · revision "}{@ui.snapshot.projection["revision"]}</box>
      <box class="height-1 overflow-hidden">{if @ui.connected, do: "Following the record", else: "Disconnected · F3 replay"}</box>
      <box id="transcript" class={"height-#{max(@breeze.terminal.height - 9, 2)} scroll-y"}>
        <box :for={block <- @ui.snapshot.projection["blocks"]} class="min-height-2">
          <box class="text-green">{block["role"] || block["type"]} {block["status"] || ""}</box>
          <box>{block["text"]}</box>
        </box>
        <box :for={{_id, text} <- @ui.snapshot.progress}>… {text}</box>
        <box :for={speech <- @ui.snapshot.projection["speech"]}>VOICE [{speech["type"]}]: {speech["text"]}</box>
      </box>
      <box class="height-1 text-red">{@ui.error || ""}</box>
      <.input id="draft" input-value={@ui.draft} input-placeholder="Message · Enter to send" br-change="chat:draft" br-submit="chat:send" default-focus />
      <box class="height-1 overflow-hidden">{if narrow?(@breeze.terminal.width), do: "F2 next F3 sync F4 pause", else: "F2 advance · F3 replay · F4 disconnect"}</box>
      <box class="height-1 overflow-hidden">{if narrow?(@breeze.terminal.width), do: "F5 yes F6 no F7 ? Esc", else: "F5 allow · F6 deny · F7 uncertain · Esc exit"}</box>
      <box class="height-1 overflow-hidden">Mock host · {@ui.snapshot.remaining} queued</box>
    </box>
    """
  end

  def run, do: Breeze.Server.run(view: __MODULE__)
end
