defmodule Arbor.AI.SessionReaderTest do
  use ExUnit.Case, async: true

  alias Arbor.AI.SessionReader

  @session_dir Path.join([System.tmp_dir!(), "arbor_session_reader_test"])

  setup do
    File.rm_rf!(@session_dir)
    File.mkdir_p!(@session_dir)
    on_exit(fn -> File.rm_rf!(@session_dir) end)
    :ok
  end

  describe "read_thinking_from_file/2" do
    test "extracts thinking blocks from session file" do
      session_file = Path.join(@session_dir, "test-session.jsonl")

      content = """
      {"type":"system","subtype":"init"}
      {"type":"assistant","sessionId":"test-session","message":{"id":"msg_001","content":[{"type":"thinking","thinking":"First let me analyze this problem...","signature":"sig123"},{"type":"text","text":"Here is my answer."}]}}
      {"type":"result","session_id":"test-session"}
      """

      File.write!(session_file, content)

      assert {:ok, blocks} = SessionReader.read_thinking_from_file(session_file)
      assert length(blocks) == 1

      [block] = blocks
      assert block.text == "First let me analyze this problem..."
      assert block.signature == "sig123"
      assert block.message_id == "msg_001"
    end

    test "returns empty list when no thinking blocks" do
      session_file = Path.join(@session_dir, "no-thinking.jsonl")

      content = """
      {"type":"assistant","sessionId":"test","message":{"id":"msg_001","content":[{"type":"text","text":"Just text."}]}}
      """

      File.write!(session_file, content)

      assert {:ok, []} = SessionReader.read_thinking_from_file(session_file)
    end

    test "handles multiple thinking blocks across messages" do
      session_file = Path.join(@session_dir, "multi-thinking.jsonl")

      content = """
      {"type":"assistant","sessionId":"test","message":{"id":"msg_001","content":[{"type":"thinking","thinking":"First thought.","signature":"sig1"}]}}
      {"type":"assistant","sessionId":"test","message":{"id":"msg_002","content":[{"type":"thinking","thinking":"Second thought.","signature":"sig2"}]}}
      """

      File.write!(session_file, content)

      assert {:ok, blocks} = SessionReader.read_thinking_from_file(session_file)
      assert length(blocks) == 2
      assert Enum.map(blocks, & &1.text) == ["First thought.", "Second thought."]
    end

    test "returns error for missing file" do
      assert {:error, {:file_read_error, :enoent, _}} =
               SessionReader.read_thinking_from_file("/nonexistent/file.jsonl")
    end

    test "handles thinking blocks without signature" do
      session_file = Path.join(@session_dir, "no-sig.jsonl")

      content = """
      {"type":"assistant","sessionId":"test","message":{"id":"msg_001","content":[{"type":"thinking","thinking":"No signature block."}]}}
      """

      File.write!(session_file, content)

      assert {:ok, [block]} = SessionReader.read_thinking_from_file(session_file)
      assert block.text == "No signature block."
      assert block.signature == nil
    end
  end

  describe "read_thinking/2" do
    test "finds session by ID in base directory" do
      project_dir = Path.join(@session_dir, "-test-project")
      File.mkdir_p!(project_dir)
      session_file = Path.join(project_dir, "abc-123.jsonl")

      content = """
      {"type":"assistant","sessionId":"abc-123","message":{"id":"msg_001","content":[{"type":"thinking","thinking":"Found by ID.","signature":"sig"}]}}
      """

      File.write!(session_file, content)

      assert {:ok, [block]} = SessionReader.read_thinking("abc-123", base_dir: @session_dir)
      assert block.text == "Found by ID."
    end

    test "returns error for unknown session" do
      assert {:error, {:session_not_found, "unknown-session"}} =
               SessionReader.read_thinking("unknown-session", base_dir: @session_dir)
    end
  end

  describe "latest_thinking/1" do
    test "reads from most recently modified session" do
      project_dir = Path.join(@session_dir, "-test-project")
      File.mkdir_p!(project_dir)

      # Create older session
      old_file = Path.join(project_dir, "old-session.jsonl")

      File.write!(old_file, """
      {"type":"assistant","sessionId":"old","message":{"id":"msg","content":[{"type":"thinking","thinking":"Old thought.","signature":"sig"}]}}
      """)

      # Wait and create newer session
      :timer.sleep(100)
      new_file = Path.join(project_dir, "new-session.jsonl")

      File.write!(new_file, """
      {"type":"assistant","sessionId":"new","message":{"id":"msg","content":[{"type":"thinking","thinking":"New thought.","signature":"sig"}]}}
      """)

      assert {:ok, [block]} = SessionReader.latest_thinking(base_dir: @session_dir)
      assert block.text == "New thought."
    end

    test "returns error when no sessions exist" do
      empty_dir = Path.join(@session_dir, "empty")
      File.mkdir_p!(empty_dir)

      assert {:error, :no_sessions_found} = SessionReader.latest_thinking(base_dir: empty_dir)
    end
  end

  describe "sessions_with_thinking/1" do
    test "lists sessions containing thinking blocks" do
      project_dir = Path.join(@session_dir, "-project")
      File.mkdir_p!(project_dir)

      # Session with thinking
      File.write!(Path.join(project_dir, "with-thinking.jsonl"), """
      {"type":"assistant","sessionId":"with","message":{"id":"msg","content":[{"type":"thinking","thinking":"Has thinking.","signature":"sig"}]}}
      """)

      # Session without thinking
      File.write!(Path.join(project_dir, "without-thinking.jsonl"), """
      {"type":"assistant","sessionId":"without","message":{"id":"msg","content":[{"type":"text","text":"No thinking."}]}}
      """)

      assert {:ok, sessions} = SessionReader.sessions_with_thinking(base_dir: @session_dir)
      assert length(sessions) == 1
      assert hd(sessions).session_id == "with-thinking"
    end

    test "respects limit option" do
      project_dir = Path.join(@session_dir, "-project")
      File.mkdir_p!(project_dir)

      for i <- 1..5 do
        File.write!(Path.join(project_dir, "session-#{i}.jsonl"), """
        {"type":"assistant","sessionId":"s#{i}","message":{"id":"msg","content":[{"type":"thinking","thinking":"Thought #{i}.","signature":"sig"}]}}
        """)

        :timer.sleep(50)
      end

      assert {:ok, sessions} =
               SessionReader.sessions_with_thinking(base_dir: @session_dir, limit: 3)

      assert length(sessions) == 3
    end
  end
end
