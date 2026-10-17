defmodule Arbor.Voice.Session.ToolWaveCoreTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Voice.Session.ToolWaveCore

  test "a closed wave is ready only after none of its calls is outstanding" do
    waves =
      ToolWaveCore.new()
      |> ToolWaveCore.admit("call_a")
      |> ToolWaveCore.admit("call_b")
      |> ToolWaveCore.close()

    assert {0, waves} = ToolWaveCore.take_ready(waves, ["call_a", "call_b"])
    assert {0, waves} = ToolWaveCore.take_ready(waves, ["call_b"])
    assert {1, waves} = ToolWaveCore.take_ready(waves, [])
    assert {0, _waves} = ToolWaveCore.take_ready(waves, [])
  end

  test "outputs that finish before turn_done wait for the close" do
    waves = ToolWaveCore.admit(ToolWaveCore.new(), "call_early")

    assert {0, waves} = ToolWaveCore.take_ready(waves, [])
    assert {1, _waves} = waves |> ToolWaveCore.close() |> ToolWaveCore.take_ready([])
  end

  test "a response without tool calls closes no wave" do
    assert {0, _waves} = ToolWaveCore.new() |> ToolWaveCore.close() |> ToolWaveCore.take_ready([])
  end

  test "each closed wave gets its own continuation and unrelated pending ids do not block it" do
    waves =
      ToolWaveCore.new()
      |> ToolWaveCore.admit("wave1")
      |> ToolWaveCore.close()
      |> ToolWaveCore.admit("wave2_a")
      |> ToolWaveCore.admit("wave2_b")

    assert {1, waves} = ToolWaveCore.take_ready(waves, ["wave2_a"])
    waves = ToolWaveCore.close(waves)
    assert {0, waves} = ToolWaveCore.take_ready(waves, ["wave2_a"])
    assert {1, _waves} = ToolWaveCore.take_ready(waves, [])
  end
end
