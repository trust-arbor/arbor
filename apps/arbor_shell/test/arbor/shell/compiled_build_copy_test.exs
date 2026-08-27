defmodule Arbor.Shell.CompiledBuildCopyTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  test "seeded Mix priv link is rewritten to the guest deps path" do
    {source, dest} = fixture_roots()
    tree_priv = Path.join(source, "tree/x/priv")
    File.mkdir_p!(tree_priv)
    File.write!(Path.join(tree_priv, "keep"), "ok\n")

    link_dir = Path.join(source, "build/test/lib/x")
    File.mkdir_p!(link_dir)
    File.ln_s!("../../../../tree/x/priv", Path.join(link_dir, "priv"))

    assert :ok =
             Arbor.Shell.copy_linux_compiled_dependency_build(
               Path.join(source, "build"),
               dest
             )

    link = Path.join(dest, "test/lib/x/priv")
    assert {:ok, %File.Stat{type: :symlink}} = File.lstat(link)
    assert File.read_link!(link) == "/arbor/deps/x/priv"
    assert File.regular?(Path.join(dest, ".arbor-compiled-build-seeded"))
  end

  test "seeded in-build relative link is rewritten to the guest build path" do
    {source, dest} = fixture_roots()
    File.mkdir_p!(Path.join(source, "build/test/lib/y/ebin"))
    link_dir = Path.join(source, "build/test/lib/x")
    File.mkdir_p!(link_dir)
    File.ln_s!("../y/ebin", Path.join(link_dir, "ebin"))

    assert :ok =
             Arbor.Shell.copy_linux_compiled_dependency_build(
               Path.join(source, "build"),
               dest
             )

    assert File.read_link!(Path.join(dest, "test/lib/x/ebin")) ==
             "/arbor/build/test/lib/y/ebin"
  end

  test "seeded copy refuses absolute and outside Mix links" do
    {source, dest} = fixture_roots()
    link_dir = Path.join(source, "build/test/lib/x")
    File.mkdir_p!(link_dir)
    File.ln_s!("/etc/passwd", Path.join(link_dir, "priv"))

    assert {:error, {:compiled_build_seed_failed, :symlink_rejected}} =
             Arbor.Shell.copy_linux_compiled_dependency_build(
               Path.join(source, "build"),
               dest
             )

    File.rm!(Path.join(link_dir, "priv"))
    File.ln_s!("../../../../../../tmp/outside", Path.join(link_dir, "priv"))

    assert {:error, {:compiled_build_seed_failed, :symlink_rejected}} =
             Arbor.Shell.copy_linux_compiled_dependency_build(
               Path.join(source, "build"),
               dest
             )
  end

  defp fixture_roots do
    root =
      Path.join(
        System.tmp_dir!(),
        "compiled-build-copy-#{System.unique_integer([:positive])}"
      )

    source = Path.join(root, "baseline")
    dest = Path.join(root, "unit-build")
    File.mkdir_p!(Path.join(source, "build"))
    File.mkdir_p!(Path.join(source, "tree"))
    File.mkdir_p!(dest)
    on_exit(fn -> File.rm_rf(root) end)
    {source, dest}
  end
end
