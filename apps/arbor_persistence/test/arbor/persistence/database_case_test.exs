defmodule Arbor.Persistence.DatabaseCaseTest do
  use ExUnit.Case, async: true

  alias Arbor.Persistence.DatabaseCase

  @moduletag :fast

  test "unavailable databases produce an explicit valid setup failure" do
    assert_raise RuntimeError,
                 ~r/database test prerequisite unavailable: :connection_refused/,
                 fn ->
                   DatabaseCase.raise_unavailable_database!(:connection_refused)
                 end
  end

  test "setup callbacks never return the invalid skip tuple" do
    source = File.read!(Path.expand("../../../lib/arbor/persistence/database_case.ex", __DIR__))

    refute source =~ ~r/\{:skip\s*,/
    assert source =~ "raise_unavailable_database!"
  end
end
