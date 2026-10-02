defmodule ConversationKit.Snapshot do
  @moduledoc """
  Pure semantic projection for hosts with independent transcript and delivery logs.

  A delivery result is a delivery block, never a fabricated assistant message.
  This projection has no replay-to-speech classification, so `speech` is empty.
  The event reducer in `ConversationKit` remains a separate, unchanged API.
  """

  @message_keys ~w(id role text timestamp ordinal)
  @delivery_keys ~w(id status input_text result_text reason admitted_cursor updated_cursor)

  @doc "Project already-normalized semantic records, discarding non-display fields."
  def project(messages, deliveries) when is_list(messages) and is_list(deliveries) do
    messages = Enum.map(messages, &Map.take(&1, @message_keys))

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

    %{
      "messages" => messages,
      "deliveries" => deliveries,
      "blocks" => message_blocks ++ delivery_blocks,
      "speech" => []
    }
  end

  defp delivery_text(%{"status" => "admitted"}), do: "Delivery admitted"

  defp delivery_text(%{"status" => "dispatch_started"}),
    do: "Delivery started; outcome unknown"

  defp delivery_text(%{"status" => "completed", "result_text" => text}),
    do: "Delivery completed: " <> text

  defp delivery_text(%{"status" => "uncertain"}), do: "Delivery outcome uncertain"
end
