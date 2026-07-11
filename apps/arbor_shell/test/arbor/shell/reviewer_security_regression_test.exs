defmodule Arbor.Shell.ReviewerSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Shell
  alias Arbor.Shell.ExecutionRegistry

  @moduletag :fast

  test "security regression: runtime PATH cannot substitute an executable identity" do
    root = fixture_root("path")
    fake_echo = Path.join(root, "echo")
    marker = Path.join(root, "fake-echo-ran")
    original_path = System.get_env("PATH", "")
    File.mkdir_p!(root)
    File.write!(fake_echo, "#!/bin/sh\ntouch '#{marker}'\necho forged\n")
    File.chmod!(fake_echo, 0o755)

    try do
      System.put_env("PATH", root <> ":" <> original_path)
      assert {:ok, result} = Shell.execute_direct("echo", ["pinned"], sandbox: :none)
      assert String.trim(result.stdout) == "pinned"
      refute File.exists?(marker)
    after
      System.put_env("PATH", original_path)
      File.rm_rf!(root)
    end
  end

  test "security regression: timeout contains a delayed descendant before returning" do
    root = fixture_root("tree")
    marker = Path.join(root, "delayed-child")
    File.mkdir_p!(root)

    try do
      script = "(sleep 0.4; touch '#{marker}') & sleep 5"

      assert {:ok, result} =
               Shell.execute_direct("sh", ["-c", script], sandbox: :none, timeout: 100)

      assert result.timed_out
      Process.sleep(700)
      refute File.exists?(marker)
    after
      File.rm_rf!(root)
    end
  end

  test "security regression: raw legacy status mutation cannot forge terminal success" do
    assert {:ok, execution_id} =
             Shell.execute_async("sleep 2", sandbox: :none, timeout: 3_000)

    registry = Process.whereis(ExecutionRegistry)

    forged_reply =
      Task.async(fn ->
        raw_call(
          registry,
          {:transition_status, execution_id, [:pending, :running], :completed,
           %{result: %{exit_code: 0}}}
        )
      end)
      |> Task.await()

    refute forged_reply == :ok
    assert {:ok, :running} = Shell.get_status(execution_id)
    assert :ok = Shell.kill(execution_id)
  end

  defp fixture_root(tag) do
    Path.join(
      System.tmp_dir!(),
      "arbor_shell_reviewer_#{tag}_#{System.unique_integer([:positive])}"
    )
  end

  defp raw_call(registry, request) do
    ref = make_ref()
    send(registry, {:"$gen_call", {self(), ref}, request})

    receive do
      {^ref, reply} -> reply
    after
      1_000 -> :no_reply
    end
  end
end
