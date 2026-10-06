defmodule Arbor.Agent.SimpleAgentMissingAuthoritySecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag :fast
  @moduletag :security_regression

  test "security regression: public SimpleAgent never falls back to an unapproved action effect" do
    # The owning helper starts real authority. A fresh BEAM using these exact
    # compiled paths proves absence without changing the helper's shared tree.
    paths = Enum.flat_map(:code.get_path(), fn path -> ["-pa", to_string(path)] end)
    script = Path.expand("../../isolated/simple_agent_missing_authority.exs", __DIR__)
    elixir = System.find_executable("elixir") || raise "pinned Elixir unavailable"
    {output, status} = System.cmd(elixir, paths ++ [script], stderr_to_stdout: true)
    assert status == 0, output
    assert output =~ "1 test, 0 failures", output
    assert output =~ "SIMPLE_AGENT_MISSING_AUTHORITY_REFUSED", output
  end
end
