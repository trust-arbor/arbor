defmodule Mix.Tasks.Arbor.ChatAuthSecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :tmp_dir

  setup do
    previous = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous) end)
    :ok
  end

  test "security regression: missing operator key rejects chat before opening a connection", %{
    tmp_dir: dir
  } do
    assert catch_exit(
             Mix.Tasks.Arbor.Agent.run([
               "chat",
               "unreachable-test-agent",
               "private draft",
               "--key-file",
               Path.join(dir, "missing.key")
             ])
           ) == {:shutdown, 1}

    assert_received {:mix_shell, :error, [message]}
    assert message =~ "Chat requires a valid private operator key"
    assert message =~ "mix arbor.user.init"
    refute message =~ "private draft"
  end

  test "security regression: malformed operator key cannot fall back to compatibility chat", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "malformed.key")
    File.write!(path, "not signing material")
    File.chmod!(path, 0o600)

    assert catch_exit(
             Mix.Tasks.Arbor.Agent.run([
               "chat",
               "unreachable-test-agent",
               "private draft",
               "--key-file",
               path
             ])
           ) == {:shutdown, 1}

    assert_received {:mix_shell, :error, [message]}
    assert message =~ "Chat requires a valid private operator key"
  end
end
