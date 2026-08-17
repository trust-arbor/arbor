defmodule Mix.Tasks.Arbor.Packaging.SafeRecoveryClosureTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Arbor.Packaging.SafeRecoveryClosure, as: Task

  @moduletag :fast

  test "production task forbids runtime hooks and unknown options" do
    assert {:error, {:production_task_forbids_runtime_hooks, [:run_peer]}} =
             Task.execute([], run_peer: fn -> :ok end)

    assert {:error, {:arguments, :unknown_or_invalid_option}} =
             Task.execute(["--cookie", "secret"])

    assert {:error, {:arguments, :unknown_or_invalid_option}} =
             Task.execute(["--executable", "/bin/true"])

    assert {:error, {:arguments, {:conflicting_mode, ["--check", "--measure"]}}} =
             Task.execute(["--check", "--measure"])
  end

  test "report fails closed when committed evidence is absent" do
    assert {:error, :evidence_missing} = Task.execute([])
  end

  test "measure fails closed without a held release" do
    assert {:error, :held_release_unavailable} = Task.execute(["--measure"])
  end
end
