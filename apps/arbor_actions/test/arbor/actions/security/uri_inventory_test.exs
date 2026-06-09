defmodule Arbor.Actions.Security.UriInventoryTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Actions.Security.UriInventory

  setup do
    dir = Path.join(System.tmp_dir!(), "uriinv_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  defp row_for(rows, ns), do: Enum.find(rows, &(&1.namespace == ns))

  test "reports an unregistered namespace as a triage gap", %{dir: dir} do
    File.write!(Path.join(dir, "a.ex"), """
    defmodule A do
      @grant %{resource_uri: "arbor://zzznotreal/do/thing"}
      def g, do: @grant
    end
    """)

    row = row_for(UriInventory.build(dir), "zzznotreal")
    assert row.in_registry == false
    assert row.uncovered == ["arbor://zzznotreal/do/thing"]
    assert row.recommendation =~ "TRIAGE"
    assert "a.ex" in Enum.map(row.files, &Path.basename/1)
  end

  test "a registered namespace has no gap", %{dir: dir} do
    File.write!(Path.join(dir, "b.ex"), """
    defmodule B do
      def g, do: "arbor://fs/read/docs"
    end
    """)

    row = row_for(UriInventory.build(dir), "fs")
    assert row.in_registry == true
    assert row.uncovered == []
    assert row.recommendation == "ok"
  end
end
