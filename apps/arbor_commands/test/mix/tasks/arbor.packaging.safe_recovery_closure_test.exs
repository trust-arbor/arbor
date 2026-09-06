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

    assert {:error, {:arguments, {:conflicting_mode, ["--measure", "--write"]}}} =
             Task.execute(["--measure", "--write"])
  end

  test "report fails closed when committed evidence is absent" do
    root = temp_umbrella_root!()
    on_exit(fn -> File.rm_rf!(root) end)
    assert {:error, :evidence_missing} = Task.execute(["--root", root])
  end

  test "report succeeds when committed evidence is present" do
    assert {:ok, report} = Task.execute([])
    assert is_map(report)
  end

  defp temp_umbrella_root! do
    root =
      Path.join(
        System.tmp_dir!(),
        "arbor-safe-recovery-#{System.unique_integer([:positive, :monotonic])}"
      )

    for marker <- ["mix.exs", "apps/arbor_commands/mix.exs", "apps/arbor_kernel/mix.exs"] do
      path = Path.join(root, marker)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "# marker\n")
    end

    {:ok, real} = Arbor.Common.SafePath.resolve_real(root)
    real
  end
end
