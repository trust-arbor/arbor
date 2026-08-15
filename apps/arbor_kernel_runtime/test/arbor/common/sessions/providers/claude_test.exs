defmodule Arbor.Common.Sessions.Providers.ClaudeTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Common.Sessions.Providers.Claude

  describe "parse_record/1" do
    test "parses a user message with string content" do
      json = %{
        "type" => "user",
        "uuid" => "msg-001",
        "parentUuid" => nil,
        "sessionId" => "session-001",
        "timestamp" => "2026-01-28T10:00:00.000Z",
        "message" => %{
          "role" => "user",
          "content" => "Hello, world!"
        }
      }

      assert {:ok, record} = Claude.parse_record(json)
      assert record.type == :user
      assert record.role == :user
      assert record.uuid == "msg-001"
      assert record.session_id == "session-001"
      assert record.text == "Hello, world!"
      assert length(record.content) == 1
      assert hd(record.content).type == :text
    end

    test "parses an assistant message with array content" do
      json = %{
        "type" => "assistant",
        "uuid" => "msg-002",
        "parentUuid" => "msg-001",
        "sessionId" => "session-001",
        "timestamp" => "2026-01-28T10:00:05.000Z",
        "message" => %{
          "role" => "assistant",
          "model" => "claude-opus-4-5-20251101",
          "content" => [
            %{"type" => "text", "text" => "Hello!"},
            %{"type" => "text", "text" => "How can I help?"}
          ],
          "usage" => %{"input_tokens" => 100, "output_tokens" => 20}
        }
      }

      assert {:ok, record} = Claude.parse_record(json)
      assert record.type == :assistant
      assert record.role == :assistant
      assert record.model == "claude-opus-4-5-20251101"
      assert record.text == "Hello!\nHow can I help?"
      assert length(record.content) == 2
      assert record.usage == %{"input_tokens" => 100, "output_tokens" => 20}
    end

    test "parses tool use content" do
      json = %{
        "type" => "assistant",
        "uuid" => "msg-003",
        "sessionId" => "session-001",
        "timestamp" => "2026-01-28T10:00:10.000Z",
        "message" => %{
          "role" => "assistant",
          "content" => [
            %{
              "type" => "tool_use",
              "id" => "toolu_123",
              "name" => "Bash",
              "input" => %{"command" => "ls -la"}
            }
          ]
        }
      }

      assert {:ok, record} = Claude.parse_record(json)
      assert length(record.content) == 1

      tool_use = hd(record.content)
      assert tool_use.type == :tool_use
      assert tool_use.tool_name == "Bash"
      assert tool_use.tool_use_id == "toolu_123"
      assert tool_use.tool_input == %{"command" => "ls -la"}
    end

    test "parses tool result content" do
      json = %{
        "type" => "user",
        "uuid" => "msg-004",
        "sessionId" => "session-001",
        "timestamp" => "2026-01-28T10:00:15.000Z",
        "message" => %{
          "role" => "user",
          "content" => [
            %{
              "type" => "tool_result",
              "tool_use_id" => "toolu_123",
              "content" => "file1.txt\nfile2.txt",
              "is_error" => false
            }
          ]
        }
      }

      assert {:ok, record} = Claude.parse_record(json)
      assert length(record.content) == 1

      tool_result = hd(record.content)
      assert tool_result.type == :tool_result
      assert tool_result.tool_use_id == "toolu_123"
      assert tool_result.tool_result == "file1.txt\nfile2.txt"
      assert tool_result.is_error == false
    end

    test "parses thinking blocks" do
      json = %{
        "type" => "assistant",
        "uuid" => "msg-005",
        "sessionId" => "session-001",
        "timestamp" => "2026-01-28T10:00:20.000Z",
        "message" => %{
          "role" => "assistant",
          "content" => [
            %{"type" => "thinking", "thinking" => "Let me think about this..."},
            %{"type" => "text", "text" => "Here's my answer."}
          ]
        }
      }

      assert {:ok, record} = Claude.parse_record(json)
      assert length(record.content) == 2

      thinking = Enum.find(record.content, &(&1.type == :thinking))
      assert thinking.text == "Let me think about this..."
    end

    test "parses progress records" do
      json = %{
        "type" => "progress",
        "uuid" => "prog-001",
        "sessionId" => "session-001",
        "timestamp" => "2026-01-28T10:00:00.000Z",
        "data" => %{"type" => "hook_progress", "hookEvent" => "SessionStart"}
      }

      assert {:ok, record} = Claude.parse_record(json)
      assert record.type == :progress

      assert record.metadata.progress_data == %{
               "type" => "hook_progress",
               "hookEvent" => "SessionStart"
             }
    end

    test "handles nil message" do
      json = %{
        "type" => "progress",
        "uuid" => "prog-001",
        "sessionId" => "session-001"
      }

      assert {:ok, record} = Claude.parse_record(json)
      assert record.role == nil
      assert record.content == []
    end

    test "parses timestamp correctly" do
      json = %{
        "type" => "user",
        "uuid" => "msg-001",
        "sessionId" => "session-001",
        "timestamp" => "2026-01-28T10:30:45.123Z",
        "message" => %{"role" => "user", "content" => "test"}
      }

      assert {:ok, record} = Claude.parse_record(json)
      assert record.timestamp.year == 2026
      assert record.timestamp.month == 1
      assert record.timestamp.day == 28
      assert record.timestamp.hour == 10
      assert record.timestamp.minute == 30
    end

    test "handles invalid timestamp" do
      json = %{
        "type" => "user",
        "uuid" => "msg-001",
        "sessionId" => "session-001",
        "timestamp" => "invalid",
        "message" => %{"role" => "user", "content" => "test"}
      }

      assert {:ok, record} = Claude.parse_record(json)
      assert record.timestamp == nil
    end

    test "extracts metadata" do
      json = %{
        "type" => "user",
        "uuid" => "msg-001",
        "sessionId" => "session-001",
        "cwd" => "/Users/test/project",
        "gitBranch" => "main",
        "version" => "2.1.20",
        "message" => %{"role" => "user", "content" => "test"}
      }

      assert {:ok, record} = Claude.parse_record(json)
      assert record.metadata.cwd == "/Users/test/project"
      assert record.metadata.git_branch == "main"
      assert record.metadata.version == "2.1.20"
    end
  end

  describe "matches?/1" do
    test "returns true for Claude format" do
      json = %{"sessionId" => "abc", "uuid" => "123"}
      assert Claude.matches?(json)
    end

    test "returns false for non-Claude format" do
      json = %{"other" => "format"}
      refute Claude.matches?(json)
    end

    test "returns false for non-map input" do
      refute Claude.matches?("string")
      refute Claude.matches?(nil)
    end
  end

  describe "session_dir/0" do
    test "returns the default Claude session directory" do
      assert Claude.session_dir() == "~/.claude/projects"
    end
  end

  describe "expanded_session_dir/0" do
    test "returns an absolute path" do
      dir = Claude.expanded_session_dir()
      assert String.starts_with?(dir, "/")
      assert String.ends_with?(dir, ".claude/projects")
    end
  end

  describe "decode_project_path/1" do
    test "decodes macOS paths" do
      assert Claude.decode_project_path("-Users-foo-myproject") =~ ~r{/Users/foo}
    end

    test "decodes Linux paths" do
      assert Claude.decode_project_path("-home-foo-myproject") =~ ~r{/home/foo}
    end

    test "handles unknown paths" do
      result = Claude.decode_project_path("-unknown-path")
      assert String.starts_with?(result, "/")
    end
  end

  describe "encode_project_path/1" do
    test "encodes paths by replacing slashes" do
      assert Claude.encode_project_path("/Users/foo/myproject") == "-Users-foo-myproject"
    end
  end
end
