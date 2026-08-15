defmodule Arbor.Commands.PackagingRootTest do
  use ExUnit.Case, async: true

  alias Arbor.Commands.PackagingRoot

  test "discovers the post-K4 umbrella from a nested directory" do
    root = complete_root!()
    nested = Path.join(root, "apps/arbor_commands/lib")
    File.mkdir_p!(nested)

    assert {:ok, ^root} = PackagingRoot.discover(nested)
    assert {:ok, ^root} = PackagingRoot.resolve(root)
  end

  test "rejects retired and incomplete lookalike roots" do
    root = tmp_root!()
    write_marker!(root, "apps/arbor_contracts/mix.exs")

    refute PackagingRoot.root?(root)
    assert {:error, :invalid_root_marker} = PackagingRoot.resolve(root)

    write_marker!(root, "mix.exs")
    write_marker!(root, "apps/arbor_kernel/mix.exs")

    refute PackagingRoot.root?(root)
    assert {:error, :invalid_root_marker} = PackagingRoot.resolve(root)
  end

  defp complete_root! do
    root = tmp_root!()

    Enum.each(
      ["mix.exs", "apps/arbor_commands/mix.exs", "apps/arbor_kernel/mix.exs"],
      &write_marker!(root, &1)
    )

    root
  end

  defp tmp_root! do
    root = Path.join(System.tmp_dir!(), "packaging-root-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp write_marker!(root, relative) do
    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "defmodule Marker do\nend\n")
  end
end
