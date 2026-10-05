defmodule ConversationKit.BoundaryTest do
  use ExUnit.Case, async: true

  test "runtime source depends on neither Arbor, DASP nor renderer/process/IO facilities" do
    files = Path.wildcard(Path.expand("../lib/**/*.ex", __DIR__))
    assert files != []

    forbidden =
      ~r/\b(Arbor|DASP|Phoenix|Breeze|TermUI|Hologram|Jido|GenServer|Application|File|IO|System|DateTime|Logger|Task|Process)\.|:ets\.|:rand\.|String\.to_atom|make_ref\(/

    Enum.each(files, fn path ->
      refute Regex.match?(forbidden, File.read!(path)),
             "Forbidden dependency or impurity in #{path}"
    end)

    assert ConversationKit.MixProject.project()[:deps] == []
    assert ConversationKit.MixProject.application() == []
  end
end
