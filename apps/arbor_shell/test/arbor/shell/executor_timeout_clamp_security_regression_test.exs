defmodule Arbor.Shell.ExecutorTimeoutClampSecurityRegressionTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Shell.Executor

  # 2026-10-11 cross-library review F-024: a caller-supplied `:timeout` flowed
  # through agent option narrowing unbounded, so a model could hold a port
  # session open indefinitely.
  test "security regression (F-024): caller-supplied timeouts are clamped to the 10 minute ceiling" do
    assert Executor.normalize_timeout(10_000_000) == 600_000
    assert Executor.normalize_timeout(600_001) == 600_000
    assert Executor.normalize_timeout(5_000) == 5_000
    assert Executor.normalize_timeout(0) == 30_000
    assert Executor.normalize_timeout(:infinity) == 30_000
  end
end
