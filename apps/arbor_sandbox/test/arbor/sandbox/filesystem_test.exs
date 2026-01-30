defmodule Arbor.Sandbox.FilesystemTest do
  use ExUnit.Case, async: true

  alias Arbor.Sandbox.Filesystem

  setup do
    base_path =
      Path.join(
        System.tmp_dir!(),
        "arbor_sandbox_test_#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(base_path)
    File.mkdir_p!(base_path)

    on_exit(fn ->
      File.rm_rf(base_path)
    end)

    {:ok, base_path: base_path}
  end

  describe "create/3" do
    test "creates a filesystem sandbox", %{base_path: base_path} do
      assert {:ok, fs} = Filesystem.create("agent_test_1", :limited, base_path: base_path)
      assert fs.agent_id == "agent_test_1"
      assert fs.level == :limited
      assert String.starts_with?(fs.base_path, base_path)
    end

    test "sanitizes agent_id", %{base_path: base_path} do
      assert {:ok, fs} = Filesystem.create("agent/../evil", :limited, base_path: base_path)
      refute String.contains?(fs.base_path, "..")
    end

    test "creates the directory", %{base_path: base_path} do
      {:ok, fs} = Filesystem.create("agent_test_2", :limited, base_path: base_path)
      assert File.dir?(fs.base_path)
    end
  end

  describe "check/4" do
    test "allows read operations in pure mode", %{base_path: base_path} do
      {:ok, fs} = Filesystem.create("agent_test_3", :pure, base_path: base_path)
      assert :ok = Filesystem.check(fs, "/file.txt", :read, :pure)
    end

    test "blocks write operations in pure mode", %{base_path: base_path} do
      {:ok, fs} = Filesystem.create("agent_test_4", :pure, base_path: base_path)

      assert {:error, :write_not_allowed_in_pure_mode} =
               Filesystem.check(fs, "/file.txt", :write, :pure)
    end

    test "allows write operations in limited mode", %{base_path: base_path} do
      {:ok, fs} = Filesystem.create("agent_test_5", :limited, base_path: base_path)
      assert :ok = Filesystem.check(fs, "/file.txt", :write, :limited)
    end

    test "returns error for nil filesystem" do
      assert {:error, :no_filesystem_sandbox} =
               Filesystem.check(nil, "/file.txt", :read, :limited)
    end
  end

  describe "resolve_path/2" do
    test "resolves relative paths", %{base_path: base_path} do
      {:ok, fs} = Filesystem.create("agent_test_6", :limited, base_path: base_path)
      assert {:ok, path} = Filesystem.resolve_path(fs, "/subdir/file.txt")
      assert String.starts_with?(path, fs.base_path)
      assert String.ends_with?(path, "/subdir/file.txt")
    end

    test "blocks path traversal attacks", %{base_path: base_path} do
      {:ok, fs} = Filesystem.create("agent_test_7", :limited, base_path: base_path)

      assert {:error, :path_traversal_blocked} =
               Filesystem.resolve_path(fs, "/../../../etc/passwd")
    end

    test "handles leading slash", %{base_path: base_path} do
      {:ok, fs} = Filesystem.create("agent_test_8", :limited, base_path: base_path)
      {:ok, path1} = Filesystem.resolve_path(fs, "/file.txt")
      {:ok, path2} = Filesystem.resolve_path(fs, "file.txt")
      assert path1 == path2
    end

    test "returns error for nil filesystem" do
      assert {:error, :no_filesystem_sandbox} = Filesystem.resolve_path(nil, "/file.txt")
    end
  end

  describe "list_files/2" do
    test "lists files in sandbox", %{base_path: base_path} do
      {:ok, fs} = Filesystem.create("agent_test_9", :limited, base_path: base_path)
      File.write!(Path.join(fs.base_path, "test.txt"), "content")

      assert {:ok, files} = Filesystem.list_files(fs)
      assert "test.txt" in files
    end
  end

  describe "exists?/2" do
    test "returns true for existing files", %{base_path: base_path} do
      {:ok, fs} = Filesystem.create("agent_test_10", :limited, base_path: base_path)
      File.write!(Path.join(fs.base_path, "exists.txt"), "content")

      assert Filesystem.exists?(fs, "/exists.txt")
    end

    test "returns false for nonexistent files", %{base_path: base_path} do
      {:ok, fs} = Filesystem.create("agent_test_11", :limited, base_path: base_path)
      refute Filesystem.exists?(fs, "/nonexistent.txt")
    end
  end

  describe "cleanup/1" do
    test "handles nil gracefully" do
      assert :ok = Filesystem.cleanup(nil)
    end

    test "returns ok for valid filesystem", %{base_path: base_path} do
      {:ok, fs} = Filesystem.create("agent_test_12", :limited, base_path: base_path)
      assert :ok = Filesystem.cleanup(fs)
    end
  end
end
