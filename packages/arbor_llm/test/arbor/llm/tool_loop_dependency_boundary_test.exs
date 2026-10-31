defmodule Arbor.LLM.ToolLoopDependencyBoundaryTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  test "ToolLoop uses public downward facades instead of Arbor.Orchestrator internals" do
    source =
      Path.expand("../../../lib/arbor/llm/tool_loop.ex", __DIR__)
      |> File.read!()

    refute source =~ "Arbor.Orchestrator"
    refute source =~ "Arbor.Signals.Bus"
    assert source =~ "alias Arbor.LLM.Config"
    assert source =~ "signal_module = Config.signal_module()"
    assert source =~ "apply(signal_module, :emit"
  end
end
