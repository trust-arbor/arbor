defmodule Arbor.Shell.TrustedPathAclSecurityRegressionTest do
  use ExUnit.Case, async: true

  alias Arbor.Shell.TrustedPath
  alias Arbor.Shell.TrustedPath.Identity

  @moduletag :fast

  describe "grant-write ACL fail-closed; deny-only stays trusted" do
    test "security regression: Darwin deny-only ACE stays trusted and grant-write ACE to another principal is untrusted" do
      {handle, harness} = compile_acl_classifier_harness!()

      try do
        {output, status} = System.cmd(harness, [], stderr_to_stdout: true)
        assert status == 0, output
        assert output == "ok\n"
      after
        File.rm_rf!(handle)
      end
    end

    test "security regression: POSIX named-user read ACL stays trusted when mode bits stay trusted" do
      {dir, _file} = operator_fixture("acl-access-read-755")
      File.chmod!(dir, 0o755)

      try do
        assert {:ok, %Identity{}} =
                 TrustedPath.pin_operator_owned_directory(dir, others: :no_write)

        apply_access_read_acl!(dir)
        assert_no_group_other_write!(dir)
        assert posix_named_user?(dir)

        assert {:ok, %Identity{}} =
                 TrustedPath.pin_operator_owned_directory(dir, others: :no_write)
      after
        File.rm_rf!(dir)
      end
    end

    test "security regression: launcher probe admits deny-equivalent read ACL and rejects grant-write default ACL" do
      {read_dir, _read_file} = operator_fixture("acl-probe-read")
      {write_dir, _write_file} = operator_fixture("acl-probe-write")
      File.chmod!(read_dir, 0o755)

      try do
        apply_access_read_acl!(read_dir)
        apply_default_write_acl!(write_dir)
        assert_no_group_other_write!(read_dir)
        assert_no_group_other_bits!(write_dir)

        launcher = acl_launcher!()

        {_out, read_status} =
          System.cmd(launcher, ["trusted-path-acl", read_dir], stderr_to_stdout: true)

        {_out, write_status} =
          System.cmd(launcher, ["trusted-path-acl", write_dir], stderr_to_stdout: true)

        {_out, clean_status} =
          System.cmd(launcher, ["trusted-path-acl", "/bin/ls"], stderr_to_stdout: true)

        assert clean_status == 0
        assert read_status == 0
        assert write_status == 1
      after
        File.rm_rf!(read_dir)
        File.rm_rf!(write_dir)
      end
    end

    test "security regression: default ACL write grant on a 0700 operator directory is untrusted" do
      {dir, _file} = operator_fixture("acl-default-dir")

      try do
        assert {:ok, %Identity{}} = TrustedPath.pin_operator_owned_directory(dir)
        assert_no_group_other_bits!(dir)

        apply_default_write_acl!(dir)
        assert_no_group_other_bits!(dir)
        assert posix_named_user?(dir)

        assert {:error, :untrusted_path} = TrustedPath.pin_operator_owned_directory(dir)
      after
        File.rm_rf!(dir)
      end
    end

    test "security regression: default ACL write grant on an ancestor rejects the operator file pin" do
      {dir, file} = operator_fixture("acl-ancestor-write")

      try do
        assert {:ok, %Identity{}} = TrustedPath.pin_operator_owned_regular_file(file)
        assert_no_group_other_bits!(dir)
        assert_no_group_other_bits!(file)

        apply_default_write_acl!(dir)
        assert_no_group_other_bits!(dir)
        assert posix_named_user?(dir)

        assert {:error, :untrusted_path} = TrustedPath.pin_operator_owned_regular_file(file)
      after
        File.rm_rf!(dir)
      end
    end

    test "security regression: deny-only / read-only default ACL on an ancestor stays trusted" do
      {dir, file} = operator_fixture("acl-ancestor-read")

      try do
        assert {:ok, %Identity{}} = TrustedPath.pin_operator_owned_regular_file(file)
        assert_no_group_other_bits!(dir)

        apply_default_read_acl!(dir)
        assert_no_group_other_bits!(dir)
        assert posix_named_user?(dir)

        assert {:ok, %Identity{}} = TrustedPath.pin_operator_owned_regular_file(file)
      after
        File.rm_rf!(dir)
      end
    end

    test "security regression: post-pin default write ACL fails verify_pinned" do
      {dir, _file} = operator_fixture("acl-verify")

      try do
        assert {:ok, identity} = TrustedPath.pin_operator_owned_directory(dir)
        assert :ok = TrustedPath.verify_pinned(identity)

        apply_default_write_acl!(dir)
        assert posix_named_user?(dir)
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

  defp apply_default_write_acl!(path) do
    {output, status} =
      System.cmd("setfacl", ["-d", "-m", "u:65534:rwx", path], stderr_to_stdout: true)

    assert status == 0, output
  end

  defp apply_default_read_acl!(path) do
    {output, status} =
      System.cmd("setfacl", ["-d", "-m", "u:65534:r", path], stderr_to_stdout: true)

    assert status == 0, output
  end

  defp apply_access_read_acl!(path) do
    {output, status} =
      System.cmd("setfacl", ["-m", "u:65534:r", path], stderr_to_stdout: true)

    assert status == 0, output
  end

  defp posix_named_user?(path) do
    {output, status} = System.cmd("getfacl", ["-p", "-c", path], stderr_to_stdout: true)
    assert status == 0, output

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

  defp acl_launcher! do
    priv = :code.priv_dir(:arbor_shell) |> List.to_string()
    launcher = Path.join(priv, "arbor_shell_launcher")
    assert File.regular?(launcher), launcher
    launcher
  end

  defp compile_acl_classifier_harness! do
    root = Path.join(System.tmp_dir!(), "arbor-acl-class-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    out = Path.join(root, "acl_classifier_harness")
    c_src = Path.expand("../../../c_src", __DIR__)
    harness = Path.join(root, "acl_classifier_harness.c")
    File.write!(harness, acl_classifier_harness_source())

    {output, status} =
      System.cmd(
        "cc",
        [
          "-std=c11",
          "-O2",
          "-Wall",
          "-Wextra",
          "-Werror",
          "-D_GNU_SOURCE",
          "-D_POSIX_C_SOURCE=200809L",
          "-I",
          c_src,
          harness,
          Path.join(c_src, "arbor_shell_trusted_path_acl.c"),
          "-o",
          out
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
    {root, out}
  end

  defp acl_classifier_harness_source do
    """
    #include "arbor_shell_trusted_path_acl.h"

    #include <stdio.h>
    #include <stdint.h>
    #include <string.h>

    static int expect_eq(int got, int want, const char *msg) {
      if (got != want) {
        fprintf(stderr, "%s: got %d want %d\\n", msg, got, want);
        return 1;
      }
      return 0;
    }

    static void put_le16(unsigned char *p, uint16_t v) {
      p[0] = (unsigned char)(v & 0xffu);
      p[1] = (unsigned char)((v >> 8) & 0xffu);
    }

    static void put_le32(unsigned char *p, uint32_t v) {
      p[0] = (unsigned char)(v & 0xffu);
      p[1] = (unsigned char)((v >> 8) & 0xffu);
      p[2] = (unsigned char)((v >> 16) & 0xffu);
      p[3] = (unsigned char)((v >> 24) & 0xffu);
    }

    static void put_entry(unsigned char *p, uint16_t tag, uint16_t perm, uint32_t id) {
      put_le16(p, tag);
      put_le16(p + 2, perm);
      put_le32(p + 4, id);
    }

    int main(void) {
      int rc = 0;
      unsigned char blob[4 + 8 * 5];
      uint32_t owner = 1000;

      /* macOS ~/Desktop: `0: group:everyone deny delete`
       * DELETE is not write/append/add_file/delete_child, and deny never untrusts. */
      rc |= expect_eq(arbor_acl_entry_untrusted(0, 0, 0, 12, 501), 0,
                      "darwin everyone deny delete");
      rc |= expect_eq(arbor_acl_entry_untrusted(0, 1, 0, 12, 501), 0,
                      "darwin deny delete_child still trusted");

      /* macOS grant write/append/add_file/delete_child to another principal. */
      rc |= expect_eq(arbor_acl_entry_untrusted(1, 1, 1, 502, 501), 1,
                      "darwin allow write other user");
      rc |= expect_eq(arbor_acl_entry_untrusted(1, 1, 0, 20, 501), 1,
                      "darwin allow write other group");
      rc |= expect_eq(arbor_acl_entry_untrusted(1, 1, 1, 501, 501), 0,
                      "darwin allow write owner");
      rc |= expect_eq(arbor_acl_entry_untrusted(1, 1, 1, 0, 501), 0,
                      "darwin allow write root");
      rc |= expect_eq(arbor_acl_entry_untrusted(1, 0, 1, 502, 501), 0,
                      "darwin allow read other user");

      /* POSIX v2 named-user WRITE, mode-equivalent bits 0700. */
      memset(blob, 0, sizeof(blob));
      put_le32(blob, 2);
      put_entry(blob + 4, 0x01, 0x07, 0xFFFFFFFFu);
      put_entry(blob + 12, 0x02, 0x02, 65534);
      put_entry(blob + 20, 0x04, 0x00, 0xFFFFFFFFu);
      put_entry(blob + 28, 0x10, 0x07, 0xFFFFFFFFu);
      put_entry(blob + 36, 0x20, 0x00, 0xFFFFFFFFu);
      rc |= expect_eq(arbor_posix_acl_blob_untrusted(blob, sizeof(blob), owner), 1,
                      "posix named-user write");

      /* POSIX v2 named-user READ only. */
      put_entry(blob + 12, 0x02, 0x04, 65534);
      rc |= expect_eq(arbor_posix_acl_blob_untrusted(blob, sizeof(blob), owner), 0,
                      "posix named-user read");

      /* POSIX named-user WRITE to the owner is trusted. */
      put_entry(blob + 12, 0x02, 0x02, owner);
      rc |= expect_eq(arbor_posix_acl_blob_untrusted(blob, sizeof(blob), owner), 0,
                      "posix named-user write owner");

      if (rc != 0) return 1;
      fputs("ok\\n", stdout);
      return 0;
    }
    """
  end
end
