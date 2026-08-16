defmodule Arbor.Shell.TrustedBuildHexSeedTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Shell.TrustedBuild.HexSeed
  alias Arbor.Shell.TrustedBuild.Identity

  test "copies a nonempty tree through temp modes then finalizes readonly and writable" do
    {source, digest} = write_hex_tree!()

    try do
      readonly = dest!("ro")
      writable = dest!("rw")

      assert {:ok, ro_digest} = HexSeed.seed_tree(source, readonly, digest, :readonly)
      assert {:ok, rw_digest} = HexSeed.seed_tree(source, writable, digest, :writable)

      assert {:ok, ^digest} = Identity.tree_digest(source)
      {:ok, source_content} = Identity.content_digest(source)
      assert {:ok, ^source_content} = Identity.content_digest(readonly)
      assert {:ok, ^source_content} = Identity.content_digest(writable)
      assert ro_digest != digest
      assert rw_digest != digest
      assert ro_digest != rw_digest

      assert_mode(readonly, 0o555)
      assert_mode(Path.join(readonly, "hex-2.0.0"), 0o555)
      assert_mode(Path.join(readonly, "hex-2.0.0/hex"), 0o444)
      assert_mode(writable, 0o700)
      assert_mode(Path.join(writable, "hex-2.0.0"), 0o700)
      assert_mode(Path.join(writable, "hex-2.0.0/hex"), 0o600)
    after
      File.rm_rf!(Path.dirname(source))
    end
  end

  test "rejects source digest drift before copy" do
    {source, digest} = write_hex_tree!()

    try do
      File.write!(Path.join(source, "hex-2.0.0/forged"), "x")
      dest = dest!("drift")
      assert {:error, :hex_seed_digest_mismatch} = HexSeed.seed_tree(source, dest, digest, :readonly)
    after
      File.rm_rf!(Path.dirname(source))
    end
  end

  test "verify_ancestry rejects symlink hops and accepts a real file chain" do
    root = Path.join(System.tmp_dir!(), "arbor-anc-#{System.unique_integer([:positive])}")

    try do
      File.mkdir_p!(Path.join(root, "bin"))
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
      File.rm_rf!(root)
    end
  end

  test "rejects destination mode drift after finalize" do
    {source, digest} = write_hex_tree!()

    try do
      dest = dest!("finalize")
      assert {:ok, seeded} = HexSeed.seed_tree(source, dest, digest, :readonly)
      File.chmod!(Path.join(dest, "hex-2.0.0/hex"), 0o644)
      assert {:ok, drifted} = Identity.tree_digest(dest)
      assert drifted != seeded
    after
      File.rm_rf!(Path.dirname(source))
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
    {:ok, digest} = Identity.tree_digest(root)
    {root, digest}
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
