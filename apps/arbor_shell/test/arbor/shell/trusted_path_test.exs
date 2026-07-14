defmodule Arbor.Shell.TrustedPathTest do
  use ExUnit.Case, async: true

  alias Arbor.Shell.TrustedPath
  alias Arbor.Shell.TrustedPath.Identity

  @moduletag :fast

  describe "pin_root_owned_regular_file/2" do
    test "pins a root-owned system executable with digest and metadata" do
      path = first_existing_file(["/bin/ls", "/usr/bin/true", "/bin/cat"])

      assert {:ok, %Identity{} = identity} =
               TrustedPath.pin_root_owned_regular_file(path, executable: true)

      assert identity.path == expected_canonical(path)
      assert identity.type == :regular
      assert is_integer(identity.device)
      assert is_integer(identity.inode)
      assert identity.size > 0
      assert is_integer(identity.mtime)
      assert is_integer(identity.ctime)
      assert is_integer(identity.mode)
      assert identity.uid == 0
      assert is_integer(identity.gid)
      assert identity.sha256 =~ ~r/\A[0-9a-f]{64}\z/
      assert identity.executable_required

      {:ok, %File.Stat{} = stat} = File.stat(identity.path, time: :posix)
      assert identity.device == stat.major_device
      assert identity.inode == stat.inode
      assert identity.size == stat.size
      assert identity.mode == stat.mode
      assert identity.uid == stat.uid
      assert identity.gid == stat.gid

      {:ok, contents} = File.read(identity.path)

      expected_digest =
        :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)

      assert identity.sha256 == expected_digest
    end

    test "pins a root-owned regular non-executable when executable is not required" do
      # Prefer a small root-owned data file when present; otherwise fall back to
      # a known system binary and only assert the non-executable pin path works.
      path =
        first_existing_file([
          "/etc/hosts",
          "/etc/passwd",
          "/usr/share/dict/words",
          "/bin/ls"
        ])

      assert {:ok, %Identity{} = identity} =
               TrustedPath.pin_root_owned_regular_file(path)

      assert identity.type == :regular
      assert identity.executable_required == false
      assert identity.sha256 =~ ~r/\A[0-9a-f]{64}\z/
      assert identity.uid == 0
    end

    test "rejects user-owned temporary regular files" do
      root = tmp_root("file")
      path = Path.join(root, "tool")
      File.mkdir_p!(root)
      File.write!(path, "#!/bin/sh\necho hi\n")
      File.chmod!(path, 0o755)

      try do
        assert {:error, reason} =
                 TrustedPath.pin_root_owned_regular_file(path, executable: true)

        assert reason in [:untrusted_path, :path_not_found]
        refute is_tuple(reason)
        refute is_binary(reason)
      after
        File.rm_rf!(root)
      end
    end

    test "rejects relative, NUL, and nonexistent paths with bounded atoms" do
      assert {:error, :relative_path} =
               TrustedPath.pin_root_owned_regular_file("bin/ls", executable: true)

      assert {:error, :invalid_path} =
               TrustedPath.pin_root_owned_regular_file("/bin/ls\0evil", executable: true)

      assert {:error, :path_not_found} =
               TrustedPath.pin_root_owned_regular_file(
                 "/tmp/arbor-trusted-path-missing-#{System.unique_integer([:positive])}",
                 executable: true
               )
    end

    test "closed options reject unknown, duplicate, and malformed values" do
      path = first_existing_file(["/bin/ls", "/usr/bin/true"])

      assert {:error, :unknown_option} =
               TrustedPath.pin_root_owned_regular_file(path, unknown: true)

      # Explicit list preserves duplicate keys; trailing keyword syntax collapses them.
      assert {:error, :duplicate_option} =
               TrustedPath.pin_root_owned_regular_file(path, [
                 {:executable, true},
                 {:executable, false}
               ])

      assert {:error, :malformed_options} =
               TrustedPath.pin_root_owned_regular_file(path, executable: "yes")

      assert {:error, :malformed_options} =
               TrustedPath.pin_root_owned_regular_file(path, [{"executable", true}])
    end
  end

  describe "pin_root_owned_directory/1" do
    test "pins a root-owned system directory without a digest" do
      path = first_existing_dir(["/bin", "/usr/bin", "/usr"])

      assert {:ok, %Identity{} = identity} = TrustedPath.pin_root_owned_directory(path)

      assert identity.path == expected_canonical(path)
      assert identity.type == :directory
      assert is_nil(identity.sha256)
      assert identity.executable_required == false
      assert identity.uid == 0
      assert Bitwise.band(identity.mode, 0o022) == 0
    end

    test "rejects writable user-owned temporary directories" do
      root = tmp_root("dir")
      File.mkdir_p!(root)

      try do
        assert {:error, reason} = TrustedPath.pin_root_owned_directory(root)
        assert reason in [:untrusted_path, :path_not_found]
        refute is_tuple(reason)
      after
        File.rm_rf!(root)
      end
    end

    test "rejects relative and nonexistent directories" do
      assert {:error, :relative_path} = TrustedPath.pin_root_owned_directory("usr/bin")

      assert {:error, :path_not_found} =
               TrustedPath.pin_root_owned_directory(
                 "/tmp/arbor-trusted-path-missing-dir-#{System.unique_integer([:positive])}"
               )
    end
  end

  describe "canonicalize_absolute/1" do
    test "returns a canonical absolute path for an existing system path" do
      path = first_existing_file(["/bin/ls", "/usr/bin/true"])
      assert {:ok, canonical} = TrustedPath.canonicalize_absolute(path)
      assert Path.type(canonical) == :absolute
      assert canonical == expected_canonical(path)
    end

    test "follows portable directory symlinks such as /tmp when present" do
      case File.lstat("/tmp") do
        {:ok, %File.Stat{type: :symlink}} ->
          assert {:ok, canonical} = TrustedPath.canonicalize_absolute("/tmp")
          assert Path.type(canonical) == :absolute
          assert canonical != "/tmp" or File.lstat!(canonical).type == :directory
          assert {:ok, %File.Stat{type: :directory}} = File.stat(canonical)

        _other ->
          # Platforms without a /tmp symlink still exercise absolute rejection.
          assert {:error, :relative_path} = TrustedPath.canonicalize_absolute("tmp")
      end
    end

    test "rejects relative, NUL, and nonexistent inputs" do
      assert {:error, :relative_path} = TrustedPath.canonicalize_absolute("bin/ls")
      assert {:error, :invalid_path} = TrustedPath.canonicalize_absolute("/bin/\0ls")

      assert {:error, :path_not_found} =
               TrustedPath.canonicalize_absolute(
                 "/tmp/arbor-trusted-path-missing-canon-#{System.unique_integer([:positive])}"
               )
    end
  end

  describe "verify_pinned/1 and same_identity?/2" do
    test "verify succeeds for a freshly pinned system file and directory" do
      file_path = first_existing_file(["/bin/ls", "/usr/bin/true"])
      dir_path = first_existing_dir(["/bin", "/usr/bin"])

      assert {:ok, file_identity} =
               TrustedPath.pin_root_owned_regular_file(file_path, executable: true)

      assert {:ok, dir_identity} = TrustedPath.pin_root_owned_directory(dir_path)

      assert :ok = TrustedPath.verify_pinned(file_identity)
      assert :ok = TrustedPath.verify_pinned(dir_identity)
      assert TrustedPath.same_identity?(file_identity, file_identity)
      assert TrustedPath.same_identity?(dir_identity, dir_identity)
      refute TrustedPath.same_identity?(file_identity, dir_identity)
    end

    test "same_identity? is false when metadata differs" do
      path = first_existing_file(["/bin/ls", "/usr/bin/true"])
      assert {:ok, identity} = TrustedPath.pin_root_owned_regular_file(path, executable: true)

      altered = %{identity | size: identity.size + 1}
      refute TrustedPath.same_identity?(identity, altered)
      assert {:error, :identity_mismatch} = TrustedPath.verify_pinned(altered)
    end
  end

  describe "bounded errors" do
    test "public errors are atoms and never embed path strings" do
      errors = [
        TrustedPath.canonicalize_absolute("relative"),
        TrustedPath.canonicalize_absolute("/no/such/#{System.unique_integer([:positive])}"),
        TrustedPath.pin_root_owned_regular_file("relative", executable: true),
        TrustedPath.pin_root_owned_directory(tmp_root("err")),
        TrustedPath.pin_root_owned_regular_file("/bin/ls", unknown: 1)
      ]

      Enum.each(errors, fn
        {:error, reason} ->
          assert is_atom(reason)
          refute is_binary(reason)
          refute is_tuple(reason)

        other ->
          flunk("expected bounded error, got: #{inspect(other)}")
      end)
    end
  end

  defp first_existing_file(paths) do
    Enum.find(paths, &File.regular?/1) ||
      flunk("no suitable system file among #{inspect(paths)}")
  end

  defp first_existing_dir(paths) do
    Enum.find(paths, &File.dir?/1) ||
      flunk("no suitable system directory among #{inspect(paths)}")
  end

  defp expected_canonical(path) do
    assert {:ok, canonical} = TrustedPath.canonicalize_absolute(path)
    canonical
  end

  defp tmp_root(tag) do
    Path.join(
      System.tmp_dir!(),
      "arbor_trusted_path_#{tag}_#{System.unique_integer([:positive])}"
    )
  end
end
