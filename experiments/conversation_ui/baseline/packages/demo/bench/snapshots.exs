alias ConversationDemo.{BreezeView, TermUIView}
File.mkdir_p!("evidence")

for {width, height} <- [{90, 36}, {24, 14}] do
  session = Breeze.Test.start!(BreezeView, size: {width, height})
  File.write!("evidence/breeze-#{width}x#{height}.txt", Breeze.Test.render_text!(session))
  Breeze.Test.stop(session)
  state = TermUIView.init([]) |> Map.merge(%{width: width, height: height})

  {:ok, manager} =
    TermUI.Renderer.BufferManager.start_link(
      name: ConversationDemo.SnapshotBuffer,
      rows: height,
      cols: width
    )

  TermUI.Runtime.NodeRenderer.render_to_buffer(TermUIView.view(state), manager)
  buffer = TermUI.Renderer.BufferManager.get_current_buffer(manager)

  output =
    Enum.map_join(1..height, "\n", fn row ->
      Enum.map_join(1..width, "", fn col ->
        cell = TermUI.Renderer.Buffer.get_cell(buffer, row, col)
        if cell.wide_placeholder, do: "", else: cell.char
      end)
    end)

  File.write!("evidence/termui-#{width}x#{height}.txt", output)
  GenServer.stop(manager)
end
