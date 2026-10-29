defmodule Arbor.Shell.HomeCredentialPathSecurityRegressionTest do
  @moduledoc """
  Security regression: AgentContainment's public credential list is the
  same list Builtin uses to generate blocking file reflexes.
  """

  use ExUnit.Case, async: true

  @moduletag :fast
  @moduletag security: :regression

  alias Arbor.Common.HomeCredentialPaths
  alias Arbor.Security.Reflex.Builtin
  alias Arbor.Shell.AgentContainment

  test "security regression: reflex blocks are generated from AgentContainment's list" do
    containment = AgentContainment.home_credential_paths()
    assert containment == HomeCredentialPaths.entries()
    refute containment == []

    generated =
      Builtin.file_reflexes()
      |> Enum.filter(&(&1.id in Enum.map(containment, fn entry -> entry.id end)))

    assert Enum.map(generated, & &1.id) |> Enum.sort() ==
             Enum.map(containment, & &1.id) |> Enum.sort()

    assert Enum.all?(generated, &(&1.response == :block))
  end

  test "security regression: containment regex still matches every credential path" do
    for %{glob: glob} <- AgentContainment.home_credential_paths() do
      relative = glob |> String.trim_leading("~/") |> String.replace("*", "x")
      path = Path.join("/home/agent", relative)
      assert AgentContainment.protected_path?(path), "#{path} escaped containment"
    end
  end
end
