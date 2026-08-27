defmodule Arbor.Shell.SpawnCapableTimeoutTest do
  use ExUnit.Case, async: true

  alias Arbor.Shell
  alias Arbor.Shell.SpawnCapableTimeout

  @moduletag :fast

  test "public facade exposes standard and intensive profile ceilings" do
    assert Shell.spawn_capable_max_timeout_ms() == 600_000
    assert Shell.spawn_capable_max_timeout_ms() == SpawnCapableTimeout.max_timeout_ms()

    assert {:ok, 600_000} = Shell.spawn_capable_max_timeout_ms(:standard)
    assert {:ok, 1_200_000} = Shell.spawn_capable_max_timeout_ms(:intensive)
    assert {:error, :invalid_resource_profile} = Shell.spawn_capable_max_timeout_ms(:turbo)
    assert {:error, :invalid_resource_profile} = Shell.spawn_capable_max_timeout_ms("intensive")
    assert {:error, :invalid_resource_profile} = Shell.spawn_capable_max_timeout_ms(nil)

    assert SpawnCapableTimeout.max_timeout_ms(:standard) ==
             Shell.spawn_capable_max_timeout_ms(:standard)

    assert SpawnCapableTimeout.max_timeout_ms(:intensive) ==
             Shell.spawn_capable_max_timeout_ms(:intensive)
  end

  @tag :security_regression
  test "security regression: standard rejects >600_000 while intensive admits <=1_200_000" do
    assert :ok = SpawnCapableTimeout.validate_timeout_ms(600_000, :standard)

    assert {:error, :timeout_too_large} =
             SpawnCapableTimeout.validate_timeout_ms(600_001, :standard)

    assert {:error, :timeout_too_large} =
             SpawnCapableTimeout.validate_timeout_ms(1_200_000, :standard)

    assert :ok = SpawnCapableTimeout.validate_timeout_ms(600_001, :intensive)
    assert :ok = SpawnCapableTimeout.validate_timeout_ms(1_200_000, :intensive)

    assert {:error, :timeout_too_large} =
             SpawnCapableTimeout.validate_timeout_ms(1_200_001, :intensive)

    assert {:error, :invalid_resource_profile} =
             SpawnCapableTimeout.validate_timeout_ms(1_000, :turbo)

    assert {:error, :timeout_too_small} = SpawnCapableTimeout.validate_timeout_ms(0, :standard)
    assert {:error, :invalid_timeout} = SpawnCapableTimeout.validate_timeout_ms(1.5, :standard)
  end

  test "projects only the exact trusted prelaunch deadline atom" do
    assert SpawnCapableTimeout.project_prelaunch_error(:deadline_exhausted) ==
             :operation_deadline_exceeded

    for unchanged <- [
          :operation_deadline_exceeded,
          :probe_failed,
          :probe_cancelled,
          "deadline_exhausted",
          ":deadline_exhausted",
          {:deadline_exhausted, :untrusted},
          %{error: :deadline_exhausted},
          nil
        ] do
      assert SpawnCapableTimeout.project_prelaunch_error(unchanged) == unchanged
    end
  end
end
