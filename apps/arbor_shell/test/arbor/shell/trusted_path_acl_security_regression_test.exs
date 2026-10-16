defmodule Arbor.Shell.TrustedPathAclSecurityRegressionTest do
  use ExUnit.Case, async: true

  alias Arbor.Shell.TrustedPath
  alias Arbor.Shell.TrustedPath.Identity

  @moduletag :fast

  describe "POSIX ACL fail-closed" do
    test "security regression: default ACL on a 0700 operator directory is untrusted" do
      {dir, _file} = operator_fixture("acl-default-dir")

      try do
        assert {:ok, %Identity{}} = TrustedPath.pin_operator_owned_directory(dir)
        assert_no_group_other_bits!(dir)

        apply_default_acl!(dir)
        assert_no_group_other_bits!(dir)
        assert posix_acl_xattr?(dir)

        assert {:error, :untrusted_path} = TrustedPath.pin_operator_owned_directory(dir)
      after
        File.rm_rf!(dir)
      end
    end

    test "security regression: access ACL on a 0755 operator directory is untrusted even with others: :no_write" do
      {dir, _file} = operator_fixture("acl-access-755")
      File.chmod!(dir, 0o755)

      try do
        assert {:ok, %Identity{}} =
                 TrustedPath.pin_operator_owned_directory(dir, others: :no_write)

        apply_access_acl!(dir)
        assert_no_group_other_write!(dir)
        assert posix_acl_xattr?(dir)

        assert {:error, :untrusted_path} =
                 TrustedPath.pin_operator_owned_directory(dir, others: :no_write)
      after
        File.rm_rf!(dir)
      end
    end

    test "security regression: default ACL on an ancestor rejects the operator file pin" do
      {dir, file} = operator_fixture("acl-ancestor")

      try do
        assert {:ok, %Identity{}} = TrustedPath.pin_operator_owned_regular_file(file)
        assert_no_group_other_bits!(dir)
        assert_no_group_other_bits!(file)

        apply_default_acl!(dir)
        assert_no_group_other_bits!(dir)
        assert posix_acl_xattr?(dir)

        assert {:error, :untrusted_path} = TrustedPath.pin_operator_owned_regular_file(file)
      after
        File.rm_rf!(dir)
      end
    end

    test "security regression: post-pin default ACL fails verify_pinned" do
      {dir, _file} = operator_fixture("acl-verify")

      try do
        assert {:ok, identity} = TrustedPath.pin_operator_owned_directory(dir)
        assert :ok = TrustedPath.verify_pinned(identity)

        apply_default_acl!(dir)
        assert posix_acl_xattr?(dir)
        assert {:error, :untrusted_path} = TrustedPath.verify_pinned(identity)
      after
        File.rm_rf!(dir)
      end
    end
  end

  defp operator_fixture(tag) do
    raw =
      Path.join(
        System.tmp_dir!(),
        "arbor_trusted_path_acl_#{tag}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(raw)
    {:ok, dir} = TrustedPath.canonicalize_absolute(raw)
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    file = Path.join(dir, "validation-runtime.json")
    File.write!(file, "{\"runtime\":\"oci\"}\n")
    File.chmod!(file, 0o400)
    {:ok, canonical_file} = TrustedPath.canonicalize_absolute(file)
    {dir, canonical_file}
  end

  defp apply_default_acl!(path) do
    {output, status} =
      System.cmd("setfacl", ["-d", "-m", "u:65534:rwx", path], stderr_to_stdout: true)

    assert status == 0, output
  end

  defp apply_access_acl!(path) do
    {output, status} =
      System.cmd("setfacl", ["-m", "u:65534:r", path], stderr_to_stdout: true)

    assert status == 0, output
  end

  defp posix_acl_xattr?(path) do
    {output, status} = System.cmd("getfacl", ["-p", "-c", path], stderr_to_stdout: true)
    assert status == 0, output

    # Named-user entries (not the owner `user::` mapping) prove an ACL exists
    # even when traditional mode bits stay trusted.
    Regex.match?(~r/(^|\n)(default:)?user:[^:\n]+:/u, output)
  end

  defp assert_no_group_other_bits!(path) do
    {:ok, %File.Stat{mode: mode}} = File.stat(path, time: :posix)
    assert Bitwise.band(mode, 0o077) == 0
  end

  defp assert_no_group_other_write!(path) do
    {:ok, %File.Stat{mode: mode}} = File.stat(path, time: :posix)
    assert Bitwise.band(mode, 0o022) == 0
  end
end
