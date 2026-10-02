defmodule ConversationDemo.HistoryWindow do
  @moduledoc "Pure, reversible presentation window; the connection owner retains full history."
  @size 20

  def new, do: %{offset: 0, size: @size, full: false}

  def move(window, "older", snapshot),
    do: %{window | offset: min(window.offset + window.size, max(count(snapshot) - 1, 0))}

  def move(window, "newer", _snapshot),
    do: %{window | offset: max(window.offset - window.size, 0)}

  def move(window, "toggle", _snapshot), do: %{window | full: !window.full}
  def move(window, _, _snapshot), do: window

  def show(window, snapshot) do
    messages = snapshot.projection["messages"]
    total = length(messages)
    finish = if window.full, do: total, else: max(total - window.offset, 0)
    start = if window.full, do: 0, else: max(finish - window.size, 0)
    ids = messages |> Enum.slice(start, finish - start) |> MapSet.new(& &1["id"])

    message_blocks =
      snapshot.projection["blocks"]
      |> Enum.filter(&(&1["type"] == "message" && MapSet.member?(ids, &1["id"])))

    deliveries =
      snapshot.projection["blocks"]
      |> Enum.filter(&(&1["type"] == "delivery"))
      |> then(&if(window.full, do: &1, else: Enum.take(&1, -window.size)))

    %{
      blocks: message_blocks ++ deliveries,
      total: total,
      first: if(total > 0, do: start + 1, else: 0),
      last: finish,
      older: !window.full && start > 0,
      newer: !window.full && window.offset > 0,
      full: window.full
    }
  end

  defp count(snapshot), do: length(snapshot.projection["messages"])
end
