defmodule Arbor.Shell.CapShellTest do
  @moduledoc """
  CapShell is intentionally fail-closed (security API break).

  Positive compound-execution tests that contradicted the fail-closed contract
  were removed. This suite retains non-execution checks (default config,
  compound detection via the public facade) and proves CapShell.run/3 never
  executes. Behavioral no-side-effect regressions live in
  `cap_shell_security_regression_test.exs`.
  """
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Shell.CapShell

  @unavailable {:error, {:compound_shell_unavailable, :security_boundary_incomplete}}

  describe "compound_shell_enabled? default" do
    test "absent config key defaults to false (fail-closed routing)" do
      prev = Application.get_env(:arbor_shell, :compound_shell_enabled)
      Application.delete_env(:arbor_shell, :compound_shell_enabled)

      try do
        refute Arbor.Shell.compound_shell_enabled?()
      after
        if is_nil(prev),
          do: Application.delete_env(:arbor_shell, :compound_shell_enabled),
          else: Application.put_env(:arbor_shell, :compound_shell_enabled, prev)
      end
    end

    test "explicit true reports enabled without re-enabling execution" do
      prev = Application.get_env(:arbor_shell, :compound_shell_enabled)
      Application.put_env(:arbor_shell, :compound_shell_enabled, true)

      try do
        assert Arbor.Shell.compound_shell_enabled?()
        # Config true still cannot execute — CapShell.run remains unavailable.
        assert @unavailable = CapShell.run("agent_cfg", "echo a && echo b")
      after
        if is_nil(prev),
          do: Application.delete_env(:arbor_shell, :compound_shell_enabled),
          else: Application.put_env(:arbor_shell, :compound_shell_enabled, prev)
      end
    end
  end

  describe "compound_command?/1 detection (non-execution)" do
    test "detects sequencing, pipes, substitution, and redirection" do
      assert Arbor.Shell.compound_command?("sleep 1; touch /tmp/x")
      assert Arbor.Shell.compound_command?("echo a && echo b")
      assert Arbor.Shell.compound_command?("cat file | wc -l")
      assert Arbor.Shell.compound_command?("echo $(date)")
      assert Arbor.Shell.compound_command?("echo hi > /tmp/out")
      refute Arbor.Shell.compound_command?("echo hello")
      refute Arbor.Shell.compound_command?("git --version")
    end
  end

  describe "CapShell.run/3 intentional security API break" do
    test "always returns compound_shell_unavailable without executing" do
      agent_id = "agent_capshell_#{:erlang.unique_integer([:positive])}"

      marker =
        Path.join(System.tmp_dir!(), "capshell_unit_#{:erlang.unique_integer([:positive])}")

      File.rm(marker)

      try do
        assert @unavailable = CapShell.run(agent_id, "touch #{marker}")
        assert @unavailable = CapShell.run(agent_id, "echo hello | grep hello")
        assert @unavailable = CapShell.run(agent_id, "git --version && echo ok")
        assert @unavailable = CapShell.run(agent_id, "if then fi fi )(")
        # Malformed terms must return, not raise FunctionClauseError.
        assert @unavailable = CapShell.run(nil, :bad, "opts")
        assert @unavailable = CapShell.run()

        refute File.exists?(marker), "CapShell.run must not execute commands"
      after
        File.rm(marker)
      end
    end
  end

  describe "ordinary non-compound Executor behavior unchanged" do
    test "single-command execute still runs through the bounded path" do
      assert {:ok, result} = Arbor.Shell.execute("echo capshell-executor-ok", sandbox: :basic)
      assert result.exit_code == 0
      assert result.stdout =~ "capshell-executor-ok"
    end

    test "compound on default-off path is rejected by sandbox metacharacters" do
      prev = Application.get_env(:arbor_shell, :compound_shell_enabled)
      Application.delete_env(:arbor_shell, :compound_shell_enabled)

      try do
        assert {:error, {:shell_metacharacters, _}} =
                 Arbor.Shell.execute("echo a && echo b", sandbox: :basic)
      after
        if is_nil(prev),
          do: Application.delete_env(:arbor_shell, :compound_shell_enabled),
          else: Application.put_env(:arbor_shell, :compound_shell_enabled, prev)
      end
    end
  end
end
