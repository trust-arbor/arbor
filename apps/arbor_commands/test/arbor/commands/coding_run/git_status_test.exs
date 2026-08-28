defmodule Arbor.Commands.CodingRun.GitStatusTest do
  use ExUnit.Case, async: true

  alias Arbor.Commands.CodingRun.GitStatus

  @moduletag :fast

  describe "run/2 fail-closed" do
    test "invalid worktree returns closed error" do
      assert {:error, :invalid_worktree} = GitStatus.run("/no/such/worktree")
      assert {:error, :invalid_worktree} = GitStatus.run(nil)
      assert {:error, :invalid_worktree} = GitStatus.run("")
    end

    test "directory without .git is invalid_worktree" do
      dir = tmp_dir()
      on_exit(fn -> File.rm_rf(dir) end)
      assert {:error, :invalid_worktree} = GitStatus.run(dir)
    end

    test "non-zero exit returns closed error and does not yield a payload" do
      worktree = git_worktree!()
      on_exit(fn -> File.rm_rf(worktree) end)

      assert {:error, :nonzero_exit} =
               GitStatus.run(worktree, executable: false_bin(), args: [])
    end

    test "timeout kills the OS process and returns closed error" do
      worktree = git_worktree!()
      on_exit(fn -> File.rm_rf(worktree) end)
      pid_file = Path.join(worktree, "sleep.pid")
      script = write_pid_sleep_script!(worktree)

      assert {:error, :timeout} =
               GitStatus.run(worktree,
                 executable: script,
                 args: [pid_file],
                 timeout_ms: 500
               )

      pid = read_pid(pid_file)
      refute os_alive?(pid)
    end

    test "output over 1 MiB kills the OS process and returns closed error" do
      worktree = git_worktree!()
      on_exit(fn -> File.rm_rf(worktree) end)
      pid_file = Path.join(worktree, "flood.pid")
      script = write_pid_flood_script!(worktree)

      assert {:error, :output_exceeded} =
               GitStatus.run(worktree,
                 executable: script,
                 args: [pid_file],
                 timeout_ms: 5_000,
                 max_bytes: 1_048_576
               )

      pid = read_pid(pid_file)
      refute os_alive?(pid)
    end
  end

  describe "decode/1" do
    test "decodes a path with spaces" do
      assert {:ok, ["path with spaces.ex"]} = GitStatus.decode(" M path with spaces.ex\0")
    end

    test "decodes a NUL-delimited rename record" do
      assert {:ok, ["old name.txt", "new name.txt"]} =
               GitStatus.decode("R  old name.txt\0new name.txt\0")
    end

    test "empty successful payload is an empty path list" do
      assert {:ok, []} = GitStatus.decode(<<>>)
    end

    test "malformed record is closed" do
      assert {:error, :malformed_output} = GitStatus.decode("not-porcelain")
    end
  end

  defp git_worktree! do
    dir = tmp_dir()
    File.mkdir_p!(Path.join(dir, ".git"))
    dir
  end

  defp tmp_dir do
    path = Path.join(System.tmp_dir!(), "coding-run-git-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end

  defp false_bin do
    System.find_executable("false") || "/bin/false"
  end

  defp write_pid_sleep_script!(dir) do
    path = Path.join(dir, "sleep.sh")

    File.write!(path, """
    #!/bin/sh
    echo $$ > "$1"
    exec sleep 30
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp write_pid_flood_script!(dir) do
    path = Path.join(dir, "flood.sh")

    File.write!(path, """
    #!/bin/sh
    echo $$ > "$1"
    dd if=/dev/zero bs=65536 count=40 2>/dev/null
    exec sleep 30
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp read_pid(path) do
    wait_for_file(path, 100)
    path |> File.read!() |> String.trim() |> String.to_integer()
  end

  defp wait_for_file(_path, 0), do: :ok

  defp wait_for_file(path, n) do
    if File.exists?(path) do
      :ok
    else
      Process.sleep(20)
      wait_for_file(path, n - 1)
    end
  end

  defp os_alive?(pid) when is_integer(pid) do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_out, 0} -> true
      _other -> false
    end
  end

  @tag :security_regression
  test "security regression: an unterminated porcelain record is malformed, never a path" do
    assert {:error, :malformed_output} = GitStatus.decode(" M allowed/path.ex")
    assert {:ok, ["allowed/path.ex"]} = GitStatus.decode(" M allowed/path.ex\0")
    assert {:ok, []} = GitStatus.decode("")
  end
end
