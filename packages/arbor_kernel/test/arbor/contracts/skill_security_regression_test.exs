defmodule Arbor.Contracts.SkillSecurityRegressionTest do
  use ExUnit.Case, async: true
  @moduletag spec: "KSEC-006"

  @moduletag :fast

  alias Arbor.Contracts.Skill

  @tag spec: "KSEC-006"
  test "security regression: constructing a skill never grants trusted taint by default" do
    assert {:ok, skill} = Skill.new(%{name: "review", description: "Review code"})
    assert skill.taint == :untrusted

    assert %Skill{name: "literal", description: "Literal"}.taint == :untrusted
  end
end
