defmodule Mix.Tasks.Arbor.ChatAuthSecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  setup do
    tmp_dir = scratch_dir!("arbor-chat-auth")
    previous = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(previous)
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
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

  defp scratch_dir!(prefix) do
    {:ok, system_tmp} = Arbor.Common.SafePath.resolve_real(System.tmp_dir!())
    token = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    path = Path.join(system_tmp, "#{prefix}-#{token}")
    File.mkdir!(path)
    File.chmod!(path, 0o700)
    path
  end
end
