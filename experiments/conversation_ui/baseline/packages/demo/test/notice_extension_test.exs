defmodule ConversationDemo.NoticeExtensionTest do
  use ExUnit.Case, async: false
  import Phoenix.LiveViewTest
  alias ConversationDemo.{MockHost, BreezeView, TermUIView, Interaction, ChatComponents}
  @moduletag :fast
  @text "This conversation is available on another device."

  test "new semantic notice reaches all unchanged native renderers through text fallback" do
    fixture = File.read!("../fixtures/v1/notice.json") |> Jason.decode!()
    {:ok, host} = MockHost.start_link(owner: self(), fixture: fixture)
    ui = Interaction.new(host: host)
    notice = Enum.find(ui.snapshot.projection["blocks"], &(&1["type"] == "notice"))
    assert render_component(&ChatComponents.semantic_block/1, block: notice) =~ @text
    session = Breeze.Test.start!(BreezeView, size: {90, 60}, start_opts: [host: host])

    try do
      assert Breeze.Test.render_text!(session) =~ @text
    after
      Breeze.Test.stop(session)
    end

    manager =
      start_supervised!(
        {TermUI.Renderer.BufferManager, name: ConversationDemo.NoticeBuffer, rows: 60, cols: 90}
      )

    TermUI.Runtime.NodeRenderer.render_to_buffer(
      TermUIView.view(%{ui | width: 90, height: 60}),
      manager
    )

    buffer = TermUI.Renderer.BufferManager.get_current_buffer(manager)

    text =
      Enum.map_join(1..60, "\n", fn row ->
        Enum.map_join(1..90, "", fn col ->
          TermUI.Renderer.Buffer.get_cell(buffer, row, col).char
        end)
      end)

    assert text =~ @text
    refute Enum.any?(ui.snapshot.projection["speech"], &(&1["text"] == @text))
  end
end
