defmodule ConversationDemo.ChatComponents do
  use Phoenix.Component
  attr(:block, :map, required: true)

  def semantic_block(assigns) do
    ~H"""
    <article id={"block-" <> @block["id"]} class={"block " <> @block["type"]} data-kind={@block["type"]}>
      <div class="block-label"><span>{label(@block)}</span><span :if={@block["type"] != "message"}>{@block["status"]}</span></div>
      <p>{@block["text"]}</p>
      <div :if={@block["type"] == "approval" and @block["status"] == "pending"} class="approval-actions">
        <button id={"approve-" <> @block["id"]} phx-click="chat:approve" phx-value-approval_id={@block["id"]} phx-value-decision="approved">Allow mock action</button>
        <button id={"deny-" <> @block["id"]} phx-click="chat:approve" phx-value-approval_id={@block["id"]} phx-value-decision="denied">Deny</button>
      </div>
    </article>
    """
  end

  defp label(%{"type" => "message", "role" => "user"}), do: "You"
  defp label(%{"type" => "message"}), do: "Assistant"
  defp label(%{"type" => "tool"}), do: "Tool activity"
  defp label(%{"type" => "approval"}), do: "Your decision"
  defp label(%{"type" => "command"}), do: "Request status"
  defp label(_), do: "Update"

  attr(:draft, :string, required: true)
  attr(:connected, :boolean, required: true)

  def composer(assigns) do
    ~H"""
    <form id="composer" phx-submit="chat:send" phx-change="chat:draft" phx-hook="Composer" class="composer">
      <label for="message">Message</label>
      <div class="compose-row"><input id="message" name="text" value={@draft} placeholder="Ask something. Try Unicode: café, 東京, 🌿" autocomplete="off" disabled={!@connected} /><button type="submit" disabled={!@connected}>Send <span>↗</span></button></div>
      <p>Your draft belongs to this interface. The conversation belongs to the shared record.</p>
    </form>
    """
  end
end
