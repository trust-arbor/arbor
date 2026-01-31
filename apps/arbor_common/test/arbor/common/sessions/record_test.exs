defmodule Arbor.Common.Sessions.RecordTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Common.Sessions.Record

  describe "new/1" do
    test "creates a record with default values" do
      record = Record.new()

      assert record.type == nil
      assert record.uuid == nil
      assert record.content == []
      assert record.text == ""
      assert record.metadata == %{}
    end

    test "creates a record with provided attributes" do
      record = Record.new(type: :user, role: :user, text: "Hello")

      assert record.type == :user
      assert record.role == :user
      assert record.text == "Hello"
    end
  end

  describe "message?/1" do
    test "returns true for user records" do
      assert Record.message?(%Record{type: :user})
    end

    test "returns true for assistant records" do
      assert Record.message?(%Record{type: :assistant})
    end

    test "returns false for other record types" do
      refute Record.message?(%Record{type: :progress})
      refute Record.message?(%Record{type: :queue_operation})
      refute Record.message?(%Record{type: :summary})
      refute Record.message?(%Record{type: :unknown})
    end
  end

  describe "user?/1" do
    test "returns true for user records" do
      assert Record.user?(%Record{type: :user})
    end

    test "returns false for non-user records" do
      refute Record.user?(%Record{type: :assistant})
      refute Record.user?(%Record{type: :progress})
    end
  end

  describe "assistant?/1" do
    test "returns true for assistant records" do
      assert Record.assistant?(%Record{type: :assistant})
    end

    test "returns false for non-assistant records" do
      refute Record.assistant?(%Record{type: :user})
      refute Record.assistant?(%Record{type: :progress})
    end
  end

  describe "struct fields" do
    test "all expected fields are present" do
      record = %Record{}

      assert Map.has_key?(record, :type)
      assert Map.has_key?(record, :uuid)
      assert Map.has_key?(record, :parent_uuid)
      assert Map.has_key?(record, :session_id)
      assert Map.has_key?(record, :timestamp)
      assert Map.has_key?(record, :role)
      assert Map.has_key?(record, :content)
      assert Map.has_key?(record, :text)
      assert Map.has_key?(record, :model)
      assert Map.has_key?(record, :usage)
      assert Map.has_key?(record, :metadata)
    end
  end
end
