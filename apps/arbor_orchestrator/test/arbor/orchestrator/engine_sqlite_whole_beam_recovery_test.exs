defmodule Arbor.Orchestrator.EngineSQLiteWholeBeamRecoveryTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :slow
  @moduletag :database
  @moduletag timeout: 240_000
  @root Path.expand("../../../../..", __DIR__)
  @support Path.expand("../../support/engine_disk_node_recovery_support.ex", __DIR__)
  @marker "ARBOR_DISK_PROBE "
  @phase_timeout 60_000
  @max_output 1_048_576

  setup do
    disk_root =
      Path.expand(
        Path.join(System.tmp_dir!(), "arbor_engine_disk_#{System.unique_integer([:positive])}")
      )

    File.mkdir_p!(disk_root)
    File.chmod!(disk_root, 0o700)

    on_exit(fn ->
      assert Path.dirname(disk_root) == Path.expand(System.tmp_dir!())
      assert String.starts_with?(Path.basename(disk_root), "arbor_engine_disk_")

      # Test-process exit closes its Ports and delivers EOF to each child. Do
      # not delete a database still owned by a child whose shutdown is pending.
      for path <- Path.wildcard(Path.join(disk_root, "workload-*.pid")) do
        os_pid = path |> File.read!() |> String.to_integer()

        assert await_os_exit(os_pid, System.monotonic_time(:millisecond) + 5_000),
               "workload still exists; preserved fixture directory #{disk_root}"
      end

      File.rm_rf!(disk_root)
    end)

    %{disk_root: disk_root}
  end

  test "production-selected Memory, journal and checkpoint owners report observed SQLite durability",
       ctx do
    port = start_phase("config", ctx.disk_root)
    assert_phase_success(port, "config")
  end

  test "whole workload BEAM loss reconstructs SQLite authority and resumes without replaying a completed effect",
       ctx do
    owner = start_phase("crash", ctx.disk_root)
    {:os_pid, owner_os_pid} = Port.info(owner, :os_pid)
    {marker, _output} = await_marker(owner, "crash_window")
    assert marker["os_pid"] == Integer.to_string(owner_os_pid)
    assert Port.info(owner, :os_pid) == {:os_pid, owner_os_pid}
    assert File.exists?(Path.join(ctx.disk_root, "authority.sqlite3"))
    assert File.read!(Path.join(ctx.disk_root, "effects.log")) == "invoked\n"
    checkpoint = Path.join(ctx.disk_root, "logs/checkpoint.json")
    assert File.exists?(checkpoint)

    # This is the exact workload BEAM captured by its owned Port and confirmed
    # by that BEAM's handshake. Repo, Security, journal and Engine all die here.
    assert {_, 0} =
             System.cmd("kill", ["-KILL", Integer.to_string(owner_os_pid)],
               stderr_to_stdout: true
             )

    assert_receive {^owner, {:exit_status, status}}, 10_000
    assert status != 0
    assert Port.info(owner) == nil

    # Remove only the compatibility file after complete workload VM exit.
    # SQLite database/WAL, source DOT and private fixture identity remain disk.
    File.rm!(checkpoint)
    refute File.exists?(checkpoint)

    # B proves unavailable SQL cannot fall back to a warmed journal or file.
    # C then boots again from disk and opens its own fresh current authority.
    # D independently verifies the terminal journal and absence of replay.
    for phase <- ["outage", "resume", "completed"] do
      port = start_phase(phase, ctx.disk_root)
      assert_phase_success(port, phase)
    end

    assert File.read!(Path.join(ctx.disk_root, "effects.log")) == "invoked\n"
  end

  defp start_phase(phase, disk_root) do
    executable = System.find_executable("elixir") || flunk("elixir executable unavailable")

    paths =
      :code.get_path()
      |> Enum.map(&List.to_string/1)
      |> Enum.filter(&(Path.type(&1) == :absolute and File.dir?(&1)))

    path_args = Enum.flat_map(paths, &["-pa", &1])
    entrypoint = "Arbor.Orchestrator.EngineDiskNodeRecoverySupport.main(System.argv())"

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        {:line, 16_384},
        {:cd, disk_root},
        {:args, path_args ++ ["-r", @support, "-e", entrypoint, "--", phase, @root, disk_root]},
        {:env,
         [
           {~c"ARBOR_DB", ~c"sqlite"},
           {~c"ARBOR_ENV_PATH", String.to_charlist(Path.join(disk_root, "missing.env"))},
           {~c"ARBOR_SQLITE_PATH", String.to_charlist(Path.join(disk_root, "authority.sqlite3"))},
           {~c"ARBOR_DATA_DIR", String.to_charlist(disk_root)},
           {~c"ARBOR_SECURITY_STATE_DIR", String.to_charlist(Path.join(disk_root, "security"))},
           {~c"ERL_AFLAGS", false},
           {~c"ERL_FLAGS", false},
           {~c"ERL_ZFLAGS", false},
           {~c"ELIXIR_ERL_OPTIONS", ~c"+S 2:2 +A 2"}
         ]}
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    File.write!(Path.join(disk_root, "workload-#{phase}.pid"), Integer.to_string(os_pid))

    on_exit(fn ->
      # Closing the exact owned Port delivers EOF to the workload watcher.
      # No process-name lookup or unrelated OS PID is used for cleanup.
      if Port.info(port) != nil, do: Port.close(port)
    end)

    port
  end

  defp await_os_exit(os_pid, deadline) do
    # Signal zero observes only the exact captured child PID. It sends no
    # termination signal; a reused PID conservatively preserves the fixture.
    case System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {_, status} when status != 0 ->
        true

      _ ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(20)
          await_os_exit(os_pid, deadline)
        else
          false
        end
    end
  end

  defp assert_phase_success(port, phase) do
    {marker, output} = await_marker(port, "done")
    assert marker["phase"] == phase
    assert_receive {^port, {:exit_status, 0}}, 10_000, output
  end

  defp await_marker(port, stage) do
    deadline = System.monotonic_time(:millisecond) + @phase_timeout
    await_marker(port, stage, deadline, "", "")
  end

  defp await_marker(port, stage, deadline, line, output) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, {kind, chunk}}} when kind in [:eol, :noeol] ->
        output = output <> chunk <> if(kind == :eol, do: "\n", else: "")
        assert byte_size(output) <= @max_output, "workload output exceeded bound"
        line = line <> chunk

        if kind == :eol do
          case line do
            @marker <> payload ->
              decoded = Jason.decode!(payload)
              assert decoded["stage"] != "failed", output

              if decoded["stage"] == stage,
                do: {decoded, output},
                else: await_marker(port, stage, deadline, "", output)

            _ ->
              await_marker(port, stage, deadline, "", output)
          end
        else
          await_marker(port, stage, deadline, line, output)
        end

      {^port, {:exit_status, status}} ->
        flunk("workload exited #{status} before #{stage}: #{output}")
    after
      remaining -> flunk("workload timed out before #{stage}: #{output}")
    end
  end
end
