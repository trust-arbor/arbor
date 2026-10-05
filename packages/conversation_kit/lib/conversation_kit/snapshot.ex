defmodule ConversationKit.Snapshot do
  @moduledoc """
  Pure semantic projection for independent transcript, delivery and notice streams.

  A delivery result is a delivery block, never a fabricated assistant message.
  Notices remain separate display blocks and carry no host authority fields.
  This projection has no replay-to-speech classification, so `speech` is empty.
  The event reducer in `ConversationKit` remains a separate, unchanged API.
  """

  @message_keys ~w(id role text timestamp ordinal)
  @message_statuses ~w(complete cancelled interrupted failed streaming)
  @delivery_keys ~w(id status input_text result_text reason admitted_cursor updated_cursor)
  @notice_keys ~w(id kind text timestamp ordinal)

  @doc "Project already-normalized semantic records, discarding non-display fields."
  def project(messages, deliveries), do: project(messages, deliveries, [])

  def project(messages, deliveries, notices)
      when is_list(messages) and is_list(deliveries) and is_list(notices) do
    messages = Enum.map(messages, &project_message/1)
    notices = Enum.map(notices, &Map.take(&1, @notice_keys))

    deliveries =
      deliveries
      |> Enum.map(&Map.take(&1, @delivery_keys))
      |> Enum.sort_by(&{&1["admitted_cursor"], &1["id"]})

    message_blocks = Enum.map(messages, &Map.put(&1, "type", "message"))

    delivery_blocks =
      Enum.map(deliveries, fn delivery ->
        delivery
        |> Map.put("type", "delivery")
        |> Map.put("text", delivery_text(delivery))
      end)

    notice_blocks = Enum.map(notices, &Map.put(&1, "type", "notice"))

    %{
      "messages" => messages,
      "deliveries" => deliveries,
      "notices" => notices,
      "blocks" => message_blocks ++ delivery_blocks ++ notice_blocks,
      "speech" => []
    }
  end

  defp project_message(message) do
    projected = Map.take(message, @message_keys)

    if message["role"] == "assistant" and message["status"] in @message_statuses do
      projected = Map.put(projected, "status", message["status"])

      case message_status_text(message["status"]) do
        nil -> projected
        text -> Map.put(projected, "status_text", text)
      end
    else
      projected
    end
  end

  defp message_status_text("cancelled"), do: "Cancelled · partial response"
  defp message_status_text("interrupted"), do: "Interrupted · partial response"
  defp message_status_text("failed"), do: "Response failed"
  defp message_status_text("streaming"), do: "Response in progress"
  defp message_status_text("complete"), do: nil

  defp delivery_text(%{"status" => "admitted"}), do: "Delivery admitted"

  defp delivery_text(%{"status" => "dispatch_started"}),
    do: "Delivery started; outcome unknown"

  defp delivery_text(%{"status" => "completed", "result_text" => text}),
    do: "Delivery completed: " <> text

  defp delivery_text(%{"status" => "uncertain"}), do: "Delivery outcome uncertain"
end
