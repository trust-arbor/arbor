Code.require_file("trusted_build_test_helpers.exs", __DIR__)

defmodule Arbor.Shell.TrustedBuildHexSeedTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Shell.TrustedBuild.HexSeed
  alias Arbor.Shell.TrustedBuild.Identity
  alias Arbor.Shell.TrustedBuildTestHelpers, as: Helpers

  test "copies a nonempty tree through temp modes then finalizes readonly and writable" do
    {source_handle, digest} = write_hex_tree!()

    try do
      readonly = dest!("ro")
      writable = dest!("rw")

      assert {:ok, ro_digest} = HexSeed.seed_tree(source_handle.root, readonly, digest, :readonly)
      assert {:ok, rw_digest} = HexSeed.seed_tree(source_handle.root, writable, digest, :writable)

      assert {:ok, ^digest} = Identity.tree_digest(source_handle.root)
      {:ok, source_content} = Identity.content_digest(source_handle.root)
      assert {:ok, ^source_content} = Identity.content_digest(readonly)
      assert {:ok, ^source_content} = Identity.content_digest(writable)
      ro_handle = Helpers.capture_handle!(readonly)
      rw_handle = Helpers.capture_handle!(writable)
      assert ro_digest != digest
      assert rw_digest != digest
      assert ro_digest != rw_digest

      assert_mode(readonly, 0o555)
      assert_mode(Path.join(readonly, "hex-2.0.0"), 0o555)
      assert_mode(Path.join(readonly, "hex-2.0.0/hex"), 0o444)
      assert_mode(writable, 0o700)
      assert_mode(Path.join(writable, "hex-2.0.0"), 0o700)
      assert_mode(Path.join(writable, "hex-2.0.0/hex"), 0o600)

      assert :ok = Helpers.rm_fixture!(ro_handle)
      assert :ok = Helpers.rm_fixture!(rw_handle)
    after
      assert :ok = Helpers.rm_fixture!(source_handle)
    end
  end

  test "rejects source digest drift before copy" do
    {source_handle, digest} = write_hex_tree!()

    try do
      File.write!(Path.join(source_handle.root, "hex-2.0.0/forged"), "x")
      dest = dest!("drift")
      assert {:error, :hex_seed_digest_mismatch} =
               HexSeed.seed_tree(source_handle.root, dest, digest, :readonly)
    after
      assert :ok = Helpers.rm_fixture!(source_handle)
    end
  end

  test "verify_ancestry rejects symlink hops and accepts a real file chain" do
    root = Path.join(System.tmp_dir!(), "arbor-anc-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "bin"))
    handle = Helpers.capture_handle!(root)

    try do
      file = Path.join(root, "bin/mix")
      File.write!(file, "#!/bin/sh\n")
      File.chmod!(file, 0o755)
      {:ok, dir} = Identity.pin_directory(root)
      {:ok, leaf} = Identity.pin_regular_file(file)
      assert :ok = Identity.verify_ancestry(dir, leaf, ["bin", "mix"])

      File.rm!(file)
      File.ln_s!("/bin/sh", file)
      assert {:error, :symlink_rejected} = Identity.verify_ancestry(dir, leaf, ["bin", "mix"])
    after
      assert :ok = Helpers.rm_fixture!(handle)
    end
  end

  test "rejects destination mode drift after finalize" do
    {source_handle, digest} = write_hex_tree!()

    try do
      dest = dest!("finalize")
      assert {:ok, seeded} = HexSeed.seed_tree(source_handle.root, dest, digest, :readonly)
      File.chmod!(Path.join(dest, "hex-2.0.0/hex"), 0o644)
      assert {:ok, drifted} = Identity.tree_digest(dest)
      assert drifted != seeded
      dest_handle = Helpers.capture_handle!(dest)
      assert :ok = Helpers.rm_fixture!(dest_handle)
    after
      assert :ok = Helpers.rm_fixture!(source_handle)
    end
  end

  defp write_hex_tree! do
    root = Path.join(System.tmp_dir!(), "arbor-hex-src-#{System.unique_integer([:positive])}")
    pkg = Path.join(root, "hex-2.0.0")
    File.mkdir_p!(pkg)
    File.write!(Path.join(pkg, "hex"), "hex-archive-body\n")
    File.write!(Path.join(pkg, "VERSION"), "2.0.0\n")
    File.mkdir_p!(Path.join(pkg, "ebin"))
    File.write!(Path.join(pkg, "ebin/hex.app"), "{application,hex,[]}.\n")
    File.chmod!(pkg, 0o755)
    File.chmod!(Path.join(pkg, "hex"), 0o644)
    handle = Helpers.capture_handle!(root)
    {:ok, digest} = Identity.tree_digest(root)
    {handle, digest}
  end

  defp dest!(label) do
    Path.join(System.tmp_dir!(), "arbor-hex-#{label}-#{System.unique_integer([:positive])}")
  end

  defp assert_mode(path, expected) do
    import Bitwise
    {:ok, stat} = File.lstat(path)
    assert (stat.mode &&& 0o777) == expected
  end
end
