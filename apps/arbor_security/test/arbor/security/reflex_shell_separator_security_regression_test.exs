defmodule Arbor.Security.ReflexShellSeparatorSecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag spec: "SSEC-015"

  @moduletag :fast
  @moduletag security: :regression

  alias Arbor.Security
  alias Arbor.Security.Reflex

  @tag spec: "SSEC-015"
  test "security regression: shell syntax cannot hide recursive root deletion" do
    for command <- [
          "/bin/rm -rfv /",
          "rm -rf -- /",
          "rm --recursive --force /",
          ~s(rm -rf "/"),
          "rm -rf $HOME",
          "true;rm -rf /",
          "true&&rm --recursive --force /",
          "false||/bin/rm -Rf $HOME",
          "printf ok|rm -rf ~/work",
          "printf ok&rm -rf ${HOME}",
          "true\nrm -rf /",
          "$(rm -rf /)",
          "echo $(/bin/rm -rfv /)",
          ~S|echo "$(rm --recursive --force /)"|,
          "`rm -rf /`",
          ~s(echo "`/bin/rm -rf /`")
        ] do
      assert {:blocked, reflex, _message} = Reflex.check(%{command: command})
      assert reflex.id == "rm_rf_root"
    end
  end

  test "security regression: public authorization rejects a glued separator bypass" do
    previous = Application.get_env(:arbor_security, :reflex_checking_enabled)
    Application.put_env(:arbor_security, :reflex_checking_enabled, true)

    on_exit(fn -> restore_env(:reflex_checking_enabled, previous) end)

    assert {:error, {:reflex_blocked, "rm_rf_root", _message}} =
             Security.authorize(
               "agent_reflex_separator_regression",
               "arbor://shell/exec",
               :execute,
               command: "true;rm -rf /",
               verify_identity: false
             )
  end

  test "quoted separator text remains data" do
    assert :ok = Reflex.check(%{command: ~s(echo 'true;rm -rf /')})
    assert :ok = Reflex.check(%{command: ~s(printf "%s" "true;rm -rf /")})
    assert :ok = Reflex.check(%{command: ~s(rm file.txt; printf "%s" "-rf /")})
    assert :ok = Reflex.check(%{command: ~S|echo '$(rm -rf /)'|})
    assert :ok = Reflex.check(%{command: ~s(echo '`rm -rf /`')})
  end

  defp restore_env(key, nil), do: Application.delete_env(:arbor_security, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_security, key, value)
end
