defmodule Arbor.Shell.SpawnCapableSecurityRegressionTest do
  @moduledoc """
  Security regressions for the public spawn-capable facade.

  Proves retired Application-configured `:spawn_backend` /
  `:spawn_executable_manifest` paths are never consulted. Uses only
  malformed/relative facade input so tests never depend on host Apple Container
  state.
  """

  use ExUnit.Case, async: false

  alias Arbor.Shell
  alias Arbor.Shell.ExecutablePolicy

  @moduletag :fast
  @moduletag :security_regression

  @relative_preflight {:error, {:invalid_tool_name, :relative_path}}
  @legacy_process Arbor.Shell.LegacySpawnRegressionProcess

  defmodule BlockingLegacyBackend do
    def capabilities do
      [
        :atomic_executable_identity,
        :deadline,
        :isolated_worktree_mount,
        :output_limit,
        :owner_lifecycle,
        :spawn_processes,
        :whole_unit_termination
      ]
    end

    def available?(_request) do
      send(probe().test_pid, :legacy_admission_called)

      receive do
        :release_legacy_admission -> :ok
      end
    end

    def execute(_request) do
      send(probe().test_pid, :legacy_execute_called)
      {:error, :unexpected_legacy_execute}
    end

    defp probe, do: Application.fetch_env!(:arbor_shell, :legacy_spawn_regression_probe)
  end

  defmodule NoisyLegacyBackend do
    @process_name Arbor.Shell.LegacySpawnRegressionProcess

    def capabilities do
      [
        :atomic_executable_identity,
        :deadline,
        :isolated_worktree_mount,
        :output_limit,
        :owner_lifecycle,
        :spawn_processes,
        :whole_unit_termination
      ]
    end

    def available?(_request), do: :ok

    def execute(_request) do
      probe = Application.fetch_env!(:arbor_shell, :legacy_spawn_regression_probe)
      File.write!(probe.marker, "legacy backend executed")
      caller = self()

      child =
        spawn(fn ->
          Process.register(self(), @process_name)
          send(caller, {:legacy_process_ready, self()})
          receive do: (:stop -> :ok)
        end)

      receive do
        {:legacy_process_ready, ^child} -> :ok
      end

      send(probe.test_pid, {:legacy_execute_called, child})

      {:ok,
       %{
         exit_code: 0,
         stdout: String.duplicate("legacy noise\n", 100),
         stderr: "",
         duration_ms: 0,
         timed_out: false,
         killed: false,
         output_truncated: false,
         output_limit_exceeded: false
       }}
    end
  end

  setup do
    previous_backend = Application.get_env(:arbor_shell, :spawn_backend)
    previous_manifest = Application.get_env(:arbor_shell, :spawn_executable_manifest)
    previous_probe = Application.get_env(:arbor_shell, :legacy_spawn_regression_probe)

    on_exit(fn ->
      if pid = Process.whereis(@legacy_process), do: Process.exit(pid, :kill)
      restore(:spawn_backend, previous_backend)
      restore(:spawn_executable_manifest, previous_manifest)
      restore(:legacy_spawn_regression_probe, previous_probe)
      replace_executable_policy!()
    end)

    :ok
  end

  test "security regression: relative tool is pure preflight before path or policy lookup" do
    root = fixture_root("early-return")
    on_exit(fn -> File.rm_rf!(root) end)
    configure_legacy_backend!(BlockingLegacyBackend, root)

    # Relative tool name is rejected by pure preflight; never touches legacy
    # backend, path resolution, or executable-policy membership.
    assert @relative_preflight ==
             Shell.execute_spawn_capable("mix", ["compile"], cwd: Path.join(root, "missing"))

    remove_executable_policy!()

    assert @relative_preflight ==
             Shell.execute_spawn_capable("mix", ["compile"], cwd: root)

    refute_receive :legacy_admission_called, 50
    refute_receive :legacy_execute_called, 50
  end

  test "security regression: configured blocking legacy admission is never called" do
    root = fixture_root("blocking-admission")
    on_exit(fn -> File.rm_rf!(root) end)
    configure_legacy_backend!(BlockingLegacyBackend, root)

    task =
      Task.async(fn ->
        Shell.execute_spawn_capable("legacy-tool", [], cwd: root)
      end)

    yielded =
      case Task.yield(task, 200) do
        nil ->
          Task.shutdown(task, :brutal_kill)
          :timed_out

        result ->
          result
      end

    # Relative legacy-tool name fails pure preflight without blocking on
    # available?/1 — proves Application-configured backend is ignored.
    assert yielded == {:ok, @relative_preflight}
    refute_receive :legacy_admission_called, 50
    refute_receive :legacy_execute_called, 50
  end

  test "security regression: configured noisy legacy execute starts no process or marker" do
    root = fixture_root("noisy-execute")
    on_exit(fn -> File.rm_rf!(root) end)
    marker = Path.join(root, "legacy-executed")
    configure_legacy_backend!(NoisyLegacyBackend, root, marker)

    assert @relative_preflight ==
             Shell.execute_spawn_capable("legacy-tool", [], cwd: root)

    refute_receive {:legacy_execute_called, _pid}, 50
    refute File.exists?(marker)
    assert Process.whereis(@legacy_process) == nil
  end

  defp configure_legacy_backend!(backend, root, marker \\ nil) do
    File.mkdir_p!(root)
    tool = Path.join(root, "legacy-tool")
    File.write!(tool, "#!/bin/sh\nexit 0\n")
    File.chmod!(tool, 0o755)

    digest =
      tool
      |> File.read!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    Application.put_env(:arbor_shell, :spawn_backend, backend)

    Application.put_env(:arbor_shell, :spawn_executable_manifest, %{
      "legacy-tool" => %{path: tool, sha256: digest}
    })

    Application.put_env(:arbor_shell, :legacy_spawn_regression_probe, %{
      test_pid: self(),
      marker: marker
    })

    replace_executable_policy!()
  end

  defp fixture_root(tag) do
    Path.join(
      System.tmp_dir!(),
      "arbor_spawn_capable_#{tag}_#{System.unique_integer([:positive])}"
    )
  end

  defp replace_executable_policy! do
    remove_executable_policy!()

    case Supervisor.start_child(
           Arbor.Shell.Supervisor,
           {ExecutablePolicy, startup_path: System.get_env("PATH", "")}
         ) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp remove_executable_policy! do
    case Supervisor.terminate_child(Arbor.Shell.Supervisor, ExecutablePolicy) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end

    case Supervisor.delete_child(Arbor.Shell.Supervisor, ExecutablePolicy) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  defp restore(key, nil), do: Application.delete_env(:arbor_shell, key)
  defp restore(key, value), do: Application.put_env(:arbor_shell, key, value)
end
