defmodule Arbor.Signals.RuntimeWiringSourceShapeTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  test "non-test runtime wiring is independent of module load order" do
    root = find_root(__DIR__)
    runtime = File.read!(Path.join(root, "config/runtime.exs"))
    test_config = File.read!(Path.join(root, "config/test.exs"))

    chunk =
      runtime
      |> String.split("# Signals durable sink")
      |> Enum.at(1)
      |> String.split("# Ollama base URL")
      |> hd()

    assert chunk =~ "if config_env() != :test do"
    assert chunk =~ "durable_sink_module: Arbor.Historian"
    assert chunk =~ "security_module: Arbor.Security"
    assert chunk =~ "crypto_module: Arbor.Security"
    assert chunk =~ "identity_registry_module: Arbor.Security"
    refute chunk =~ "Code.ensure_loaded?(Arbor.Historian)"
    refute chunk =~ "Code.ensure_loaded?(Arbor.Security)"

    refute test_config =~ "durable_sink_module"
    refute test_config =~ "security_module"
    refute test_config =~ "crypto_module"
    refute test_config =~ "identity_registry_module"
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
