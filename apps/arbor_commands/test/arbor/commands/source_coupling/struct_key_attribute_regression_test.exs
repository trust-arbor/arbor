defmodule Arbor.Commands.SourceCoupling.StructKeyAttributeRegressionTest do
  use ExUnit.Case, async: true

  alias Arbor.Commands.SourceCoupling.AstExtract

  @moduletag :fast

  test "symbolic export maps with __struct__ keys retain nested module leaves" do
    source = """
    defmodule Arbor.Provider.ExportTable do
      @providers %{
        __struct__: 0,
        top: Arbor.Alpha.Top,
        record: %{__struct__: 0, new: 3, provider: Arbor.Alpha.Record}
      }

      def exports, do: @providers
    end
    """

    assert {:ok, result} =
             AstExtract.extract("packages/arbor_persistence/lib/export_table.ex", source)

    for module <- ["Arbor.Alpha.Top", "Arbor.Alpha.Record"] do
      assert Enum.any?(result.references, &(&1.target == module and &1.kind == "attribute"))
    end
  end
end
