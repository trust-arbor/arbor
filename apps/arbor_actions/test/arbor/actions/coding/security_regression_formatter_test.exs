defmodule Arbor.Actions.Coding.SecurityRegression.FormatterTest do
  use ExUnit.Case, async: true

  alias Arbor.Actions.Coding.SecurityRegression.Formatter

  @moduletag :fast
  @moduletag :security_regression

  @module_name "ArborSecurityRegressionFormatter.M" <> String.duplicate("A", 32)

  test "security regression: mix run argv keeps leading -- before owner result path" do
    # Exact owner form after Mix.Tasks.Run: script argv retains the `--`
    # separator that precedes the owner-issued result.etf path.
    assert {:ok, "/private/tmp/val/result/result.etf", ["test/a_test.exs"]} =
             Formatter.normalize_runner_argv([
               "--",
               "/private/tmp/val/result/result.etf",
               "test/a_test.exs"
             ])

    # Already-stripped form remains valid for pure fixtures.
    assert {:ok, "/private/tmp/val/result/result.etf", ["test/a_test.exs", "test/b_test.exs"]} =
             Formatter.normalize_runner_argv([
               "/private/tmp/val/result/result.etf",
               "test/a_test.exs",
               "test/b_test.exs"
             ])

    # Treating `--` itself as the artifact path is the false source_changed footgun.
    assert {:error, :missing_artifact_path} = Formatter.normalize_runner_argv([])
    assert {:error, :missing_artifact_path} = Formatter.normalize_runner_argv(["--"])

    assert {:error, :empty_test_paths} =
             Formatter.normalize_runner_argv(["--", "/private/tmp/val/result/result.etf"])

    assert {:error, :option_shaped_artifact_path} =
             Formatter.normalize_runner_argv(["--", "-e", "test/a_test.exs"])
  end

  test "security regression: generated runner stores owner path before Mix.Task.run; suite_finished never rereads argv" do
    assert {:ok, source} = Formatter.runner_source(@module_name)

    # One-time argv parse + strip at script body, then store before Mix.
    assert source =~ "case System.argv() do"
    assert source =~ ~s(["--" | rest] -> rest)
    assert source =~ "store_artifact_path!(artifact_path)"
    assert source =~ "Mix.Task.run(\"test\""

    # Formatter-owned state holds the path; suite_finished must not touch argv.
    assert source =~ "artifact_path: artifact_path"
    assert source =~ "Map.fetch!(state, :artifact_path)"
    assert source =~ "security-regression runner missing stored artifact path"

    suite_finished =
      source
      |> String.split("def handle_cast({:suite_finished")
      |> Enum.at(1)
      |> String.split("def handle_cast(_event")
      |> hd()

    refute suite_finished =~ "System.argv()"
    refute source =~ ~r/\[artifact_path \| _tests\] = System\.argv\(\)/
    refute source =~ ~r/\[artifact_path \| test_paths\] = System\.argv\(\)/
  end
end
