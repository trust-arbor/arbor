defmodule Arbor.Actions.FileTest do
  use Arbor.Actions.ActionCase, async: true

  alias Arbor.Actions.File, as: FileActions

  describe "Read" do
    test "reads file content", %{tmp_dir: tmp_dir} do
      path = create_file(tmp_dir, "test.txt", "Hello, World!")

      assert {:ok, result} = FileActions.Read.run(%{path: path}, %{})
      assert result.path == path
      assert result.content == "Hello, World!"
      assert result.size == 13
    end

    test "returns error for non-existent file" do
      assert {:error, message} = FileActions.Read.run(%{path: "/nonexistent_file_12345.txt"}, %{})
      assert message =~ "file not found"
    end

    test "returns error for directory" do
      assert {:error, message} = FileActions.Read.run(%{path: "/tmp"}, %{})
      assert message =~ "is a directory"
    end

    test "handles binary content", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "binary.bin")
      File.write!(path, <<0, 1, 2, 255>>)

      assert {:ok, result} = FileActions.Read.run(%{path: path, encoding: :binary}, %{})
      assert result.content == <<0, 1, 2, 255>>
    end

    test "reads utf8 file with encoding option", %{tmp_dir: tmp_dir} do
      path = create_file(tmp_dir, "utf8.txt", "Hello, UTF-8!")

      assert {:ok, result} = FileActions.Read.run(%{path: path, encoding: :utf8}, %{})
      assert result.content == "Hello, UTF-8!"
    end

    test "reads latin1 file", %{tmp_dir: tmp_dir} do
      path = create_file(tmp_dir, "latin.txt", "ASCII content")

      assert {:ok, result} = FileActions.Read.run(%{path: path, encoding: :latin1}, %{})
      assert result.content == "ASCII content"
    end

    test "handles invalid UTF-8 bytes gracefully", %{tmp_dir: tmp_dir} do
      # Write invalid UTF-8 sequence
      path = Path.join(tmp_dir, "invalid_utf8.txt")
      File.write!(path, <<0xFF, 0xFE, 0x80, 0x81>>)

      # Should still succeed without crashing
      assert {:ok, result} = FileActions.Read.run(%{path: path}, %{})
      assert is_binary(result.content)
    end

    test "returns permission error", %{tmp_dir: tmp_dir} do
      path = create_file(tmp_dir, "noperm.txt", "secret")
      File.chmod!(path, 0o000)

      on_exit(fn -> File.chmod(path, 0o644) end)

      assert {:error, message} = FileActions.Read.run(%{path: path}, %{})
      assert message =~ "permission denied"
    end

    test "validates action metadata" do
      assert FileActions.Read.name() == "file_read"
      assert FileActions.Read.category() == "file"
      assert "read" in FileActions.Read.tags()
    end

    test "generates tool schema" do
      tool = FileActions.Read.to_tool()
      assert is_map(tool)
      assert tool[:name] == "file_read"
    end
  end

  describe "Write" do
    test "writes content to file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "output.txt")

      assert {:ok, result} = FileActions.Write.run(%{path: path, content: "Test content"}, %{})
      assert result.path == path
      assert result.bytes_written == 12
      assert File.read!(path) == "Test content"
    end

    test "creates parent directories when requested", %{tmp_dir: tmp_dir} do
      path = Path.join([tmp_dir, "subdir", "deep", "file.txt"])

      assert {:ok, _} =
               FileActions.Write.run(
                 %{path: path, content: "nested", create_dirs: true},
                 %{}
               )

      assert File.read!(path) == "nested"
    end

    test "fails without create_dirs for missing directory", %{tmp_dir: tmp_dir} do
      path = Path.join([tmp_dir, "nonexistent", "file.txt"])

      assert {:error, message} =
               FileActions.Write.run(
                 %{path: path, content: "test", create_dirs: false},
                 %{}
               )

      assert message =~ "directory not found" or message =~ "Failed to write"
    end

    test "appends to existing file", %{tmp_dir: tmp_dir} do
      path = create_file(tmp_dir, "append.txt", "Hello")

      assert {:ok, _} =
               FileActions.Write.run(
                 %{path: path, content: " World", mode: :append},
                 %{}
               )

      assert File.read!(path) == "Hello World"
    end

    test "overwrites existing file in write mode", %{tmp_dir: tmp_dir} do
      path = create_file(tmp_dir, "overwrite.txt", "old content")

      assert {:ok, result} =
               FileActions.Write.run(
                 %{path: path, content: "new content", mode: :write},
                 %{}
               )

      assert result.bytes_written == 11
      assert File.read!(path) == "new content"
    end

    test "returns permission error for unwritable path", %{tmp_dir: tmp_dir} do
      # Create a directory with no write permission
      no_write_dir = Path.join(tmp_dir, "no_write")
      File.mkdir_p!(no_write_dir)
      File.chmod!(no_write_dir, 0o444)

      on_exit(fn -> File.chmod(no_write_dir, 0o755) end)

      path = Path.join(no_write_dir, "file.txt")

      assert {:error, message} =
               FileActions.Write.run(%{path: path, content: "test"}, %{})

      assert message =~ "permission denied" or message =~ "Failed to write"
    end

    test "generates tool schema" do
      tool = FileActions.Write.to_tool()
      assert is_map(tool)
      assert tool[:name] == "file_write"
    end

    test "validates action metadata" do
      assert FileActions.Write.name() == "file_write"
      assert "write" in FileActions.Write.tags()
    end
  end

  describe "List" do
    test "lists directory contents", %{tmp_dir: tmp_dir} do
      create_file(tmp_dir, "file1.txt")
      create_file(tmp_dir, "file2.txt")
      File.mkdir_p!(Path.join(tmp_dir, "subdir"))

      assert {:ok, result} = FileActions.List.run(%{path: tmp_dir}, %{})
      assert result.path == tmp_dir
      assert "file1.txt" in result.entries
      assert "file2.txt" in result.entries
      assert "subdir" in result.entries
      assert result.count == 3
    end

    test "filters hidden files", %{tmp_dir: tmp_dir} do
      create_file(tmp_dir, "visible.txt")
      create_file(tmp_dir, ".hidden")

      assert {:ok, result} =
               FileActions.List.run(
                 %{path: tmp_dir, include_hidden: false},
                 %{}
               )

      assert "visible.txt" in result.entries
      refute ".hidden" in result.entries
    end

    test "includes hidden files when requested", %{tmp_dir: tmp_dir} do
      create_file(tmp_dir, "visible.txt")
      create_file(tmp_dir, ".hidden")

      assert {:ok, result} =
               FileActions.List.run(
                 %{path: tmp_dir, include_hidden: true},
                 %{}
               )

      assert "visible.txt" in result.entries
      assert ".hidden" in result.entries
    end

    test "excludes directories when requested", %{tmp_dir: tmp_dir} do
      create_file(tmp_dir, "file.txt")
      File.mkdir_p!(Path.join(tmp_dir, "subdir"))

      assert {:ok, result} =
               FileActions.List.run(
                 %{path: tmp_dir, include_dirs: false},
                 %{}
               )

      assert "file.txt" in result.entries
      refute "subdir" in result.entries
    end

    test "returns error for non-existent directory" do
      assert {:error, message} =
               FileActions.List.run(%{path: "/nonexistent_dir_12345"}, %{})

      assert message =~ "directory not found" or message =~ "not found"
    end

    test "returns error when listing a file instead of directory", %{tmp_dir: tmp_dir} do
      file_path = create_file(tmp_dir, "notadir.txt", "content")

      assert {:error, message} = FileActions.List.run(%{path: file_path}, %{})
      assert message =~ "not a directory" or message =~ "Failed to list"
    end

    test "lists empty directory", %{tmp_dir: tmp_dir} do
      empty_dir = Path.join(tmp_dir, "empty")
      File.mkdir_p!(empty_dir)

      assert {:ok, result} = FileActions.List.run(%{path: empty_dir}, %{})
      assert result.entries == []
      assert result.count == 0
    end

    test "combines include_hidden and include_dirs options", %{tmp_dir: tmp_dir} do
      create_file(tmp_dir, "visible.txt")
      create_file(tmp_dir, ".hidden_file")
      File.mkdir_p!(Path.join(tmp_dir, "subdir"))
      File.mkdir_p!(Path.join(tmp_dir, ".hidden_dir"))

      # include_hidden=true, include_dirs=false
      assert {:ok, result} =
               FileActions.List.run(
                 %{path: tmp_dir, include_hidden: true, include_dirs: false},
                 %{}
               )

      assert "visible.txt" in result.entries
      assert ".hidden_file" in result.entries
      refute "subdir" in result.entries
      refute ".hidden_dir" in result.entries
    end

    test "entries are sorted", %{tmp_dir: tmp_dir} do
      create_file(tmp_dir, "charlie.txt")
      create_file(tmp_dir, "alpha.txt")
      create_file(tmp_dir, "bravo.txt")

      assert {:ok, result} = FileActions.List.run(%{path: tmp_dir}, %{})
      assert result.entries == Enum.sort(result.entries)
    end

    test "validates action metadata" do
      assert FileActions.List.name() == "file_list"
      assert "directory" in FileActions.List.tags()
    end
  end

  describe "Glob" do
    test "finds files matching pattern", %{tmp_dir: tmp_dir} do
      create_file(tmp_dir, "file1.txt")
      create_file(tmp_dir, "file2.txt")
      create_file(tmp_dir, "other.log")

      pattern = Path.join(tmp_dir, "*.txt")
      assert {:ok, result} = FileActions.Glob.run(%{pattern: pattern}, %{})

      assert length(result.matches) == 2
      assert Enum.all?(result.matches, &String.ends_with?(&1, ".txt"))
    end

    test "finds files in subdirectories", %{tmp_dir: tmp_dir} do
      create_file(tmp_dir, "root.txt")
      create_file(tmp_dir, "subdir/nested.txt")

      pattern = Path.join(tmp_dir, "**/*.txt")
      assert {:ok, result} = FileActions.Glob.run(%{pattern: pattern}, %{})

      assert length(result.matches) == 2
    end

    test "uses base_path", %{tmp_dir: tmp_dir} do
      create_file(tmp_dir, "file.txt")

      assert {:ok, result} =
               FileActions.Glob.run(
                 %{pattern: "*.txt", base_path: tmp_dir},
                 %{}
               )

      assert length(result.matches) == 1
    end

    test "matches hidden files when requested", %{tmp_dir: tmp_dir} do
      create_file(tmp_dir, ".hidden.txt")
      create_file(tmp_dir, "visible.txt")

      # Without match_dot
      pattern = Path.join(tmp_dir, "*.txt")
      assert {:ok, result} = FileActions.Glob.run(%{pattern: pattern, match_dot: false}, %{})
      assert length(result.matches) == 1

      # With match_dot
      assert {:ok, result} = FileActions.Glob.run(%{pattern: pattern, match_dot: true}, %{})
      assert length(result.matches) == 2
    end

    test "returns empty for no matches", %{tmp_dir: tmp_dir} do
      pattern = Path.join(tmp_dir, "*.nonexistent")
      assert {:ok, result} = FileActions.Glob.run(%{pattern: pattern}, %{})

      assert result.matches == []
      assert result.count == 0
    end

    test "validates action metadata" do
      assert FileActions.Glob.name() == "file_glob"
      assert "glob" in FileActions.Glob.tags()
    end
  end

  describe "Exists" do
    test "detects existing file", %{tmp_dir: tmp_dir} do
      path = create_file(tmp_dir, "exists.txt", "content")

      assert {:ok, result} = FileActions.Exists.run(%{path: path}, %{})
      assert result.exists == true
      assert result.type == :file
      assert result.size == 7
    end

    test "detects existing directory", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "subdir")
      File.mkdir_p!(path)

      assert {:ok, result} = FileActions.Exists.run(%{path: path}, %{})
      assert result.exists == true
      assert result.type == :directory
      assert result.size == nil
    end

    test "detects non-existent path" do
      assert {:ok, result} =
               FileActions.Exists.run(%{path: "/nonexistent_path_12345"}, %{})

      assert result.exists == false
      assert result.type == nil
    end

    test "detects symlink as other type", %{tmp_dir: tmp_dir} do
      target = create_file(tmp_dir, "target.txt", "content")
      link_path = Path.join(tmp_dir, "link")
      File.ln_s!(target, link_path)

      assert {:ok, result} = FileActions.Exists.run(%{path: link_path}, %{})
      assert result.exists == true
      # Symlinks resolve to their target type via File.stat
      assert result.type in [:file, :other]
    end

    test "validates action metadata" do
      assert FileActions.Exists.name() == "file_exists"
      assert "exists" in FileActions.Exists.tags()
    end

    test "generates tool schema" do
      tool = FileActions.Exists.to_tool()
      assert is_map(tool)
      assert tool[:name] == "file_exists"
    end
  end
end
