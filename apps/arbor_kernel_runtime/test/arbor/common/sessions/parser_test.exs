defmodule Arbor.Common.Sessions.ParserTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Common.Sessions.Parser
  alias Arbor.Common.Sessions.Record

  describe "parse/2" do
    test "parses with auto-detection for Claude format" do
      json = %{
        "type" => "user",
        "uuid" => "msg-001",
        "sessionId" => "session-001",
        "message" => %{"role" => "user", "content" => "Hello"}
      }

      assert {:ok, %Record{} = record} = Parser.parse(json)
      assert record.type == :user
    end

    test "parses with explicit :claude provider" do
      json = %{
        "type" => "user",
        "uuid" => "msg-001",
        "sessionId" => "session-001",
        "message" => %{"role" => "user", "content" => "Hello"}
      }

      assert {:ok, %Record{}} = Parser.parse(json, provider: :claude)
    end

    test "returns error for unknown format with auto-detection" do
      json = %{"unknown" => "format"}

      assert {:error, :unknown_provider} = Parser.parse(json)
    end
  end

  describe "parse!/2" do
    test "returns record on success" do
      json = %{
        "type" => "user",
        "uuid" => "msg-001",
        "sessionId" => "session-001",
        "message" => %{"role" => "user", "content" => "Hello"}
      }

      assert %Record{} = Parser.parse!(json)
    end

    test "raises on failure" do
      json = %{"unknown" => "format"}

      assert_raise ArgumentError, fn ->
        Parser.parse!(json)
      end
    end
  end

  describe "parse_json/2" do
    test "parses valid JSON string" do
      json_string =
        ~s({"type": "user", "uuid": "msg-001", "sessionId": "session-001", "message": {"role": "user", "content": "Hello"}})

      assert {:ok, %Record{}} = Parser.parse_json(json_string)
    end

    test "returns error for invalid JSON" do
      assert {:error, {:json_decode_error, _}} = Parser.parse_json("{invalid json}")
    end

    test "accepts provider option" do
      json_string =
        ~s({"type": "user", "uuid": "msg-001", "sessionId": "session-001", "message": {"role": "user", "content": "Hello"}})

      assert {:ok, %Record{}} = Parser.parse_json(json_string, provider: :claude)
    end
  end

  describe "detect_provider/1" do
    test "detects Claude format" do
      json = %{"sessionId" => "abc", "uuid" => "123"}
      assert Parser.detect_provider(json) == :claude
    end

    test "returns :unknown for unrecognized format" do
      json = %{"other" => "format"}
      assert Parser.detect_provider(json) == :unknown
    end
  end
end
