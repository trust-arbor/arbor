defmodule Arbor.Orchestrator.Dot.DurationTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Dot.Duration

  test "30s yields 30_000" do
    assert Duration.parse("30s") == 30_000
  end

  test "5m yields 300_000" do
    assert Duration.parse("5m") == 300_000
  end

  test "1h yields 3_600_000" do
    assert Duration.parse("1h") == 3_600_000
  end

  test "2d yields 172_800_000" do
    assert Duration.parse("2d") == 172_800_000
  end

  test "500ms yields 500" do
    assert Duration.parse("500ms") == 500
  end

  test "bare integer string '15000' yields 15_000" do
    assert Duration.parse("15000") == 15_000
  end

  test "nil yields nil" do
    assert Duration.parse(nil) == nil
  end
end
