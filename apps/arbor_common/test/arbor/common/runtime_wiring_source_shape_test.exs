defmodule Arbor.Common.RuntimeWiringSourceShapeTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  test "non-test runtime wires Actions and Security facades into arbor_common" do
    root = find_root(__DIR__)
    runtime = File.read!(Path.join(root, "config/runtime.exs"))
    test_config = File.read!(Path.join(root, "config/test.exs"))

    chunk =
      runtime
      |> String.split("# Skill hybrid-search seams")
      |> Enum.at(1)
      |> String.split("# Ollama base URL")
      |> hd()

    assert chunk =~ "if config_env() != :test do"
    assert chunk =~ "action_capability_uri_module: Arbor.Actions"
    assert chunk =~ "skill_import_security_module: Arbor.Security"

    refute test_config =~ "action_capability_uri_module"
    refute test_config =~ "skill_import_security_module"
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
