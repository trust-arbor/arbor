defmodule Arbor.Common.Sanitizers.PathTraversalTest do
  use ExUnit.Case, async: true

  alias Arbor.Common.Sanitizers.PathTraversal
  alias Arbor.Contracts.Security.Taint

  @bit 0b00001000

  describe "sanitize/3" do
    test "clean relative path resolves within root" do
      taint = %Taint{level: :untrusted}

      {:ok, resolved, updated} =
        PathTraversal.sanitize("subdir/file.txt", taint, allowed_root: "/workspace")

      assert resolved == "/workspace/subdir/file.txt"
      assert Bitwise.band(updated.sanitizations, @bit) == @bit
    end

    test "rejects traversal beyond root" do
      taint = %Taint{}

      assert {:error, {:path_traversal, _}} =
               PathTraversal.sanitize("../../../etc/passwd", taint, allowed_root: "/workspace")
    end

    test "requires allowed_root option" do
      taint = %Taint{}

      assert {:error, {:missing_option, :allowed_root}} =
               PathTraversal.sanitize("file.txt", taint, [])
    end

    test "preserves existing sanitization bits" do
      taint = %Taint{sanitizations: 0b00000001}

      {:ok, _, updated} =
        PathTraversal.sanitize("file.txt", taint, allowed_root: "/workspace")

      assert Bitwise.band(updated.sanitizations, 0b00000001) == 0b00000001
      assert Bitwise.band(updated.sanitizations, @bit) == @bit
    end

    test "handles absolute path within root" do
      taint = %Taint{}

      {:ok, resolved, _} =
        PathTraversal.sanitize("/workspace/file.txt", taint, allowed_root: "/workspace")

      assert resolved == "/workspace/file.txt"
    end

    test "preserves other taint fields" do
      taint = %Taint{level: :hostile, sensitivity: :restricted}

      {:ok, _, updated} =
        PathTraversal.sanitize("file.txt", taint, allowed_root: "/workspace")

      assert updated.level == :hostile
      assert updated.sensitivity == :restricted
    end
  end

  describe "detect/1" do
    test "clean path is safe" do
      assert {:safe, 1.0} = PathTraversal.detect("subdir/file.txt")
    end

    test "detects dot-dot traversal" do
      {:unsafe, patterns} = PathTraversal.detect("../../../etc/passwd")
      assert "dot_dot_traversal" in patterns
    end

    test "detects null bytes" do
      {:unsafe, patterns} = PathTraversal.detect("file.txt\x00.jpg")
      assert "null_byte" in patterns
    end

    test "detects Windows separators" do
      {:unsafe, patterns} = PathTraversal.detect("..\\..\\windows\\system32")
      assert "windows_separator" in patterns
    end

    test "detects URL-encoded traversal" do
      {:unsafe, patterns} = PathTraversal.detect("%2e%2e/%2e%2e/etc/passwd")
      assert "url_encoded_traversal" in patterns
    end

    test "detects double-encoded traversal" do
      {:unsafe, patterns} = PathTraversal.detect("%252e%252e/etc/passwd")
      assert "double_encoded_traversal" in patterns
    end

    test "detects encoded forward slash" do
      {:unsafe, patterns} = PathTraversal.detect("..%2f..%2fetc%2fpasswd")
      assert "encoded_forward_slash" in patterns
    end

    test "detects encoded backslash" do
      {:unsafe, patterns} = PathTraversal.detect("..%5c..%5cwindows")
      assert "encoded_backslash" in patterns
    end

    test "detects home directory reference" do
      {:unsafe, patterns} = PathTraversal.detect("~/secret_file")
      assert "home_dir_reference" in patterns
    end

    test "non-string returns safe" do
      assert {:safe, 1.0} = PathTraversal.detect(42)
    end
  end
end
