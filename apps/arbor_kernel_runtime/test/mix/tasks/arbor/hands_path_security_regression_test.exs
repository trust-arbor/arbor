defmodule Mix.Tasks.Arbor.HandsPathSecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag spec: "KSEC-015,KSEC-020"

  @moduletag :fast
  @moduletag :security_regression

  alias Mix.Tasks.Arbor.Hands.Capture
  alias Mix.Tasks.Arbor.Hands.Cleanup
  alias Mix.Tasks.Arbor.Hands.Send
  alias Mix.Tasks.Arbor.Hands.Spawn
  alias Mix.Tasks.Arbor.Hands.Stop
  alias Mix.Tasks.Arbor.HandsHelpers, as: Hands

  setup do
    original_cwd = File.cwd!()

    suffix = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    {:ok, system_tmp} = Arbor.Common.SafePath.resolve_real(System.tmp_dir!())
    root = Path.join(system_tmp, "arbor-hands-path-#{suffix}")
    :ok = File.mkdir(root)
    :ok = File.chmod(root, 0o700)
    File.cd!(root)

    File.mkdir_p!(Path.join(root, ".arbor/hands/safe"))
    sentinel = Path.join(root, ".arbor/roadmap-sentinel")
    File.write!(sentinel, "must survive")

    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      File.cd!(original_cwd)
      Mix.shell(previous_shell)
      File.rm_rf!(root)
    end)

    {:ok, root: root, sentinel: sentinel}
  end

  @tag spec: "KSEC-015,KSEC-020"
  test "security regression: cleanup rejects traversal before deleting the .arbor root", %{
    sentinel: sentinel
  } do
    assert catch_exit(Cleanup.run([".."])) == {:shutdown, 1}
    assert File.read!(sentinel) == "must survive"
  end

  test "security regression: every Hands entry point shares the closed name grammar" do
    assert {:error, :invalid_hand_name} = Hands.validate_name("../victim")
    assert {:error, :invalid_hand_name} = Hands.validate_name("safe\nsecond")
    assert :ok = Hands.validate_name("safe-name_1")

    for {task, args} <- [
          {Cleanup, ["../victim"]},
          {Stop, ["../victim", "--force"]},
          {Capture, ["../victim", "--summary"]},
          {Send, ["../victim", "message"]},
          {Spawn, ["task", "--name", "../victim", "--no-worktree"]}
        ] do
      assert catch_exit(task.run(args)) == {:shutdown, 1}
    end

    assert_raise ArgumentError, "invalid Hand name", fn -> Hands.hand_dir("../victim") end
  end

  test "security regression: Docker-bound messages strip terminal control characters too" do
    assert Send.sanitize_message("safe\n\e[31mmessage\r\0") == "safe[31mmessage"
  end

  test "security regression: cleanup rejects a valid-name symlink outside the Hands root", %{
    root: root
  } do
    outside = Path.join(root, "outside")
    File.mkdir_p!(outside)
    sentinel = Path.join(outside, "sentinel")
    File.write!(sentinel, "must survive")

    link = Path.join(root, ".arbor/hands/linked")
    :ok = File.ln_s(outside, link)

    assert catch_exit(Cleanup.run(["linked"])) == {:shutdown, 1}
    assert File.read!(sentinel) == "must survive"
  end

  @tag spec: "KSEC-015,KSEC-020"
  test "security regression: quote-and-semicolon workspace folder is a literal spawn argv", %{
    root: root
  } do
    marker = Path.join(root, "pwned-sentinel")
    folder = "x'; touch #{marker}; '"
    run_script = Path.join([root, folder, "run.sh"])

    assert {:ok, argv} = Spawn.local_tmux_argv("arbor-hand-sec", run_script)
    assert_literal_spawn_path(argv, run_script)
    refute_shell_command_executes(argv, marker)
  end

  @tag spec: "KSEC-015,KSEC-020"
  test "security regression: command-substitution workspace folder is a literal spawn argv", %{
    root: root
  } do
    folder = "$(id)"
    run_script = Path.join([root, folder, "run.sh"])

    assert {:ok, argv} = Spawn.local_tmux_argv("arbor-hand-sec", run_script)
    assert_literal_spawn_path(argv, run_script)

    {output, _status} = eval_tmux_shell_command(argv)
    refute output =~ "uid="
    assert Enum.any?(argv, &String.contains?(&1, "$(id)"))
  end

  @tag spec: "KSEC-015,KSEC-020"
  test "security regression: hands spawn path rejects NUL bytes and newlines" do
    assert {:error, :invalid_spawn_path} = Spawn.validate_spawn_path("foo\nbar")
    assert {:error, :invalid_spawn_path} = Spawn.validate_spawn_path("foo\rbar")
    assert {:error, :invalid_spawn_path} = Spawn.validate_spawn_path("foo" <> <<0>> <> "bar")
    assert {:error, :invalid_spawn_path} = Spawn.local_tmux_argv("arbor-hand-sec", "foo\nbar")
    assert {:ok, "/tmp/ok/run.sh"} = Spawn.validate_spawn_path("/tmp/ok/run.sh")
  end

  defp assert_literal_spawn_path(argv, path) when is_list(argv) and is_binary(path) do
    assert path in argv or ("ARBOR_HAND_RUN=" <> path) in argv,
           "spawn argv must carry the literal path as its own element, got: #{inspect(argv)}"

    refute Enum.any?(argv, fn arg ->
             arg != path and arg != "ARBOR_HAND_RUN=" <> path and String.contains?(arg, path)
           end),
           "path must not be interpolated into a shell command string, got: #{inspect(argv)}"
  end

  defp refute_shell_command_executes(argv, marker) do
    File.rm(marker)
    {_output, _status} = eval_tmux_shell_command(argv)
    refute File.exists?(marker), "hostile workspace path executed a side effect at #{marker}"
  end

  defp eval_tmux_shell_command(argv) do
    shell_command = List.last(argv)
    env = spawn_env_from_argv(argv)
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        send(
          parent,
          {:cmd,
           System.cmd("bash", ["--noprofile", "--norc", "-c", shell_command],
             stderr_to_stdout: true,
             env: env
           )}
        )
      end)

    receive do
      {:cmd, result} ->
        result

      {:DOWN, ^ref, :process, ^pid, _reason} ->
        {"", 1}
    after
      400 ->
        Process.exit(pid, :kill)
        {"", 1}
    end
  end

  defp spawn_env_from_argv(argv) do
    Enum.flat_map(argv, fn
      "ARBOR_HAND_RUN=" <> path -> [{"ARBOR_HAND_RUN", path}]
      _ -> []
    end)
  end
end
