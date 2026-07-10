defmodule Arbor.Actions.FileTest do
  use Arbor.Actions.ActionCase, async: true
  @moduletag :fast

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

    test "security regression: a `..` pattern cannot escape an authorized base_path", %{
      tmp_dir: tmp_dir
    } do
      # codex path-traversal.file-glob-pattern-base-escape: pre-fix, the base was
      # capability-checked but the pattern was Path.join'd verbatim, so
      # `../sibling/**` enumerated files OUTSIDE the authorized base.
      base = Path.join(tmp_dir, "base")
      File.mkdir_p!(base)
      create_file(tmp_dir, "sibling/secret.txt")

      result =
        FileActions.Glob.run(%{pattern: "../sibling/*.txt", base_path: base}, %{})

      assert {:error, msg} = result,
             "glob pattern with `..` must be rejected, got: #{inspect(result)}"

      assert msg =~ "traversal"
    end

    test "security regression: an agent glob without base_path or workspace fails closed", %{
      tmp_dir: tmp_dir
    } do
      create_file(tmp_dir, "outside.txt", "must not be enumerated")

      result =
        FileActions.Glob.run(
          %{pattern: Path.join(tmp_dir, "*.txt")},
          %{agent_id: "agent_glob_without_base"}
        )

      assert {:error, message} = result
      assert message =~ "authorized base_path or workspace"
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

  describe "Edit" do
    test "replaces string in file", %{tmp_dir: tmp_dir} do
      path = create_file(tmp_dir, "edit_test.txt", "Hello, World!")

      assert {:ok, result} =
               FileActions.Edit.run(
                 %{path: path, old_string: "World", new_string: "Elixir"},
                 %{}
               )

      assert result.path == path
      assert result.replacements_made == 1
      assert File.read!(path) == "Hello, Elixir!"
    end

    test "replaces first occurrence only by default", %{tmp_dir: tmp_dir} do
      path = create_file(tmp_dir, "multi.txt", "foo bar foo baz foo")

      assert {:ok, result} =
               FileActions.Edit.run(
                 %{path: path, old_string: "foo", new_string: "qux"},
                 %{}
               )

      assert result.replacements_made == 1
      assert File.read!(path) == "qux bar foo baz foo"
    end

    test "replaces all occurrences when replace_all is true", %{tmp_dir: tmp_dir} do
      path = create_file(tmp_dir, "multi.txt", "foo bar foo baz foo")

      assert {:ok, result} =
               FileActions.Edit.run(
                 %{path: path, old_string: "foo", new_string: "qux", replace_all: true},
                 %{}
               )

      assert result.replacements_made == 3
      assert File.read!(path) == "qux bar qux baz qux"
    end

    test "returns error when old_string not found", %{tmp_dir: tmp_dir} do
      path = create_file(tmp_dir, "no_match.txt", "Hello, World!")

      assert {:error, message} =
               FileActions.Edit.run(
                 %{path: path, old_string: "NotHere", new_string: "Replacement"},
                 %{}
               )

      assert message =~ "String not found"
    end

    test "returns error for non-existent file" do
      assert {:error, message} =
               FileActions.Edit.run(
                 %{path: "/nonexistent_edit_12345.txt", old_string: "a", new_string: "b"},
                 %{}
               )

      assert message =~ "File not found"
    end

    test "returns error for empty old_string", %{tmp_dir: tmp_dir} do
      path = create_file(tmp_dir, "empty_old.txt", "content")

      assert {:error, message} =
               FileActions.Edit.run(
                 %{path: path, old_string: "", new_string: "something"},
                 %{}
               )

      assert message =~ "non-empty string"
    end

    test "handles multiline replacements", %{tmp_dir: tmp_dir} do
      content = """
      defmodule Foo do
        def bar, do: :old
      end
      """

      path = create_file(tmp_dir, "code.ex", content)

      assert {:ok, result} =
               FileActions.Edit.run(
                 %{path: path, old_string: ":old", new_string: ":new"},
                 %{}
               )

      assert result.replacements_made == 1
      assert File.read!(path) =~ ":new"
      refute File.read!(path) =~ ":old"
    end

    test "returns preview of changed content", %{tmp_dir: tmp_dir} do
      path = create_file(tmp_dir, "preview.txt", "The quick brown fox")

      assert {:ok, result} =
               FileActions.Edit.run(
                 %{path: path, old_string: "quick", new_string: "lazy"},
                 %{}
               )

      assert is_binary(result.preview)
      assert result.preview =~ "lazy"
    end

    test "validates action metadata" do
      assert FileActions.Edit.name() == "file_edit"
      assert FileActions.Edit.category() == "file"
      assert "edit" in FileActions.Edit.tags()
    end

    test "generates tool schema" do
      tool = FileActions.Edit.to_tool()
      assert is_map(tool)
      assert tool[:name] == "file_edit"
    end
  end

  describe "Search" do
    test "searches file for literal string", %{tmp_dir: tmp_dir} do
      path = create_file(tmp_dir, "search_test.txt", "Hello, World!\nGoodbye, World!")

      assert {:ok, result} =
               FileActions.Search.run(
                 %{pattern: "World", path: path},
                 %{}
               )

      assert result.count == 2
      assert length(result.matches) == 2
      assert Enum.all?(result.matches, fn m -> m.file == path end)
    end

    test "searches directory recursively", %{tmp_dir: tmp_dir} do
      create_file(tmp_dir, "file1.txt", "target string here")
      create_file(tmp_dir, "subdir/file2.txt", "also has target")

      assert {:ok, result} =
               FileActions.Search.run(
                 %{pattern: "target", path: tmp_dir},
                 %{}
               )

      assert result.count == 2
    end

    test "filters by glob pattern", %{tmp_dir: tmp_dir} do
      create_file(tmp_dir, "file.txt", "target")
      create_file(tmp_dir, "file.log", "target")

      assert {:ok, result} =
               FileActions.Search.run(
                 %{pattern: "target", path: tmp_dir, glob: "*.txt"},
                 %{}
               )

      assert result.count == 1
      assert hd(result.matches).file =~ ".txt"
    end

    test "limits results with max_results", %{tmp_dir: tmp_dir} do
      # Create multiple matches
      content = Enum.map_join(1..100, "\n", fn i -> "line #{i} has target" end)
      create_file(tmp_dir, "many.txt", content)

      assert {:ok, result} =
               FileActions.Search.run(
                 %{pattern: "target", path: tmp_dir, max_results: 10},
                 %{}
               )

      assert result.count == 10
    end

    test "includes context lines", %{tmp_dir: tmp_dir} do
      content = "line 1\nline 2\ntarget line\nline 4\nline 5"
      path = create_file(tmp_dir, "context.txt", content)

      assert {:ok, result} =
               FileActions.Search.run(
                 %{pattern: "target", path: path, context_lines: 1},
                 %{}
               )

      assert result.count == 1
      match = hd(result.matches)
      # Context should include surrounding lines
      assert match.content =~ "line 2"
      assert match.content =~ "target line"
      assert match.content =~ "line 4"
    end

    test "supports regex patterns", %{tmp_dir: tmp_dir} do
      content = "foo123bar\nfoo456bar\nnotmatching"
      path = create_file(tmp_dir, "regex.txt", content)

      assert {:ok, result} =
               FileActions.Search.run(
                 %{pattern: "foo\\d+bar", path: path, regex: true},
                 %{}
               )

      assert result.count == 2
    end

    test "returns error for invalid regex", %{tmp_dir: tmp_dir} do
      path = create_file(tmp_dir, "test.txt", "content")

      assert {:error, message} =
               FileActions.Search.run(
                 %{pattern: "[invalid", path: path, regex: true},
                 %{}
               )

      assert message =~ "Invalid regex"
    end

    test "returns empty results for no matches", %{tmp_dir: tmp_dir} do
      path = create_file(tmp_dir, "empty.txt", "no match here")

      assert {:ok, result} =
               FileActions.Search.run(
                 %{pattern: "zzz", path: path},
                 %{}
               )

      assert result.count == 0
      assert result.matches == []
    end

    test "returns error for non-existent path" do
      assert {:error, message} =
               FileActions.Search.run(
                 %{pattern: "test", path: "/nonexistent_dir_12345"},
                 %{}
               )

      assert message =~ "does not exist"
    end

    test "validates action metadata" do
      assert FileActions.Search.name() == "file_search"
      assert FileActions.Search.category() == "file"
      assert "search" in FileActions.Search.tags()
    end

    test "generates tool schema" do
      tool = FileActions.Search.to_tool()
      assert is_map(tool)
      assert tool[:name] == "file_search"
    end
  end

  # Strategy parity — `File.Search` dispatches to ripgrep, grep, or
  # BEAM-native based on what's installed. The output shape MUST be
  # identical across strategies. The process-dictionary key
  # `:__arbor_file_search_force_strategy__` is the testing seam that
  # forces a specific path so we can pin shape parity.
  describe "Search — strategy parity" do
    setup :tmp_dir_fixture

    defp tmp_dir_fixture(_) do
      tmp = System.tmp_dir!() |> Path.join("file_search_strategy_#{:rand.uniform(100_000)}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf(tmp) end)
      {:ok, tmp_dir: tmp}
    end

    defp run_with_strategy(strategy, params) do
      Process.put(:__arbor_file_search_force_strategy__, strategy)

      try do
        FileActions.Search.run(params, %{})
      after
        Process.delete(:__arbor_file_search_force_strategy__)
      end
    end

    test "all available strategies return the same shape for a literal search", %{
      tmp_dir: tmp_dir
    } do
      path = Path.join(tmp_dir, "parity.txt")

      File.write!(path, """
      line 1: alpha
      line 2: beta
      line 3: gamma_NEEDLE_target
      line 4: delta
      line 5: epsilon_NEEDLE
      """)

      strategies_to_test =
        [
          :beam,
          if(System.find_executable("rg"), do: :ripgrep),
          if(System.find_executable("grep"), do: :grep)
        ]
        |> Enum.reject(&is_nil/1)

      results =
        Enum.map(strategies_to_test, fn strategy ->
          {:ok, result} =
            run_with_strategy(strategy, %{
              pattern: "NEEDLE",
              path: path,
              context_lines: 1
            })

          {strategy, result}
        end)

      # All strategies must find both NEEDLE occurrences
      for {strategy, result} <- results do
        assert result.count == 2, "strategy #{strategy} found #{result.count} matches, expected 2"
      end

      # All strategies must return matches at the same lines + file
      for {strategy, result} <- results do
        lines = result.matches |> Enum.map(& &1.line) |> Enum.sort()

        assert lines == [3, 5],
               "strategy #{strategy} returned lines #{inspect(lines)}, expected [3, 5]"

        for match <- result.matches do
          assert match.file == path
        end
      end

      # Content includes context lines (the matched line is marked with
      # the > prefix in every strategy)
      for {strategy, result} <- results do
        first_match = Enum.find(result.matches, &(&1.line == 3))

        assert is_binary(first_match.content) and
                 String.contains?(first_match.content, "> 3:"),
               "strategy #{strategy} content missing match marker: #{inspect(first_match.content)}"
      end
    end

    test "no-match path returns empty list under every strategy", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "no_match.txt")
      File.write!(path, "nothing relevant here\n")

      strategies_to_test =
        [
          :beam,
          if(System.find_executable("rg"), do: :ripgrep),
          if(System.find_executable("grep"), do: :grep)
        ]
        |> Enum.reject(&is_nil/1)

      for strategy <- strategies_to_test do
        {:ok, result} =
          run_with_strategy(strategy, %{pattern: "ZZZ_NOT_PRESENT_ZZZ", path: path})

        assert result.count == 0, "strategy #{strategy} returned non-empty for no-match"
        assert result.matches == []
      end
    end

    test "empty file list short-circuits without invoking any external tool", %{
      tmp_dir: tmp_dir
    } do
      # A directory with no matching files for the glob — get_files_to_search
      # returns []. The search_files dispatcher should return {:ok, []}
      # immediately, regardless of strategy.
      File.write!(Path.join(tmp_dir, "ignored.md"), "anything")

      for strategy <- [:beam, :ripgrep, :grep] do
        {:ok, result} =
          run_with_strategy(strategy, %{
            pattern: "x",
            path: tmp_dir,
            # Filter to files that don't exist
            glob: "*.this_extension_does_not_match"
          })

        assert result.count == 0
        assert result.matches == []
      end
    end

    # Regression: regex parity across strategies. The compiled pattern is
    # PCRE (Elixir `Regex`), but grep's `-E` engine is POSIX ERE and does
    # NOT understand PCRE escapes like `\d`. Before the fix, a regex
    # search under the `:grep` strategy silently returned 0 matches for
    # `foo\d+bar` (matched a literal `d`), so on a CI runner that had
    # grep but not ripgrep, "supports regex patterns" found 0 instead of
    # 2. Every available strategy must agree on a PCRE regex search.
    test "PCRE regex returns identical results under every strategy", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "regex_parity.txt")
      File.write!(path, "foo123bar\nfoo456bar\nnotmatching\nfooXbar\n")

      strategies_to_test =
        [
          :beam,
          if(System.find_executable("rg"), do: :ripgrep),
          if(System.find_executable("grep"), do: :grep)
        ]
        |> Enum.reject(&is_nil/1)

      for strategy <- strategies_to_test do
        {:ok, result} =
          run_with_strategy(strategy, %{
            pattern: "foo\\d+bar",
            path: path,
            regex: true
          })

        assert result.count == 2,
               "strategy #{strategy} found #{result.count} matches for PCRE regex, expected 2"

        assert result.matches |> Enum.map(& &1.line) |> Enum.sort() == [1, 2],
               "strategy #{strategy} matched wrong lines: #{inspect(Enum.map(result.matches, & &1.line))}"
      end
    end
  end
end
