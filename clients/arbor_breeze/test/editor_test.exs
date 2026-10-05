defmodule ArborBreeze.EditorTest do
  use ExUnit.Case, async: true
  alias ArborBreeze.Editor

  test "only a matching acknowledgement clears the unchanged native draft" do
    original = Editor.new() |> Editor.draft("日本語 👋\nsecond line")
    {:send, request, pending} = Editor.submit(original, %{send_allowed: true}, "stable")
    assert request == %{id: "stable", text: original.draft}
    assert {:ignored, ^pending} = Editor.submit(pending, %{send_allowed: true}, "another")
    assert Editor.observe(pending, %{ack: %{id: "other", text: original.draft}}) == pending
    assert Editor.observe(pending, %{ack: %{id: "stable", text: "different"}}) == pending
    assert %{draft: "", submitted: nil} = Editor.observe(pending, %{ack: request})

    changed = Editor.draft(pending, "new draft")
    assert %{draft: "new draft", submitted: nil} = Editor.observe(changed, %{ack: request})
  end

  test "manual disconnect preserves draft while access loss clears every local pending value" do
    editor = Editor.new() |> Editor.draft("retained")
    assert Editor.observe(editor, %{connected: false, private_cleared: false}) == editor

    assert %{draft: "", submitted: nil} =
             Editor.observe(editor, %{connected: false, private_cleared: true})

    assert {:ignored, ^editor} = Editor.submit(editor, %{send_allowed: false}, "stable")
  end

  test "definite rejection releases the send latch without dropping editable input" do
    editor = Editor.new() |> Editor.draft("edit me")
    {:send, _request, pending} = Editor.submit(editor, %{send_allowed: true}, "stable")

    assert Editor.observe(pending, %{
             busy: false,
             pending_id: "stable",
             ack: nil,
             error: "unknown"
           }) == pending

    assert Editor.observe(pending, %{busy: false, pending_id: nil, ack: nil, error: "rejected"}) ==
             editor
  end
end
