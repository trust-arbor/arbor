defmodule Arbor.Gateway.SchemasTest do
  use ExUnit.Case, async: true

  alias Arbor.Gateway.Schemas

  @moduletag :fast

  describe "Memory.recall_request" do
    test "validates required fields" do
      schema = Schemas.Memory.recall_request()

      assert {:error, _} = Schemas.Memory.validate(schema, %{})
      assert {:error, _} = Schemas.Memory.validate(schema, %{"agent_id" => "test"})
      assert {:error, _} = Schemas.Memory.validate(schema, %{"query" => "test"})
    end

    test "validates valid minimal request" do
      schema = Schemas.Memory.recall_request()

      assert {:ok, validated} =
               Schemas.Memory.validate(schema, %{"agent_id" => "test", "query" => "test query"})

      assert validated["agent_id"] == "test"
      assert validated["query"] == "test query"
    end

    test "validates optional fields with defaults" do
      schema = Schemas.Memory.recall_request()

      assert {:ok, validated} =
               Schemas.Memory.validate(schema, %{
                 "agent_id" => "test",
                 "query" => "test query",
                 "limit" => 20,
                 "threshold" => 0.5,
                 "type" => "fact"
               })

      assert validated["limit"] == 20
      assert validated["threshold"] == 0.5
      assert validated["type"] == "fact"
    end

    test "validates limit bounds" do
      schema = Schemas.Memory.recall_request()

      # Below min
      assert {:error, errors} =
               Schemas.Memory.validate(schema, %{
                 "agent_id" => "test",
                 "query" => "test",
                 "limit" => 0
               })

      assert Enum.any?(errors, fn e -> e.field =~ "limit" end)

      # Above max
      assert {:error, errors} =
               Schemas.Memory.validate(schema, %{
                 "agent_id" => "test",
                 "query" => "test",
                 "limit" => 200
               })

      assert Enum.any?(errors, fn e -> e.field =~ "limit" end)
    end

    test "validates threshold bounds" do
      schema = Schemas.Memory.recall_request()

      # Below min
      assert {:error, errors} =
               Schemas.Memory.validate(schema, %{
                 "agent_id" => "test",
                 "query" => "test",
                 "threshold" => -0.1
               })

      assert Enum.any?(errors, fn e -> e.field =~ "threshold" end)

      # Above max
      assert {:error, errors} =
               Schemas.Memory.validate(schema, %{
                 "agent_id" => "test",
                 "query" => "test",
                 "threshold" => 1.5
               })

      assert Enum.any?(errors, fn e -> e.field =~ "threshold" end)
    end

    test "validates type enum" do
      schema = Schemas.Memory.recall_request()

      # Invalid type
      assert {:error, errors} =
               Schemas.Memory.validate(schema, %{
                 "agent_id" => "test",
                 "query" => "test",
                 "type" => "invalid"
               })

      assert Enum.any?(errors, fn e -> e.field =~ "type" end)
    end
  end

  describe "Memory.index_request" do
    test "validates required fields" do
      schema = Schemas.Memory.index_request()

      assert {:error, _} = Schemas.Memory.validate(schema, %{})
      assert {:error, _} = Schemas.Memory.validate(schema, %{"agent_id" => "test"})
      assert {:error, _} = Schemas.Memory.validate(schema, %{"content" => "test"})
    end

    test "validates valid request" do
      schema = Schemas.Memory.index_request()

      assert {:ok, validated} =
               Schemas.Memory.validate(schema, %{
                 "agent_id" => "test",
                 "content" => "test content"
               })

      assert validated["agent_id"] == "test"
      assert validated["content"] == "test content"
    end

    test "accepts optional metadata" do
      schema = Schemas.Memory.index_request()

      assert {:ok, validated} =
               Schemas.Memory.validate(schema, %{
                 "agent_id" => "test",
                 "content" => "test content",
                 "metadata" => %{"type" => "fact"}
               })

      assert validated["metadata"] == %{"type" => "fact"}
    end
  end

  describe "Memory.summarize_request" do
    test "validates required fields" do
      schema = Schemas.Memory.summarize_request()

      assert {:error, _} = Schemas.Memory.validate(schema, %{})
      assert {:error, _} = Schemas.Memory.validate(schema, %{"agent_id" => "test"})
      assert {:error, _} = Schemas.Memory.validate(schema, %{"text" => "test"})
    end

    test "validates valid request" do
      schema = Schemas.Memory.summarize_request()

      assert {:ok, validated} =
               Schemas.Memory.validate(schema, %{
                 "agent_id" => "test",
                 "text" => "Long text to summarize"
               })

      assert validated["agent_id"] == "test"
      assert validated["text"] == "Long text to summarize"
    end

    test "validates max_length bounds" do
      schema = Schemas.Memory.summarize_request()

      # Below min
      assert {:error, errors} =
               Schemas.Memory.validate(schema, %{
                 "agent_id" => "test",
                 "text" => "test",
                 "max_length" => 10
               })

      assert Enum.any?(errors, fn e -> e.field =~ "max_length" end)

      # Above max
      assert {:error, errors} =
               Schemas.Memory.validate(schema, %{
                 "agent_id" => "test",
                 "text" => "test",
                 "max_length" => 10_000
               })

      assert Enum.any?(errors, fn e -> e.field =~ "max_length" end)
    end
  end

  describe "Bridge.authorize_tool_request" do
    test "validates required fields" do
      schema = Schemas.Bridge.authorize_tool_request()

      assert {:error, _} = Schemas.Bridge.validate(schema, %{})
      assert {:error, _} = Schemas.Bridge.validate(schema, %{"session_id" => "test"})
      assert {:error, _} = Schemas.Bridge.validate(schema, %{"tool_name" => "test"})
    end

    test "validates valid minimal request" do
      schema = Schemas.Bridge.authorize_tool_request()

      assert {:ok, validated} =
               Schemas.Bridge.validate(schema, %{
                 "session_id" => "session123",
                 "tool_name" => "Read"
               })

      assert validated["session_id"] == "session123"
      assert validated["tool_name"] == "Read"
    end

    test "validates with optional fields" do
      schema = Schemas.Bridge.authorize_tool_request()

      assert {:ok, validated} =
               Schemas.Bridge.validate(schema, %{
                 "session_id" => "session123",
                 "tool_name" => "Read",
                 "tool_input" => %{"path" => "/tmp/file.txt"},
                 "cwd" => "/home/user"
               })

      assert validated["tool_input"] == %{"path" => "/tmp/file.txt"}
      assert validated["cwd"] == "/home/user"
    end

    test "rejects empty session_id" do
      schema = Schemas.Bridge.authorize_tool_request()

      assert {:error, errors} =
               Schemas.Bridge.validate(schema, %{
                 "session_id" => "",
                 "tool_name" => "Read"
               })

      assert Enum.any?(errors, fn e -> e.field =~ "session_id" end)
    end
  end
end
