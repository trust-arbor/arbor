defmodule ConversationDemo.InterfacesTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias ConversationDemo.{MockHost, Interaction, BreezeView, TermUIView}
  @endpoint ConversationDemo.Endpoint
  @moduletag :fast

  test "LiveView sends Unicode, shows host pending state, and replays while retaining local draft separation" do
    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "The conversation"
    assert html =~ "uncertain"
    assert html =~ "Review the pending approval on screen"
    html = view |> form("#composer", text: "café 東京 🌿") |> render_submit()
    assert_push_event(view, "composer:sent", %{})
    assert html =~ "café 東京 🌿"
    assert html =~ "Command demo-1: pending"
    view |> form("#composer", text: "Keep my draft: 東京") |> render_change()
    assert view |> element("#advance") |> render_click() =~ "Temporary progress"
    view |> element("#disconnect") |> render_click()
    assert view |> element("#advance") |> render_click() =~ "Disconnected"
    html = view |> element("#replay") |> render_click()
    assert html =~ "Searching the local fixture"
    assert html =~ "Keep my draft: 東京"
    refute html =~ "Temporary progress"
  end

  test "LiveView protected approval changes only after host response and final speech requires completion" do
    {:ok, view, _html} = live(build_conn(), "/")
    html = view |> element("#approve-approval-access") |> render_click(%{"value" => ""})
    assert html =~ "approved"
    refute html =~ "The mock search is complete."
    for _ <- 1..3, do: view |> element("#advance") |> render_click()
    assert view |> element("#speech-preview") |> render() =~ "The mock search is complete."
  end

  test "Breeze real runtime test API handles Unicode input, resize, replay and protected approval" do
    session = Breeze.Test.start!(BreezeView, size: {90, 36})
    on_exit(fn -> Breeze.Test.stop(session) end)
    assert Breeze.Test.render_text!(session) =~ "CONVERSATION / BREEZE"
    Breeze.Test.focus(session, "draft")
    for char <- String.graphemes("café 東京 🌿"), do: Breeze.Test.input(session, char)
    Breeze.Test.input(session, "Enter")
    Breeze.Test.event(session, "chat:advance", %{})
    assert Breeze.Test.render_text!(session) =~ "checking the conversation"
    Breeze.Test.event(session, "chat:disconnect", %{})
    Breeze.Test.event(session, "chat:advance", %{})
    Breeze.Test.event(session, "chat:replay", %{})
    session = Breeze.Test.resize(session, {24, 14})
    rendered = Breeze.Test.render_text!(session)
    assert String.valid?(rendered)
    assert length(String.split(rendered, "\n")) >= 1

    assert Enum.all?(
             String.split(rendered, "\n"),
             &(TermUI.Renderer.DisplayWidth.width(&1) <= 24)
           )

    session = Breeze.Test.resize(session, {90, 45})
    assert Breeze.Test.render_text!(session) =~ "café 東京 🌿"

    Breeze.Test.event(session, "chat:approve", %{
      "approval_id" => "approval-access",
      "decision" => "denied"
    })

    assert Breeze.Test.render_text!(session) =~ "approval_denied" or
             Breeze.Test.render_text!(session) =~ "denied"
  end

  test "TermUI runtime dispatches input and resize with actual render-tree-to-buffer output" do
    runtime = start_supervised!({TermUI.Runtime, root: TermUIView, skip_terminal: true})

    for char <- String.graphemes("café 東京 🌿"),
        do: TermUI.Runtime.send_event(runtime, %TermUI.Event.Key{key: :char, char: char})

    TermUI.Runtime.send_event(runtime, %TermUI.Event.Key{key: :enter})
    TermUI.Runtime.send_event(runtime, %TermUI.Event.Resize{width: 24, height: 14})
    TermUI.Runtime.sync(runtime)
    send(runtime, :dispatch_effects)
    TermUI.Runtime.sync(runtime)
    ui = TermUI.Runtime.get_state(runtime).root_state
    assert ui.draft == ""
    assert ui.width == 24
    assert Enum.any?(ui.snapshot.projection["messages"], &(&1["text"] == "café 東京 🌿"))

    buffer =
      start_supervised!(
        {TermUI.Renderer.BufferManager, name: ConversationDemo.TestBuffer, rows: 14, cols: 24}
      )

    TermUI.Runtime.NodeRenderer.render_to_buffer(TermUIView.view(ui), buffer)
    current = TermUI.Renderer.BufferManager.get_current_buffer(buffer)

    text =
      for row <- 1..14,
          into: "",
          do:
            Enum.map_join(1..24, "", fn col ->
              TermUI.Renderer.Buffer.get_cell(current, row, col).char
            end)

    assert text =~ "TERMUI / r"
    assert String.valid?(text)

    assert TermUIView.wrap("東京🌿 café", 5)
           |> Enum.all?(&(TermUI.Renderer.DisplayWidth.width(&1) <= 5))
  end

  test "all adapters consume one projection and replay does not change a local draft" do
    {:ok, host} = MockHost.start_link(owner: self())
    ui = Interaction.new(host: host) |> Interaction.act("draft", %{"text" => "unfinished"})
    next = Interaction.act(ui, "replay", %{})
    assert next.snapshot.projection == ui.snapshot.projection
    assert next.draft == "unfinished"
    assert next.snapshot.progress == %{}
    assert TermUIView.rows(next) |> Enum.any?(&String.contains?(&1, "uncertain"))
  end
end
