defmodule Arbor.Common.Sessions.Providers.ClaudeEdgeCasesTest do
  @moduledoc """
  Additional edge case tests for the Claude provider to improve coverage.
  """
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Common.Sessions.Providers.Claude

  describe "parse_record/1 edge cases" do
    test "parses queue_operation type" do
      json = %{
        "type" => "queue_operation",
        "uuid" => "q-001",
        "sessionId" => "session-001"
      }

      assert {:ok, record} = Claude.parse_record(json)
      assert record.type == :queue_operation
    end

    test "parses summary type" do
      json = %{
        "type" => "summary",
        "uuid" => "s-001",
        "sessionId" => "session-001"
      }

      assert {:ok, record} = Claude.parse_record(json)
      assert record.type == :summary
    end

    test "parses file-history-snapshot type" do
      json = %{
        "type" => "file-history-snapshot",
        "uuid" => "fhs-001",
        "sessionId" => "session-001",
        "snapshot" => %{"files" => ["a.ex", "b.ex"]}
      }

      assert {:ok, record} = Claude.parse_record(json)
      assert record.type == :file_history_snapshot
      assert record.metadata.snapshot == %{"files" => ["a.ex", "b.ex"]}
    end

    test "parses unknown type to :unknown" do
      json = %{
        "type" => "some_new_type",
        "uuid" => "u-001",
        "sessionId" => "session-001"
      }

      assert {:ok, record} = Claude.parse_record(json)
      assert record.type == :unknown
    end

    test "handles nil type" do
      json = %{
        "uuid" => "u-001",
        "sessionId" => "session-001"
      }

      assert {:ok, record} = Claude.parse_record(json)
      assert record.type == :unknown
    end

    test "handles nil timestamp" do
      json = %{
        "type" => "user",
        "uuid" => "msg-001",
        "sessionId" => "session-001",
        "message" => %{"role" => "user", "content" => "test"}
      }

      assert {:ok, record} = Claude.parse_record(json)
      assert record.timestamp == nil
    end

    test "handles numeric timestamp (not a string)" do
      json = %{
        "type" => "user",
        "uuid" => "msg-001",
        "sessionId" => "session-001",
        "timestamp" => 1_234_567_890,
        "message" => %{"role" => "user", "content" => "test"}
      }

      assert {:ok, record} = Claude.parse_record(json)
      assert record.timestamp == nil
    end

    test "parses assistant message with nil content" do
      json = %{
        "type" => "assistant",
        "uuid" => "msg-002",
        "sessionId" => "session-001",
        "message" => %{
          "role" => "assistant",
          "content" => nil
        }
      }

      assert {:ok, record} = Claude.parse_record(json)
      assert record.content == []
      assert record.text == ""
    end

    test "handles unknown content item types" do
      json = %{
        "type" => "assistant",
        "uuid" => "msg-002",
        "sessionId" => "session-001",
        "message" => %{
          "role" => "assistant",
          "content" => [
            %{"type" => "server_tool_use", "name" => "mcp_tool", "id" => "st_001"}
          ]
        }
      }

      assert {:ok, record} = Claude.parse_record(json)
      assert length(record.content) == 1

      item = hd(record.content)
      assert item.type == :unknown
      assert is_map(item.metadata)
    end

    test "handles non-map content items in array" do
      json = %{
        "type" => "assistant",
        "uuid" => "msg-002",
        "sessionId" => "session-001",
        "message" => %{
          "role" => "assistant",
          "content" => ["just a string", 42]
        }
      }

      assert {:ok, record} = Claude.parse_record(json)
      assert length(record.content) == 2

      [first, second] = record.content
      assert first.type == :unknown
      assert second.type == :unknown
    end

    test "parses system role" do
      json = %{
        "type" => "user",
        "uuid" => "msg-001",
        "sessionId" => "session-001",
        "message" => %{
          "role" => "system",
          "content" => "System prompt"
        }
      }

      assert {:ok, record} = Claude.parse_record(json)
      assert record.role == :system
    end

    test "handles unknown role" do
      json = %{
        "type" => "user",
        "uuid" => "msg-001",
        "sessionId" => "session-001",
        "message" => %{
          "role" => "tool",
          "content" => "Some content"
        }
      }

      assert {:ok, record} = Claude.parse_record(json)
      assert record.role == nil
    end

    test "preserves parentUuid" do
      json = %{
        "type" => "assistant",
        "uuid" => "msg-002",
        "parentUuid" => "msg-001",
        "sessionId" => "session-001",
        "message" => %{
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => "Response"}]
        }
      }

      assert {:ok, record} = Claude.parse_record(json)
      assert record.parent_uuid == "msg-001"
    end

    test "extracts metadata with isSidechain and userType" do
      json = %{
        "type" => "user",
        "uuid" => "msg-001",
        "sessionId" => "session-001",
        "isSidechain" => true,
        "userType" => "external",
        "slug" => "test-slug",
        "message" => %{"role" => "user", "content" => "test"}
      }

      assert {:ok, record} = Claude.parse_record(json)
      assert record.metadata.is_sidechain == true
      assert record.metadata.user_type == "external"
      assert record.metadata.slug == "test-slug"
    end

    test "ignores message for non user/assistant types" do
      json = %{
        "type" => "progress",
        "uuid" => "prog-001",
        "sessionId" => "session-001",
        "message" => %{
          "role" => "assistant",
          "content" => "Should be ignored"
        }
      }

      assert {:ok, record} = Claude.parse_record(json)
      assert record.type == :progress
      # Message parsing should be skipped for non user/assistant types
      assert record.content == []
    end

    test "handles tool_result with is_error true" do
      json = %{
        "type" => "user",
        "uuid" => "msg-003",
        "sessionId" => "session-001",
        "message" => %{
          "role" => "user",
          "content" => [
            %{
              "type" => "tool_result",
              "tool_use_id" => "toolu_456",
              "content" => "Error: command not found",
              "is_error" => true
            }
          ]
        }
      }

      assert {:ok, record} = Claude.parse_record(json)
      tool_result = hd(record.content)
      assert tool_result.is_error == true
      assert tool_result.tool_result == "Error: command not found"
    end
  end

  describe "matches?/1 edge cases" do
    test "returns false for map with only sessionId" do
      refute Claude.matches?(%{"sessionId" => "abc"})
    end

    test "returns false for map with only uuid" do
      refute Claude.matches?(%{"uuid" => "123"})
    end

    test "returns true even with extra fields" do
      assert Claude.matches?(%{"sessionId" => "abc", "uuid" => "123", "extra" => "field"})
    end

    test "returns false for empty map" do
      refute Claude.matches?(%{})
    end

    test "returns false for integer input" do
      refute Claude.matches?(42)
    end

    test "returns false for list input" do
      refute Claude.matches?([])
    end
  end

  describe "encode_project_path/1" do
    test "handles root path" do
      assert Claude.encode_project_path("/") == "-"
    end

    test "handles nested paths" do
      assert Claude.encode_project_path("/Users/test/code/my-project") ==
               "-Users-test-code-my-project"
    end
  end

  describe "decode_project_path/1" do
    test "handles fallback for unknown prefixes" do
      result = Claude.decode_project_path("-opt-data-project")
      assert String.starts_with?(result, "/")
    end
  end
end
