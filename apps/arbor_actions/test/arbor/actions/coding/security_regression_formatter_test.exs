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

  test "security regression: generated runner strips mix-run -- before artifact write" do
    assert {:ok, source} = Formatter.runner_source(@module_name)

    # Both top-level suite launch and suite_finished must strip the separator.
    assert source =~ "case System.argv() do"
    assert source =~ ~s(["--" | rest] -> rest)
    assert source =~ "security-regression runner missing artifact path argument"
    assert source =~ "security-regression runner missing reviewed test paths"

    # Must not treat raw System.argv head as the artifact without stripping.
    refute source =~ ~r/\[artifact_path \| _tests\] = System\.argv\(\)/
    refute source =~ ~r/\[artifact_path \| test_paths\] = System\.argv\(\)/
  end
end
