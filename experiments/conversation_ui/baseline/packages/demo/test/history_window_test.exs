defmodule ConversationDemo.HistoryWindowTest do
  use ExUnit.Case, async: true
  alias ConversationDemo.HistoryWindow
  @moduletag :fast

  def snapshot(count) do
    messages = for n <- 1..count, do: %{"id" => "message-#{n}", "text" => "Record #{n}"}
    blocks = Enum.map(messages, &Map.put(&1, "type", "message"))
    %{projection: %{"messages" => messages, "blocks" => blocks}}
  end

  test "default twenty message window preserves full ten thousand message source" do
    source = snapshot(10_000)
    window = HistoryWindow.show(HistoryWindow.new(), source)
    assert {window.first, window.last, window.total} == {9_981, 10_000, 10_000}
    assert length(window.blocks) == 20
    assert length(source.projection["messages"]) == 10_000
  end

  test "older and newer controls expose adjacent stable IDs" do
    source = snapshot(100)
    older = HistoryWindow.move(HistoryWindow.new(), "older", source)

    assert {HistoryWindow.show(older, source).first, HistoryWindow.show(older, source).last} ==
             {61, 80}

    newer = HistoryWindow.move(older, "newer", source)
    assert HistoryWindow.show(newer, source).first == 81
  end

  test "full toggle shows every record and restores the selected window" do
    source = snapshot(100)
    older = HistoryWindow.move(HistoryWindow.new(), "older", source)
    full = HistoryWindow.move(older, "toggle", source)
    assert length(HistoryWindow.show(full, source).blocks) == 100
    assert HistoryWindow.show(full, source).full
    restored = HistoryWindow.move(full, "toggle", source)
    assert HistoryWindow.show(restored, source).first == 61
  end
end
