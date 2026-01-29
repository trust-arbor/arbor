defmodule Arbor.Common.SafePathTest do
  use ExUnit.Case, async: true

  alias Arbor.Common.SafePath

  @moduletag :fast

  describe "validate/1" do
    test "accepts normal paths" do
      assert :ok = SafePath.validate("file.txt")
      assert :ok = SafePath.validate("subdir/file.txt")
      assert :ok = SafePath.validate("deep/nested/path/file.txt")
      assert :ok = SafePath.validate("/absolute/path/file.txt")
    end

    test "rejects empty paths" do
      assert {:error, :empty_path} = SafePath.validate("")
    end

    test "allows literal .. (security enforced by resolve_within)" do
      # validate/1 allows literal ".." - the actual security check is in
      # resolve_within/2 which verifies resolved paths stay within bounds
      assert :ok = SafePath.validate("..")
      assert :ok = SafePath.validate("../file.txt")
      assert :ok = SafePath.validate("subdir/../file.txt")
      assert :ok = SafePath.validate("subdir/../../etc/passwd")
    end

    test "rejects URL-encoded traversal sequences" do
      assert {:error, :traversal_sequence} = SafePath.validate("%2e%2e/etc/passwd")
      assert {:error, :traversal_sequence} = SafePath.validate("%2E%2E/etc/passwd")
      assert {:error, :traversal_sequence} = SafePath.validate("subdir/%2e%2e/etc/passwd")
    end

    test "rejects paths with null bytes" do
      assert {:error, :null_byte} = SafePath.validate("file.txt\x00.jpg")
      assert {:error, :null_byte} = SafePath.validate("path/to\x00/file")
    end

    test "accepts paths with dots that aren't traversal" do
      assert :ok = SafePath.validate("file.txt")
      assert :ok = SafePath.validate(".hidden")
      assert :ok = SafePath.validate("path/.config")
      assert :ok = SafePath.validate("file.name.with.dots.txt")
    end
  end

  describe "validate!/1" do
    test "returns :ok for valid paths" do
      assert :ok = SafePath.validate!("safe/path/file.txt")
    end

    test "raises TraversalError for encoded traversal" do
      assert_raise SafePath.TraversalError, ~r/traversal/i, fn ->
        SafePath.validate!("%2e%2e/evil")
      end
    end

    test "raises TraversalError for null bytes" do
      assert_raise SafePath.TraversalError, ~r/null/i, fn ->
        SafePath.validate!("file\x00.txt")
      end
    end
  end

  describe "within?/2" do
    test "returns true for paths within root" do
      assert SafePath.within?("/workspace/file.txt", "/workspace")
      assert SafePath.within?("/workspace/subdir/file.txt", "/workspace")
      assert SafePath.within?("/workspace/deep/nested/path.txt", "/workspace")
    end

    test "returns false for paths outside root" do
      refute SafePath.within?("/etc/passwd", "/workspace")
      refute SafePath.within?("/workspace/../etc/passwd", "/workspace")
      refute SafePath.within?("/other/path", "/workspace")
    end

    test "handles relative paths against root" do
      # Relative paths are resolved relative to root
      assert SafePath.within?("file.txt", "/workspace")
      assert SafePath.within?("subdir/file.txt", "/workspace")
    end

    test "rejects relative path traversal escapes" do
      refute SafePath.within?("../etc/passwd", "/workspace")
      refute SafePath.within?("subdir/../../etc/passwd", "/workspace")
    end

    test "handles root path exactly" do
      assert SafePath.within?("/workspace", "/workspace")
    end

    test "rejects paths that are prefixes but not children" do
      # /workspace2 is not within /workspace even though it starts with /workspace
      refute SafePath.within?("/workspace2/file.txt", "/workspace")
    end
  end

  describe "resolve_within/2" do
    test "returns resolved path for valid paths" do
      assert {:ok, "/workspace/file.txt"} = SafePath.resolve_within("file.txt", "/workspace")

      assert {:ok, "/workspace/subdir/file.txt"} =
               SafePath.resolve_within("subdir/file.txt", "/workspace")
    end

    test "resolves . and .. within bounds" do
      assert {:ok, "/workspace/file.txt"} = SafePath.resolve_within("./file.txt", "/workspace")

      assert {:ok, "/workspace/file.txt"} =
               SafePath.resolve_within("subdir/../file.txt", "/workspace")
    end

    test "returns error for escaping paths" do
      assert {:error, :path_traversal} = SafePath.resolve_within("../etc/passwd", "/workspace")
      # This one escapes: a/b/c + 4 levels up goes above /workspace
      assert {:error, :path_traversal} =
               SafePath.resolve_within("a/b/c/../../../../etc/passwd", "/workspace")
    end

    test "allows .. that stays within bounds" do
      # a/b/c + 3 levels up = /workspace, then /etc/passwd = /workspace/etc/passwd (within bounds)
      assert {:ok, "/workspace/etc/passwd"} =
               SafePath.resolve_within("a/b/c/../../../etc/passwd", "/workspace")
    end
  end

  describe "safe_join/2" do
    test "joins paths safely" do
      assert {:ok, "/workspace/file.txt"} = SafePath.safe_join("/workspace", "file.txt")

      assert {:ok, "/workspace/subdir/file.txt"} =
               SafePath.safe_join("/workspace", "subdir/file.txt")
    end

    test "rejects traversal attempts" do
      assert {:error, :path_traversal} = SafePath.safe_join("/workspace", "../etc/passwd")

      assert {:error, :path_traversal} =
               SafePath.safe_join("/workspace", "subdir/../../etc/passwd")
    end

    test "rejects absolute user paths" do
      assert {:error, :path_traversal} = SafePath.safe_join("/workspace", "/etc/passwd")
      assert {:error, :path_traversal} = SafePath.safe_join("/workspace", "/absolute/path")
    end
  end

  describe "safe_join!/2" do
    test "returns path for valid joins" do
      assert "/workspace/file.txt" = SafePath.safe_join!("/workspace", "file.txt")
    end

    test "raises for invalid joins" do
      assert_raise SafePath.TraversalError, fn ->
        SafePath.safe_join!("/workspace", "../escape")
      end
    end
  end

  describe "normalize/1" do
    test "resolves . components" do
      assert "/workspace/file.txt" = SafePath.normalize("/workspace/./file.txt")
      assert "/workspace/file.txt" = SafePath.normalize("/workspace/./subdir/../file.txt")
    end

    test "resolves .. components" do
      assert "/workspace/file.txt" = SafePath.normalize("/workspace/subdir/../file.txt")
      assert "/file.txt" = SafePath.normalize("/workspace/../file.txt")
    end

    test "handles multiple consecutive separators" do
      normalized = SafePath.normalize("/workspace//subdir///file.txt")
      assert String.contains?(normalized, "workspace")
      assert String.contains?(normalized, "file.txt")
    end
  end

  describe "absolute?/1 and relative?/1" do
    test "correctly identifies absolute paths" do
      assert SafePath.absolute?("/absolute/path")
      assert SafePath.absolute?("/")
      refute SafePath.absolute?("relative/path")
      refute SafePath.absolute?("./relative")
    end

    test "correctly identifies relative paths" do
      assert SafePath.relative?("relative/path")
      assert SafePath.relative?("./relative")
      assert SafePath.relative?("file.txt")
      refute SafePath.relative?("/absolute/path")
    end
  end

  describe "safe_basename/1" do
    test "extracts safe basenames" do
      assert {:ok, "file.txt"} = SafePath.safe_basename("/path/to/file.txt")
      assert {:ok, "file.txt"} = SafePath.safe_basename("file.txt")
      assert {:ok, "file"} = SafePath.safe_basename("/path/to/file")
    end

    test "rejects traversal in basename" do
      assert {:error, :traversal_sequence} = SafePath.safe_basename("/path/to/..")
      assert {:error, :traversal_sequence} = SafePath.safe_basename("..")
    end

    test "handles trailing slashes" do
      # Path.basename strips trailing slash, so "/path/to/" becomes "to"
      assert {:ok, "to"} = SafePath.safe_basename("/path/to/")
    end

    test "rejects root path" do
      assert {:error, :empty_path} = SafePath.safe_basename("/")
    end
  end

  describe "sanitize_filename/1" do
    test "keeps safe filenames unchanged" do
      assert "file.txt" = SafePath.sanitize_filename("file.txt")
      assert "my-file_name.txt" = SafePath.sanitize_filename("my-file_name.txt")
    end

    test "removes path separators" do
      assert "etc_passwd" = SafePath.sanitize_filename("etc/passwd")
      assert "etc_passwd" = SafePath.sanitize_filename("etc\\passwd")
    end

    test "removes leading dots" do
      assert "hidden" = SafePath.sanitize_filename("..hidden")
      assert "file.txt" = SafePath.sanitize_filename("...file.txt")
    end

    test "removes traversal sequences" do
      result = SafePath.sanitize_filename("../../../etc/passwd")
      refute String.contains?(result, "..")
      refute String.contains?(result, "/")
    end

    test "removes null bytes" do
      result = SafePath.sanitize_filename("file\x00.txt")
      refute String.contains?(result, <<0>>)
    end

    test "returns 'unnamed' for completely invalid input" do
      assert "unnamed" = SafePath.sanitize_filename("..")
      assert "unnamed" = SafePath.sanitize_filename("...")
      assert "unnamed" = SafePath.sanitize_filename("/")
    end

    test "respects max_length option" do
      long_name = String.duplicate("a", 300)
      result = SafePath.sanitize_filename(long_name, max_length: 100)
      assert String.length(result) == 100
    end

    test "uses custom replacement character" do
      assert "etc-passwd" = SafePath.sanitize_filename("etc/passwd", replacement: "-")
    end
  end

  describe "resolve_real/1" do
    @tag :tmp_dir
    test "resolves existing paths", %{tmp_dir: tmp_dir} do
      # Create a test file
      test_file = Path.join(tmp_dir, "test.txt")
      File.write!(test_file, "test")

      assert {:ok, resolved} = SafePath.resolve_real(test_file)
      assert String.ends_with?(resolved, "test.txt")
    end

    test "returns error for non-existent paths" do
      assert {:error, :not_found} = SafePath.resolve_real("/definitely/does/not/exist/12345")
    end

    @tag :tmp_dir
    test "follows symlinks", %{tmp_dir: tmp_dir} do
      # Create a file and a symlink to it
      real_file = Path.join(tmp_dir, "real.txt")
      link_file = Path.join(tmp_dir, "link.txt")

      File.write!(real_file, "test")
      File.ln_s!(real_file, link_file)

      assert {:ok, resolved} = SafePath.resolve_real(link_file)
      assert String.ends_with?(resolved, "real.txt")
    end
  end

  describe "TraversalError" do
    test "has meaningful messages" do
      error = %SafePath.TraversalError{reason: :path_traversal}
      assert Exception.message(error) =~ "traversal"

      error = %SafePath.TraversalError{reason: :null_byte}
      assert Exception.message(error) =~ "null"
    end
  end
end
