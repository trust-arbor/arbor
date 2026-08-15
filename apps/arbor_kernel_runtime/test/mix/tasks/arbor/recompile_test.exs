defmodule Mix.Tasks.Arbor.RecompileTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  test "compiles changed source before reconciling live modules" do
    attributes = Mix.Tasks.Arbor.Recompile.__info__(:attributes)

    assert Keyword.fetch!(attributes, :requirements) == ["compile"]
  end
end
