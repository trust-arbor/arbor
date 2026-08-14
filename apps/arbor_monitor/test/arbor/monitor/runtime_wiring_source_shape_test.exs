defmodule Arbor.Monitor.RuntimeWiringSourceShapeTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  test "non-test runtime wires Agent and Comms facades into arbor_monitor" do
    root = find_root(__DIR__)
    runtime = File.read!(Path.join(root, "config/runtime.exs"))
    test_config = File.read!(Path.join(root, "config/test.exs"))

    chunk =
      runtime
      |> String.split("# Monitor operational bridges")
      |> Enum.at(1)
      |> String.split("# Ollama base URL")
      |> hd()

    assert chunk =~ "if config_env() != :test do"
    assert chunk =~ "channel_bridge_module: Arbor.Comms"
    assert chunk =~ "agent_directory_module: Arbor.Agent"

    refute test_config =~ "channel_bridge_module"
    refute test_config =~ "agent_directory_module"
  end

  defp find_root(dir) do
    cond do
      File.exists?(Path.join([dir, "apps", "arbor_contracts", "mix.exs"])) ->
        dir

      Path.dirname(dir) == dir ->
        flunk("umbrella root not found from #{__DIR__}")

      true ->
        find_root(Path.dirname(dir))
    end
  end
end
