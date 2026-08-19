defmodule Arbor.Shell.TrustedSystemPrincipalSecurityRegressionTest do
  @moduledoc """
  Security regression: trusted-system Shell APIs reject a smuggled principal.

  Parent behavior (must fail on checkout of the exact parent):
  `Arbor.Shell.execute/2` and `execute_direct/3` ignore `:agent_id` and
  `:principal_id`, so an extension can attach a principal key and still
  launch on the host path.

  Fixed behavior: atom-key first, then the string-key fallback, those
  keys are denied with `:unauthorized` and the command does not launch.
  Host callers that pass no principal still use execute/execute_direct.
  """
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  @principal_opt_cases [
    {:agent_id, "agent_smuggle"},
    {:principal_id, "agent_smuggle"},
    {"agent_id", "agent_smuggle"},
    {"principal_id", "agent_smuggle"}
  ]

  test "security regression: execute/2 with a principal key is denied and does not launch" do
    for {key, value} <- @principal_opt_cases do
      marker = marker_path()
      opts = [{key, value}, {:sandbox, :none}]

      assert {:error, :unauthorized} = Arbor.Shell.execute("touch #{marker}", opts),
             "execute/2 accepted principal key #{inspect(key)}"

      refute File.exists?(marker),
             "execute/2 launched after principal key #{inspect(key)}"
    end
  end

  test "security regression: execute_direct/3 with a principal key is denied and does not launch" do
    for {key, value} <- @principal_opt_cases do
      marker = marker_path()
      opts = [{key, value}, {:sandbox, :none}]

      assert {:error, :unauthorized} =
               Arbor.Shell.execute_direct("touch", [marker], opts),
             "execute_direct/3 accepted principal key #{inspect(key)}"

      refute File.exists?(marker),
             "execute_direct/3 launched after principal key #{inspect(key)}"
    end
  end

  test "security regression: host execute/execute_direct with no principal still launch" do
    assert {:ok, result} = Arbor.Shell.execute("echo host-ok", sandbox: :none)
    assert String.trim(result.stdout) == "host-ok"

    assert {:ok, direct} =
             Arbor.Shell.execute_direct("echo", ["host-direct"], sandbox: :none)

    assert String.trim(direct.stdout) == "host-direct"
  end

  defp marker_path do
    Path.join(
      System.tmp_dir!(),
      "arbor_shell_p1b_principal_#{System.unique_integer([:positive])}"
    )
  end
end
