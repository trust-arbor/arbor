defmodule Arbor.Common.Sessions.ReaderTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Common.Sessions.Reader
  alias Arbor.Common.Sessions.Record

  @fixtures_dir Path.expand("../../../fixtures/sessions", __DIR__)

  describe "stream/2" do
    test "streams records from a basic JSONL file" do
      path = Path.join(@fixtures_dir, "claude_basic.jsonl")
      assert {:ok, stream} = Reader.stream(path, allowed_root: @fixtures_dir)

      records = Enum.to_list(stream)
      assert length(records) == 4

      # First should be a user message
      assert hd(records).type == :user
      assert hd(records).text == "Hello, can you help me?"
    end

    test "streams records with tool use" do
      path = Path.join(@fixtures_dir, "claude_tools.jsonl")
      assert {:ok, stream} = Reader.stream(path, allowed_root: @fixtures_dir)

      records = Enum.to_list(stream)
      assert length(records) == 8

      # Find a tool use message
      tool_msg =
        Enum.find(records, fn r ->
          r.type == :assistant and Enum.any?(r.content, &(&1[:type] == :tool_use))
        end)

      assert tool_msg != nil
      tool_use = Enum.find(tool_msg.content, &(&1[:type] == :tool_use))
      assert tool_use.tool_name == "Bash"
    end

    test "streams records with thinking blocks" do
      path = Path.join(@fixtures_dir, "claude_thinking.jsonl")
      assert {:ok, stream} = Reader.stream(path, allowed_root: @fixtures_dir)

      records = Enum.to_list(stream)

      # Find a thinking message
      thinking_msg =
        Enum.find(records, fn r ->
          r.type == :assistant and Enum.any?(r.content, &(&1[:type] == :thinking))
        end)

      assert thinking_msg != nil
      thinking = Enum.find(thinking_msg.content, &(&1[:type] == :thinking))
      assert thinking.text =~ "sorting"
    end

    test "returns empty stream for empty file" do
      path = Path.join(@fixtures_dir, "claude_empty.jsonl")
      assert {:ok, stream} = Reader.stream(path, allowed_root: @fixtures_dir)

      records = Enum.to_list(stream)
      assert records == []
    end

    test "skips malformed lines by default" do
      path = Path.join(@fixtures_dir, "claude_malformed.jsonl")
      assert {:ok, stream} = Reader.stream(path, allowed_root: @fixtures_dir)

      records = Enum.to_list(stream)
      # Should have valid records, skipping invalid ones
      assert length(records) == 3

      # All records should be valid
      Enum.each(records, fn record ->
        assert %Record{} = record
        assert record.uuid != nil
      end)
    end

    test "returns error for non-existent file" do
      assert {:error, :file_not_found} =
               Reader.stream("/nonexistent/path.jsonl", allowed_root: "/")
    end

    @tag :security_regression
    test "security regression: requires and enforces a trusted read root" do
      path = Path.join(@fixtures_dir, "claude_basic.jsonl")

      assert {:error, :allowed_root_required} = Reader.stream(path)
      assert {:error, :path_traversal} = Reader.stream(path, allowed_root: System.tmp_dir!())
    end

    @tag :security_regression
    test "security regression: rejects oversized JSONL records before parsing" do
      path = Path.join(@fixtures_dir, "claude_basic.jsonl")
      assert {:ok, stream} = Reader.stream(path, allowed_root: @fixtures_dir, max_line_bytes: 4)
      assert Enum.to_list(stream) == []
    end

    @tag :security_regression
    test "security regression: discards an oversized line in bounded chunks and resumes" do
      root = tmp_dir("bounded-lines")
      path = Path.join(root, "session.jsonl")

      valid_line =
        @fixtures_dir
        |> Path.join("claude_basic.jsonl")
        |> File.read!()
        |> String.split("\n", parts: 2)
        |> hd()

      File.write!(path, [String.duplicate("x", 256_000), "\n", valid_line, "\n"])

      assert {:ok, stream} = Reader.stream(path, allowed_root: root, max_line_bytes: 512)
      assert [%Record{}] = Enum.to_list(stream)
    end

    @tag :security_regression
    test "security regression: a symlink swap after validation cannot redirect lazy reads" do
      base = tmp_dir("descriptor-swap")
      root = Path.join(base, "root")
      File.mkdir!(root)

      candidate = Path.join(root, "session.jsonl")
      outside = Path.join(base, "outside.jsonl")
      fixture = File.read!(Path.join(@fixtures_dir, "claude_basic.jsonl"))
      File.write!(candidate, fixture)
      File.write!(outside, fixture)

      assert {:ok, stream} = Reader.stream(candidate, allowed_root: root)

      File.rm!(candidate)
      File.ln_s!(outside, candidate)

      assert Enum.to_list(stream) == []
    end
  end

  describe "read_all/2" do
    test "reads all records from a file" do
      path = Path.join(@fixtures_dir, "claude_basic.jsonl")
      assert {:ok, records} = Reader.read_all(path, allowed_root: @fixtures_dir)

      assert is_list(records)
      assert length(records) == 4
    end

    test "returns error for non-existent file" do
      assert {:error, :file_not_found} =
               Reader.read_all("/nonexistent/path.jsonl", allowed_root: "/")
    end
  end

  describe "find_sessions/2" do
    test "finds session files in a directory" do
      assert {:ok, files} = Reader.find_sessions(@fixtures_dir, allowed_root: @fixtures_dir)

      assert is_list(files)
      assert files != []
      assert Enum.all?(files, &String.ends_with?(&1, ".jsonl"))
    end

    test "returns error for non-directory" do
      path = Path.join(@fixtures_dir, "claude_basic.jsonl")

      assert {:error, :not_a_directory} =
               Reader.find_sessions(path, allowed_root: @fixtures_dir)
    end

    test "returns empty list for directory with no sessions" do
      test_dir = tmp_dir("empty-sessions")

      assert {:ok, []} = Reader.find_sessions(test_dir, allowed_root: test_dir)
    end
  end

  describe "latest_session/2" do
    test "returns the most recent session file" do
      assert {:ok, path} = Reader.latest_session(@fixtures_dir, allowed_root: @fixtures_dir)

      assert String.ends_with?(path, ".jsonl")
      assert File.exists?(path)
    end

    test "returns error when no sessions found" do
      test_dir = tmp_dir("empty-sessions")

      assert {:error, :no_sessions_found} =
               Reader.latest_session(test_dir, allowed_root: test_dir)
    end
  end

  describe "resolve/1" do
    @tag :security_regression
    test "security regression: rejects traversal-shaped session identifiers" do
      assert {:error, :invalid_identifier} = Reader.resolve("../secrets")
      assert {:error, :invalid_identifier} = Reader.resolve("name/../../secrets")
    end
  end

  describe "resolve_within/2" do
    test "resolves a path within allowed root" do
      path = Path.join(@fixtures_dir, "claude_basic.jsonl")
      assert {:ok, resolved} = Reader.resolve_within("claude_basic.jsonl", @fixtures_dir)
      assert resolved == path
    end

    test "returns error for path traversal attempt" do
      assert {:error, :path_traversal} =
               Reader.resolve_within("../../../etc/passwd", @fixtures_dir)
    end

    test "returns error for non-existent file" do
      assert {:error, :file_not_found} = Reader.resolve_within("nonexistent.jsonl", @fixtures_dir)
    end

    test "returns error for non-jsonl file" do
      # Even if a file exists, it should reject non-.jsonl files
      assert {:error, _} = Reader.resolve_within("some_file.txt", @fixtures_dir)
    end
  end

  defp tmp_dir(label) do
    {:ok, system_tmp} = Arbor.Common.SafePath.resolve_real(System.tmp_dir!())
    token = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    path = Path.join(system_tmp, "arbor-reader-#{label}-#{token}")
    File.mkdir!(path)
    File.chmod!(path, 0o700)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
