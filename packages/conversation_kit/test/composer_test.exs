defmodule ConversationKit.ComposerTest do
  use ExUnit.Case, async: true
  alias ConversationKit.Composer

  test "matching acknowledgement releases only the pinned unchanged submission" do
    composer = Composer.new() |> Composer.draft("hello 日本語\n👋")
    {:send, request, pending} = Composer.submit(composer, true, "stable")
    assert request == %{id: "stable", text: composer.draft}
    assert pending.submitted.revision == composer.revision
    assert Composer.acknowledge(pending, %{id: "other", text: composer.draft}) == pending
    assert Composer.acknowledge(pending, %{id: "stable", text: "different"}) == pending
    cleared = Composer.acknowledge(pending, request)
    assert cleared.draft == ""
    assert cleared.submitted == nil
  end

  test "a delayed acknowledgement preserves a newer identical-text draft revision" do
    composer = Composer.new() |> Composer.draft("same text")
    {:send, request, pending} = Composer.submit(composer, true, "stable")
    newer = pending |> Composer.draft("edited away") |> Composer.draft("same text")
    assert newer.revision > pending.submitted.revision
    acknowledged = Composer.acknowledge(newer, request)
    assert acknowledged.draft == "same text"
    assert acknowledged.revision == newer.revision
    assert acknowledged.submitted == nil
  end

  test "unresolved send identity blocks a second command while input stays editable" do
    original = Composer.new() |> Composer.draft("first")
    {:send, _request, pending} = Composer.submit(original, true, "stable")
    newer = Composer.draft(pending, "second")
    assert {:ignored, ^newer} = Composer.submit(newer, true, "new-id")
    assert {:ignored, ^original} = Composer.submit(original, false, "stable")
    assert {:ignored, %{submitted: nil}} = Composer.submit(Composer.new(), true, "empty")
  end

  test "definite rejection preserves draft and cannot release a different submission" do
    composer = Composer.new() |> Composer.draft("edit me")
    {:send, _request, pending} = Composer.submit(composer, true, "stable")
    assert Composer.reject(pending, "other") == pending
    assert Composer.reject(pending, "stable") == composer
  end

  test "privacy clear invalidates old acknowledgement and preserves later new input" do
    composer = Composer.new() |> Composer.draft("private input")
    {:send, old_request, pending} = Composer.submit(composer, true, "stable")
    cleared = Composer.clear(pending)
    assert cleared.draft == ""
    assert cleared.submitted == nil
    assert cleared.revision > pending.revision
    newer = Composer.draft(cleared, "new authorized draft")
    assert Composer.acknowledge(newer, old_request) == newer
  end
end
