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
end
